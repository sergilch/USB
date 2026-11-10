#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# run_synth.sh - Yosys synthesis smoke test for the top levels
#
#   ./run_synth.sh                       all top levels
#   ./run_synth.sh usb_ulpi_phy_top      only the named top level(s)
#   CORNER=slow ./run_synth.sh           xh018 Liberty corner: typ (default), slow, fast
#
# Per top level (all usb_*.v are read, hierarchy -check picks the used modules):
#   * generic synthesis, flattened (synth -flatten);
#   * no latches may be inferred, and "check -assert" must find no problems
#     (undriven / multiply driven nets, logic loops);
#   * if the X-FAB library is present (X-FAB/xh018_lib): flip-flops mapped with
#     dfflibmap, logic with abc onto the D_CELLS_JIHD cells; no generic cell may be
#     left, and the area is reported (stat -liberty).  Without X-FAB/ only the generic
#     part runs.
# The BBSUD8F pad cells of usb_ulpi_phy_pads are black boxes: their port declarations
# are cut out of X-FAB/BBSUD8F.v into build/ at run time (the vendor simulation model
# itself is not synthesizable, and the PDK is not part of the public repository).  The
# pad wrapper is skipped without X-FAB/.
#
# Logs and netlists go to build/ (git-ignored): build/synth_<top>.log, .v.
# Yosys warns that it cannot parse the function of the scan flip-flops of the library
# (SDFF*): they are not used, which is fine for this smoke test.  No timing analysis is
# done here (work plan 9.1 / 9.3).
#
# Exit code: 0 if every top level that ran passed, 1 otherwise.
#-----------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"
BUILD=build
mkdir -p "$BUILD"
CORNER=${CORNER:-typ}

command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }

TOPS=(usb_ulpi_phy_top usb_ulpi_phy_pads usb_rx_datapath usb_ulpi_tx_top usb_afe_tx_if)
[ $# -gt 0 ] && TOPS=("$@")

RTL=$(ls usb_*.v | tr '\n' ' ')

LIB=""
if [ -d X-FAB/xh018_lib ]; then
    LIB=$(ls X-FAB/xh018_lib/D_CELLS_JIHD_LPMOS_${CORNER}_*.lib 2>/dev/null | head -1)
    [ -z "$LIB" ] && { echo "no Liberty file for corner '$CORNER' in X-FAB/xh018_lib"; exit 1; }
fi

# black-box stub of the pad cell (ports only)
BB=""
if [ -f X-FAB/BBSUD8F.v ]; then
    BB=$BUILD/BBSUD8F_bb.v
    {
        echo "(* blackbox *)"
        awk '/^module BBSUD8F[ (]/ { p = 1 }
             p && /^[ \t]*(module|input|output|inout)/ { print }
             p && /^[ \t]*output/ { exit }' X-FAB/BBSUD8F.v
        echo "endmodule"
    } > "$BB"
fi

echo "Yosys $(yosys -V | awk '{print $2}'), library: ${LIB:-none (generic only)}"
pass=0; fail=0; skip=0
for top in "${TOPS[@]}"; do
    log=$BUILD/synth_$top.log
    if [ "$top" = usb_ulpi_phy_pads ] && [ -z "$BB" ]; then
        printf '  %-20s SKIPPED (X-FAB/BBSUD8F.v not present)\n' "$top"; skip=$((skip + 1)); continue
    fi
    script="read_verilog $BB $RTL; hierarchy -check -top $top; synth -top $top -flatten;"
    script+=" select -assert-none t:\$_DLATCH* t:\$dlatch* t:\$_SR_*;"
    script+=" check -assert; tee -o $BUILD/synth_$top.ff select -count t:\$_*DFF*;"
    if [ -n "$LIB" ]; then
        script+=" dfflibmap -liberty $LIB; abc -liberty $LIB; opt_clean;"
        script+=" select -assert-none t:\$_*; tee -o $BUILD/synth_$top.stat stat -liberty $LIB;"
    else
        script+=" tee -o $BUILD/synth_$top.stat stat;"
    fi
    script+=" write_verilog -noattr $BUILD/synth_$top.v"

    if yosys -q -l "$log" -p "$script" > /dev/null 2>&1; then
        cells=$(awk '/Number of cells:/ { n = $NF } END { print n }' "$BUILD/synth_$top.stat")
        ffs=$(grep -oE '[0-9]+ objects' "$BUILD/synth_$top.ff" | awk '{print $1}')
        area=$(awk '/Chip area/ { a = $NF } END { print a }' "$BUILD/synth_$top.stat")
        pads=$(awk '$1 == "BBSUD8F" { print $2 }' "$BUILD/synth_$top.stat" | tail -1)
        printf '  %-20s PASSED  cells %6s  flip-flops %4s' "$top" "$cells" "$ffs"
        [ -n "$area" ] && printf '  area %10.0f' "$area"
        [ -n "$pads" ] && printf '  (incl. %s BBSUD8F)' "$pads"
        printf '\n'
        pass=$((pass + 1))
    else
        why=$(grep -m1 -E 'ERROR|Assert' "$log")
        printf '  %-20s FAILED  %s (see %s)\n' "$top" "${why:-yosys error}" "$log"
        fail=$((fail + 1))
    fi
done

echo "--------------------------------------------------"
echo "synthesis: $pass passed, $fail failed, $skip skipped${LIB:+ (corner $CORNER)}"
[ $fail -eq 0 ]
