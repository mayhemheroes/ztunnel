#!/usr/bin/env bash
#
# ztunnel/mayhem/test.sh — RUN istio/ztunnel's own library unit-test suite (`cargo test --lib`,
# default features) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: ztunnel's `src/baggage.rs` ships real assertion-based unit tests
# (`mod tests`, 5 `#[test]`s) that feed a KNOWN W3C baggage header string through
# `parse_baggage_header` and `assert_eq!` the parsed `Baggage` struct fields (cluster_id,
# namespace, workload_name, service_name, revision, region, zone) against golden values — this is
# exactly the code path the `baggage` fuzz target exercises. Other `src/**` modules (rbac,
# workload, xds parsing, etc.) carry their own `#[test]`s asserting concrete parse/convert
# results. A no-op / "exit(0)" / output-altering patch to any of that code CANNOT pass — the
# assert_eq!s would fail. This script only RUNS the suite via `cargo test --lib`; it never builds
# fuzz targets.
#
# We run with the crate's default features (tls-aws-lc — the same TLS backend the binary ships)
# and NO sanitizer RUSTFLAGS, so the oracle stays a clean, honest, independent build (not the
# ASan-instrumented fuzz objects from build.sh).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test --lib (ztunnel crate, default features) ==="
# Use the image's DEFAULT toolchain (the Dockerfile pinned it to the same nightly the fuzz build
# uses), so no `+toolchain` override — that would make rustup try to install a different channel
# into the read-only shared /opt/toolchains/rust. --no-fail-fast so we count every test; RUSTFLAGS
# cleared so it inherits nothing from the sanitizer build. --lib runs the ztunnel library's own
# unit tests (baggage/rbac/workload/xds parsing, …) — the same code the fuzz targets exercise.
out="$(RUSTFLAGS="" cargo test --lib --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries (there's one for --lib, but keep this general).
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
