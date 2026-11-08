#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import subprocess
import sys

BLOCKS = [
    ("hmac_ctrl", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("aes_clp_wrapper", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("ecc_top", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("doe_ctrl", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("sha256_ctrl", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("sha512_ctrl", "/home/swenson/calightra/fpga/calightra_synth.vf"),
    ("caliptra_spi_ram_bridge", "/home/swenson/calightra/fpga/calightra_synth.vf"),
]

def run_cmd(cmd):
    res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return res.stdout

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "hmac_ctrl"
    for mode, defs in [
        ("baseline", []),
        ("phase2", ["--define", "CALIGHTRA_PHASE1", "--define", "CALIGHTRA_NO_COUNTERMEASURES", "--define", "RV_FPGA_OPTIMIZE"]),
    ]:
        out_v = f"/home/swenson/calightra/fpga/{target}_{mode}.v"
        cmd = ["python3", "/home/swenson/calightra/fpga/run_sv2v.py", "--top", target, "--out", out_v] + defs
        subprocess.run(cmd, check=True)
        ys_cmd = (
            f"yosys -p 'read_verilog -D ICE40_HX -lib -specify +/ice40/cells_sim.v; "
            f"read_verilog -sv {out_v}; hierarchy -check -top {target}; proc; opt -fast; "
            f"synth_ice40 -top {target} -dsp -noabc9' | grep -A 28 'Printing statistics'"
        )
        print(f"=== {target} ({mode}) ===")
        print(run_cmd(ys_cmd))

if __name__ == "__main__":
    main()
