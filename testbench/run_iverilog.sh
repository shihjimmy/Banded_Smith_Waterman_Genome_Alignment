#!/bin/sh
# Open-source flow (Icarus Verilog >= 11). Run inside testbench/.
#   sh run_iverilog.sh            -> B = 4 on testbench/pattern
#   sh run_iverilog.sh stress     -> additionally random stress tests on many (L, B)
set -e
run() {
    label=$1; shift
    iverilog -g2005 -DRTL "$@" -o /tmp/tb_BSW.vvp tb_BSW.v 2>&1 | grep -v "sensitive to all" || true
    printf '%-28s ' "$label"
    vvp -n /tmp/tb_BSW.vvp | grep -E 'ALL .* PASS|FAIL :|Time out' || echo "no result"
}
run "L=256 B=4"
if [ "$1" = "stress" ]; then
    for cfg in "256 8" "256 16" "16 1" "16 2" "16 3" "16 5" "16 16" "32 7" "64 13" "64 64"; do
        set -- $cfg
        d=/tmp/bsw_stress_$1_$2/
        n=60; [ $1 -ge 256 ] && n=10
        python3 ../gen_pattern.py --length $1 --band $2 --random $n --seed $(( $1 * 7 + $2 )) --out $d > /dev/null
        run "L=$1 B=$2 ($n random)" -DSEQ_L=$1 -DBAND=$2 -DPAT_DIR=\"$d\" -DNCASE=$n
    done
fi
