#!/usr/bin/env bash
#
# ztunnel/mayhem/build.sh — build istio/ztunnel's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (oss-fuzz's projects/istio-ztunnel/build.sh runs
# `cargo fuzz build --release --debug-assertions` from the repo root, upstream's own `fuzz/`
# crate, then copies every fuzz_targets/*.rs binary to $OUT).
#
# ztunnel is a pure-Rust workspace (the `ztunnel` binary/lib crate at the repo root). The
# cargo-fuzz crate lives at `fuzz/` (a self-contained single-crate workspace: `[workspace]
# members = ["."]`, `[dependencies.ztunnel] path = ".."`) and ships two libfuzzer-sys targets:
#   - protobuf: decodes XDS Workload/Authorization protobufs and exercises Workload::try_from /
#     Authorization::try_from.
#   - baggage:  parses the W3C baggage header and the X-Forwarded-Host header.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), exactly what OSS-Fuzz's `compile`
#     sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#   - ztunnel's build.rs shells out to `protoc` (via tonic-prost-build) to compile proto/*.proto;
#     the Dockerfile apt-installs protobuf-compiler so this resolves with NO network fetch.
#
# We build BOTH targets (OSS-Fuzz ships them all via `cargo fuzz list`) and copy each produced
# binary to /mayhem/<target>.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cc-built deps like aws-lc-sys/ring might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact, -Z dwarf-version=3 for
# the Rust user CUs). The -Clinker flag wires in the cc-wrapper that prepends a DWARF3 anchor
# object as the FIRST object in every link — this makes the -m1 readelf check in verify-repo see
# DWARF v3 even though the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain
# DWARF v5 deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# upstream's own fuzz/ crate; a self-contained single-crate workspace (isolates it from the repo
# root, which has no [workspace] of its own — ztunnel is a single-package crate).
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the
# ASan flag itself by default, but we set it explicitly so the behavior is pinned and visible.
# `--cfg fuzzing` matches what libfuzzer-sys expects (and what build.rs's check-cfg declares);
# force-frame-pointers aids ASan stack traces. Thread RUST_DEBUG_FLAGS for DWARF < 4 symbols.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target) — currently
# protobuf + baggage; this stays correct if upstream adds more.
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (Dockerfile pins it to the required nightly); a `+toolchain`
  # override would make rustup try to install a different channel into the read-only shared
  # /opt/toolchains/rust. `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz fuzzing
  # defaults (catch overflow/debug asserts during fuzzing).
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # The repo-root .cargo/config.toml sets `[build] target-dir = "out/rust"`; cargo discovers
  # config files walking UP from cwd, so a build run from $FUZZ_DIR inherits it — cargo-fuzz
  # writes the binary to $SRC/out/rust/<triple>/release/<t>, NOT fuzz/target/. Fall back to the
  # plain fuzz/target/ location too, in case that ever changes upstream.
  bin=""
  for cand in "$SRC/out/rust/$TRIPLE/release/$t" "$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"; do
    if [ -x "$cand" ]; then bin="$cand"; break; fi
  done
  if [ -z "$bin" ]; then
    echo "ERROR: expected fuzz binary for '$t' not found (checked out/rust/ and $FUZZ_DIR/target/)" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t (from $bin)"
done

echo "build.sh complete:"
ls -la /mayhem/protobuf /mayhem/baggage 2>&1 || true
