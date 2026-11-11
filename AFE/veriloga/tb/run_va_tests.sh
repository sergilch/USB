#!/usr/bin/env bash
# run_va_tests.sh - run the Verilog-A testbenches of AFE/veriloga with Spectre
#
#   ./run_va_tests.sh             all testbenches (tb_afe_*.scs), in parallel
#   ./run_va_tests.sh cdr ldo     only those whose name contains an argument
#
# SPECTRE selects the simulator command (default: spectre).  Logs and raw
# data go to <repo>/build/va/<testbench>/ (git-ignored).  Each testbench
# prints TEST PASSED / TEST FAILED: <n> error(s) / TEST FAILED: timeout; this
# script checks that line, not Spectre's exit code, and exits non-zero on any
# failure.  Without a simulator it reports every testbench as SKIP and exits 0.
set -u
cd "$(dirname "$0")"
TB_DIR=$(pwd)
OUT=$(cd ../../.. && pwd)/build/va
SPECTRE=${SPECTRE:-spectre}

tbs=()
for f in tb_afe_*.scs; do
    name=${f%.scs}
    if [ $# -eq 0 ]; then tbs+=("$name"); continue; fi
    for a in "$@"; do
        case "$name" in *"$a"*) tbs+=("$name"); break ;; esac
    done
done
[ ${#tbs[@]} -eq 0 ] && { echo "no testbench matches: $*"; exit 1; }

if ! command -v "$SPECTRE" >/dev/null 2>&1; then
    for t in "${tbs[@]}"; do echo "SKIP  $t  (no '$SPECTRE' on PATH; set SPECTRE=...)"; done
    exit 0
fi

mkdir -p "$OUT"
for t in "${tbs[@]}"; do
    mkdir -p "$OUT/$t"
    ( cd "$TB_DIR" && "$SPECTRE" +escchars =log "$OUT/$t/$t.log" -raw "$OUT/$t/$t.raw" \
          "$t.scs" > "$OUT/$t/stdout.txt" 2>&1 ) &
done
wait

fail=0
for t in "${tbs[@]}"; do
    res=$(grep -h -E "TEST (PASSED|FAILED)" "$OUT/$t/$t.log" "$OUT/$t/stdout.txt" 2>/dev/null | head -1)
    case "$res" in
        *"TEST PASSED"*) echo "PASS  $t" ;;
        *"TEST FAILED"*) echo "FAIL  $t  ($res)"; fail=1 ;;
        *)               echo "FAIL  $t  (no result line, see $OUT/$t/$t.log)"; fail=1 ;;
    esac
done
exit $fail
