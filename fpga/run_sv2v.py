#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys

def main():
    parser = argparse.ArgumentParser(description="Run sv2v on Calightra VF filelist")
    parser.add_argument("--vf", default="/home/swenson/calightra/fpga/calightra_synth.vf")
    parser.add_argument("--top", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--define", action="append", default=[])
    args = parser.parse_args()

    caliptra_root = "/home/swenson/calightra/caliptra-rtl"
    env_vars = {
        "${CALIPTRA_ROOT}": caliptra_root,
        "${CALIPTRA_PRIM_ROOT}": f"{caliptra_root}/src/caliptra_prim_generic",
        "${CALIPTRA_PRIM_MODULE_PREFIX}": "caliptra_prim_generic",
        "${CALIPTRA_AXI4PC_DIR}": "/home/swenson/calightra/sim",
    }

    incdirs = []
    files = []
    with open(args.vf, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            for k, v in env_vars.items():
                line = line.replace(k, v)
            if line.startswith("+incdir+"):
                incdirs.append("-I" + line[len("+incdir+"):])
            else:
                files.append(line)

    cmd = ["/usr/local/bin/sv2v", "--top=" + args.top]
    for d in ["RV_OPENSOURCE", "SYNTHESIS"] + args.define:
        cmd.append("-D" + d)
    cmd.extend(incdirs)
    cmd.extend(files)

    print(f"Running sv2v for top={args.top} defines={args.define} -> {args.out}")
    with open(args.out, "w") as out_f:
        res = subprocess.run(cmd, stdout=out_f, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        sys.exit(res.returncode)
    if res.stderr:
        print("sv2v warnings/messages:\n" + res.stderr[:1000])
    with open(args.out, "r") as f:
        txt = f.read()
    import re
    txt2 = re.sub(r"\d+'h[0-9a-fA-F]+\[(\d+-:\d+)\]", r"pt[\1]", txt)
    if txt2 != txt:
        with open(args.out, "w") as f:
            f.write(txt2)
    print(f"Successfully wrote {args.out} ({os.path.getsize(args.out)} bytes)")

if __name__ == "__main__":
    main()
