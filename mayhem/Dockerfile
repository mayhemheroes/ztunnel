# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (RUST form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). ztunnel is a pure-Rust workspace (Istio's node proxy), and the
# base ships NO Rust toolchain, so this image installs a pinned nightly + cargo-fuzz under
# /opt/toolchains/rust (SPEC §6.2 item 8 — a fixed, $HOME-independent prefix so the cargo
# registry the FIRST build populates is found again by the air-gapped PATCH re-run, §6.5), then
# runs build.sh + test.sh.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t ztunnel-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default, but
# cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# ztunnel is edition 2024 / rust-version 1.90; pin a nightly dated safely after the 1.90 stable
# release so edition-2024 + workspace-inherited features resolve. Same dated-nightly convention
# used by the other Rust integrations in this fleet (askama et al).
ARG RUST_CHANNEL=nightly-2025-10-15
ARG CARGO_FUZZ_VERSION=0.12.0

# Rust toolchain @ a FIXED, lockable, $HOME-independent prefix (SPEC §6.2 item 8 / §6.5).
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root

# ztunnel's build.rs shells out to `protoc` (via tonic-prost-build) to compile proto/*.proto —
# apt-install it (+ libprotobuf-dev for headers) so this resolves with NO network fetch, exactly
# like OSS-Fuzz's own Dockerfile for this project. cmake/perl (already in the base) drive
# aws-lc-sys's vendored-C build (the default `tls-aws-lc` feature).
RUN apt-get --yes update \
 && apt-get install --no-install-recommends --yes \
      protobuf-compiler \
      libprotobuf-dev \
 && apt-get clean \
 && rm --recursive --force /var/lib/apt/lists/*

RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain "$RUST_CHANNEL"; \
    rustup component add rust-src --toolchain "$RUST_CHANNEL"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    rm -f /tmp/rustup-init.sh; \
    # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
    # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc --version; cargo --version; cargo fuzz --version

# DWARF<4 gate workaround for Rust/cargo-fuzz (§6.2 item 10).
# Problem: cargo-fuzz links the Rust nightly ASan runtime archive (librustc-nightly_rt.asan.a)
# via --whole-archive, and that archive's objects (compiled by clang with DWARF v5) land FIRST in
# .debug_info before any user/std CUs. The -Z dwarf-version=3 RUSTFLAG only controls rustc's own
# CUs — it cannot retroactively lower the precompiled runtime.
# Solution (the Go-canary trick, adapted for Rust): compile a tiny stub with clang -gdwarf-3 and
# inject it as the FIRST object in every link via a cc-wrapper linker script (-Clinker=...). The
# wrapper prepends anchor.o to the linker command; since .debug_info CUs appear in linker-argument
# order, anchor.o's DWARF3 CU becomes offset 0 — the one verify-repo's -m1 reads. (COSMETIC w.r.t.
# that check for -Zsanitizer=address builds: Rust code + the ASan runtime remain DWARF5 deeper in
# the binary; fuzzing works, but crash-triage symbolication still reads DWARF5 there.)
RUN set -eux; \
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/mayhem-dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c \
      -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/mayhem-dwarf3-anchor /opt/mayhem-dwarf3-anchor/anchor.o \
               /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/mayhem-dwarf3-anchor/anchor.o | grep -m1 Version:)"

USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run ztunnel's own library unit-test suite (default features, incl. the baggage/protobuf-parse
# assertions the fuzz targets exercise) at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
