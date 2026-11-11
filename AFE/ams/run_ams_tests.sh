#!/usr/bin/env bash
# run_ams_tests.sh - run the Spectre AMS testbenches of AFE/ams with xrun
#
#   AFE/ams/run_ams_tests.sh            all testbenches (tb_ams_*.vams), in parallel
#   AFE/ams/run_ams_tests.sh link pwr   only those whose name contains an argument
#
# Each testbench's header holds its xrun command (an "//   xrun ..." line with
# "\" continuations, paths relative to the repository root); this script runs
# exactly that command from the root, adding
#   -xmlibdirpath build/ams/<tb>   -l build/ams/<tb>/xrun.log
#   -spectre_args "-raw build/ams/<tb>/psf"   -input build/ams/<tb>/run.tcl
# (SHM waveforms of the top two levels into build/ams/<tb>/waves.shm), plus
# $XRUN_OPTS (for example "-define AMS_NPKT=10" or a -defparam).
#
# XRUN selects the command (default: xrun).  Before simulating, the static
# netlist check check_ams_netlist.py runs (ports, files, connect rules); it
# also runs without a simulator.  Each testbench prints TEST PASSED / TEST
# FAILED: <n> error(s) / TEST FAILED: timeout; this script checks that line,
# not xrun's exit status, and exits non-zero on any failure.  Without xrun it
# reports SKIP for the simulation and exits with the static check's status.
#
# The Icarus shadows tb_ams_*_shadow.v (same digital ends and sequences, the
# afe_*_bm.v models) run with ./run_tests.sh, not here.
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=$ROOT/build/ams
XRUN=${XRUN:-xrun}
XRUN_OPTS=${XRUN_OPTS:-}

tbs=()
for f in AFE/ams/tb_ams_*.vams; do
    name=$(basename "$f" .vams)
    if [ $# -eq 0 ]; then tbs+=("$f"); continue; fi
    for a in "$@"; do
        case "$name" in *"$a"*) tbs+=("$f"); break ;; esac
    done
done
[ ${#tbs[@]} -eq 0 ] && { echo "no testbench matches: $*"; exit 1; }

echo "static netlist check:"
python3 AFE/ams/check_ams_netlist.py "${tbs[@]}"
static=$?
[ $static -ne 0 ] && echo "static check failed"

if ! command -v "$XRUN" >/dev/null 2>&1; then
    for f in "${tbs[@]}"; do echo "SKIP  $(basename "$f" .vams)  (no '$XRUN' on PATH; set XRUN=...)"; done
    exit $static
fi
[ $static -ne 0 ] && exit $static

# xrun command of a testbench header (continuation lines joined)
tb_cmd() {
    awk '
        !on && /^\/\/[ \t]+xrun / { on = 1 }
        on {
            line = $0; sub(/^\/\/[ \t]+/, "", line)
            cont = (line ~ /\\[ \t]*$/); sub(/\\[ \t]*$/, "", line)
            printf "%s ", line
            if (!cont) exit
        }' "$1"
}

mkdir -p "$OUT"
for f in "${tbs[@]}"; do
    t=$(basename "$f" .vams)
    d=$OUT/$t
    mkdir -p "$d"
    cat > "$d/run.tcl" <<EOF
database -open waves -shm -into $d/waves.shm -default
probe -create $t -depth 2 -all -shm
run
exit
EOF
    cmd=$(tb_cmd "$f")
    cmd="$XRUN ${cmd#xrun }"                 # the header says xrun; use $XRUN
    ( eval "$cmd" -xmlibdirpath "$d" -l "$d/xrun.log" \
          -spectre_args "\"-raw $d/psf\"" -input "$d/run.tcl" $XRUN_OPTS \
          > "$d/stdout.txt" 2>&1 ) &
done
wait

fail=0
for f in "${tbs[@]}"; do
    t=$(basename "$f" .vams)
    res=$(grep -h -E "TEST (PASSED|FAILED)" "$OUT/$t/xrun.log" "$OUT/$t/stdout.txt" 2>/dev/null | tail -1)
    case "$res" in
        *"TEST PASSED"*) echo "PASS  $t" ;;
        *"TEST FAILED"*) echo "FAIL  $t  ($res)"; fail=1 ;;
        *)               echo "FAIL  $t  (no result line, see $OUT/$t/xrun.log)"; fail=1 ;;
    esac
done
exit $fail
