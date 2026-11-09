#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# Run NeoMutt's own acutest unit suite (built by build.sh with the normal flags). The tests need the
# neomutt-test-files fixtures as NEOMUTT_TEST_DIR. They are committed as a tarball (git_ver.c's make rule
# depends on every tracked file, and the fixtures include a dangling symlink) and unpacked into a scratch
# dir on each run, since setup.sh chmods them and the tests write into tmp/.
runner="$SRC/build-test/test/neomutt-test"
[ -x "$runner" ] || { echo "missing $runner (mayhem/build.sh should have built it)" >&2; emit_ctrf "acutest" 0 1; exit 1; }

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
tar -xzf "$SRC/mayhem/neomutt-test-files.tar.gz" -C "$work"
mkdir -p "$work/tmp"
(cd "$work" && sh ./setup.sh)
export NEOMUTT_TEST_DIR="$work"

log="$work/../neomutt-test.$$.log"
(cd "$SRC/build-test" && "$runner" --no-color) > "$log" 2>&1
rc=$?
cat "$log"

# acutest ends the run with "SUCCESS: No unit tests have failed." or "FAILED: N of M unit tests have
# failed." Messages printed mid-test split the per-test "[ OK ]" markers, so on success the count is the
# number of listed tests. A runner that exits early or prints nothing (e.g. a neutered program) has
# neither summary line and is reported as a failure.
passed=0; failed=0
if grep -q '^SUCCESS: No unit tests have failed' "$log"; then
  passed=$("$runner" -l | grep -c '^  test_')
  [ "$passed" -gt 0 ] || failed=1
elif m=$(grep -E '^FAILED: [0-9]+ of [0-9]+ unit tests have failed' "$log" | tail -1) && [ -n "$m" ]; then
  failed=$(echo "$m" | awk '{print $2}'); passed=$(( $(echo "$m" | awk '{print $4}') - failed ))
else
  failed=1
fi
rm -f "$log"
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
emit_ctrf "acutest" "$passed" "$failed" 0
