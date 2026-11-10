#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_tests.sh - build and run the self-checking testbenches (Icarus Verilog)
#
#   ./run_tests.sh                 all testbenches
#   ./run_tests.sh ulpi_core rx_   only testbenches whose name contains one of the words
#   JOBS=4 ./run_tests.sh          run up to 4 simulations in parallel (default: nproc)
#
# The iverilog command of every testbench is taken from its header comment (the
# "iverilog ..." line and its "\" continuations), so the file lists live in one place.
# Simulations, logs and VCDs go to build/ (git-ignored).  A testbench passes only if
# its last result line is "TEST PASSED".  Testbenches that need the X-FAB pad model
# (X-FAB/...) are skipped with a note when X-FAB/ is not there (the PDK is not part
# of the public repository).
#
# Exit code: 0 if every testbench that ran passed, 1 otherwise.
#-----------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"
BUILD=build
mkdir -p "$BUILD"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

command -v iverilog >/dev/null || { echo "iverilog not found"; exit 1; }

# iverilog command from the header of a testbench (joined continuation lines)
tb_cmd() {
    awk '
        /^\/\/[ \t]+iverilog/ { on = 1 }
        on {
            line = $0
            sub(/^\/\/[ \t]*/, "", line)
            cont = (line ~ /\\[ \t]*$/)
            sub(/\\[ \t]*$/, "", line)
            cmd = cmd " " line
            if (!cont) { print cmd; exit }
        }' "$1"
}

run_one() {
    local tb=$1 name cmd out log res
    name=${tb%.v}
    cmd=$(tb_cmd "$tb")
    if [ -z "$cmd" ]; then
        echo "$name|NO COMMAND|header has no iverilog line"; return
    fi
    if [[ $cmd == *X-FAB/* ]] && [ ! -d X-FAB ]; then
        echo "$name|SKIPPED|X-FAB/ (PDK) not present"; return
    fi
    out=$BUILD/sim_$name
    log=$BUILD/$name.log
    # replace the "-o <file>" of the header by the build directory
    cmd=$(sed -E "s#-o[ \t]+[^ \t]+#-o $out#" <<< "$cmd")
    if ! eval "$cmd" > "$log" 2>&1; then
        echo "$name|BUILD FAILED|see $log"; return
    fi
    ( cd "$BUILD" && vvp -n "sim_$name" ) >> "$log" 2>&1
    res=$(grep -E '^TEST (PASSED|FAILED)' "$log" | tail -1)
    [ -z "$res" ] && res="NO RESULT"
    echo "$name|$res|$log"
}
export -f run_one tb_cmd
export BUILD

tbs=()
for tb in tb_*.v; do
    if [ $# -eq 0 ]; then tbs+=("$tb"); continue; fi
    for w in "$@"; do [[ $tb == *"$w"* ]] && { tbs+=("$tb"); break; }; done
done
[ ${#tbs[@]} -eq 0 ] && { echo "no testbench matches: $*"; exit 1; }

start=$(date +%s)
results=$(printf '%s\n' "${tbs[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} | sort)

pass=0; fail=0; skip=0
while IFS='|' read -r name res info; do
    case $res in
        "TEST PASSED") pass=$((pass + 1)); printf '  %-32s %s\n' "$name" "$res" ;;
        SKIPPED)       skip=$((skip + 1)); printf '  %-32s %s (%s)\n' "$name" "$res" "$info" ;;
        *)             fail=$((fail + 1)); printf '  %-32s %s (%s)\n' "$name" "$res" "$info" ;;
    esac
done <<< "$results"

echo "--------------------------------------------------"
echo "testbenches: $pass passed, $fail failed, $skip skipped ($(( $(date +%s) - start )) s)"
[ $fail -eq 0 ]
