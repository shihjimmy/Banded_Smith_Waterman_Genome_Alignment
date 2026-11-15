# VCS (run inside testbench/ after `source license.sh`)
vcs tb_BSW.v +define+RTL -full64 -R -debug_access+all +v2k +notimingcheck              # B = 4
# other band:  python3 ../gen_pattern.py --band 8 --pairs <s.dat> <t.dat> --out pattern_b8
#              vcs tb_BSW.v +define+RTL+BAND=8+PAT_DIR=\"pattern_b8/\" -full64 -R +v2k
# gate level:  vcs tb_BSW.v +define+SDF -full64 -R -debug_access+all +v2k
# add +define+FSDB to dump BSW.fsdb for Verdi
