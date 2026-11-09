#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# NeoMutt uses autosetup; out-of-tree build dirs named build-* are covered by upstream's `build*/`
# .gitignore, so `git clean -ffdX` removes their configure state. Re-running this script on a built tree
# only re-runs configure-less incremental makes.
CONFIGURE_OPTS=(--disable-doc --disable-nls)   # same as OSS-Fuzz's projects/neomutt/build.sh

# 1) The project's own unit-test binary with NORMAL flags (the PATCH oracle; mayhem/test.sh only runs it).
mkdir -p build-test
(
  cd build-test
  [ -f Makefile ] || ../configure "${CONFIGURE_OPTS[@]}" CC="$CC" --quiet
  make -j"$MAYHEM_JOBS" test/neomutt-test EXTRA_CFLAGS="$COVERAGE_FLAGS" EXTRA_LDFLAGS="$COVERAGE_FLAGS"
)

# 2) Sanitized fuzz build. `--fuzzing` makes configure add -fsanitize=fuzzer (coverage instrumentation)
#    and the `fuzz` make target (upstream's fuzz/{address,body,cli,date}.c harnesses). Sanitizer + DWARF<4
#    flags go in at make time (EXTRA_*), not at configure time, so configure's probe programs stay clean.
mkdir -p build-fuzz/fuzz   # upstream's Makefile only creates the library output dirs, not fuzz/
(
  cd build-fuzz
  [ -f Makefile ] || ../configure "${CONFIGURE_OPTS[@]}" --fuzzing CC="$CC" --quiet

  # LeakSanitizer off at build time (docs/rules/c.md): ASan + UBSan stay fully active.
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o lsan_off.o
  # The LLVM run-once driver must be a C object so its LLVMFuzzerTestOneInput reference isn't mangled.
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o standalone_main.o

  # libFuzzer binaries: upstream's own link rule, with the fuzzing engine and the LSan hook appended.
  make -j"$MAYHEM_JOBS" fuzz \
    EXTRA_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" EXTRA_LDFLAGS="$SANITIZER_FLAGS" \
    LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $PWD/lsan_off.o"

  # Standalone reproducers: same objects and rule, EXEEXT renames the outputs, and the driver replaces libFuzzer.
  make -j"$MAYHEM_JOBS" fuzz EXEEXT=-standalone \
    LDFLAGS="-L/usr/lib $SANITIZER_FLAGS -fsanitize=fuzzer-no-link" \
    LIB_FUZZING_ENGINE="$PWD/standalone_main.o $PWD/lsan_off.o"

  for f in address body cli date; do
    cp -f "fuzz/$f-fuzz" "/mayhem/$f-fuzz"
    cp -f "fuzz/$f-fuzz-standalone" "/mayhem/$f-fuzz-standalone"
  done
)
