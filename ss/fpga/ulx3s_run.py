#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Program Radiona ULX3S-85F SRAM and capture live Calightra-SS UART logs."""

import argparse
import shutil
import subprocess
import sys
import time
import serial


def open_serial_retry(port: str, baud: int, timeout_s: float = 5.0) -> serial.Serial:
    deadline = time.monotonic() + timeout_s
    last_err = None
    while time.monotonic() < deadline:
        try:
            ser = serial.Serial(
                port=port,
                baudrate=baud,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.05,
                xonxoff=False,
                rtscts=False,
                dsrdtr=False,
            )
            ser.reset_input_buffer()
            return ser
        except Exception as e:
            last_err = e
            time.sleep(0.01)
    raise RuntimeError(f"Timed out waiting for {port} after JTAG load: {last_err}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fujprog", default=shutil.which("fujprog") or "fujprog")
    ap.add_argument("--bit", default="calightra_ss_ulx3s_85f.bit")
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-prog", action="store_true", help="Skip fujprog SRAM load and send 'r' cold reset")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if not args.no_prog:
        print(f"[host] Programming ULX3S-85F SRAM with {args.bit} ...")
        subprocess.run([args.fujprog, "-j", "sram", args.bit], check=True)

    ser = open_serial_retry(args.port, args.baud)
    print(f"[host] Opened {args.port} @ {args.baud} 8N1 — listening for Calightra-SS UART...\n")

    if args.no_prog:
        ser.write(b"r")
        ser.flush()

    captured = bytearray()
    t0 = time.monotonic()
    sent_interactive = False
    done_time = None

    while time.monotonic() - t0 < 20.0:
        chunk = ser.read(1024)
        if chunk:
            captured.extend(chunk)
            sys.stdout.write(chunk.decode("utf-8", errors="replace"))
            sys.stdout.flush()

            txt = captured.decode("utf-8", errors="replace")
            if not sent_interactive and "Interactive UART console ready" in txt:
                sent_interactive = True
                time.sleep(0.15)
                print("\n[host] Sending live UART command 's' (STATUS) & 'v' (VERSION) over /dev/ttyUSB0...")
                ser.write(b"s")
                ser.flush()
                time.sleep(0.25)
                ser.write(b"v")
                ser.flush()
                done_time = time.monotonic() + 1.0

        if done_time is not None and time.monotonic() >= done_time:
            break

    ser.close()
    if args.out:
        with open(args.out, "wb") as f:
            f.write(captured)
        print(f"\n[host] Saved {len(captured)} bytes to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
