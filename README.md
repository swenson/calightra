<!-- SPDX-License-Identifier: Apache-2.0 -->

# Calightra: Stripped Caliptra 2.1 RTL for Fast Verilator Simulation & Open-Source FPGAs

**Calightra** (`caliptra-core` branch) is a stripped-down, 100% binary-compatible implementation of [`chipsalliance/caliptra-rtl`](https://github.com/chipsalliance/caliptra-rtl) (`patch_v2.1` branch `188b0b0e` + [`adams-bridge`](https://github.com/chipsalliance/adams-bridge) `v2.0.3` `b77e3d89`) engineered to:
1. **Simulate at high speed in Verilator**: **7.53x faster** compilation, **19.3x smaller** model, and **2.00x faster** wall-clock boot of the unmodified [`chipsalliance/caliptra-sw`](https://github.com/chipsalliance/caliptra-sw) 2.1 release binaries (`rom-2.1.3-1`: `caliptra-rom.bin` + `image-bundle-mldsa.bin` `fw-2.1.4`).
2. **Synthesize, place, and route on small open-source Lattice FPGAs** (**Radiona ULX3S-85F** / **ECP5-45F** / **iCE40**) using `sv2v` + `yosys` + `nextpnr` + `ecppack`, stripping side-channel countermeasures (DOM masking, scalar blinding, LFSRs), SRAM SECDED ECC (`39b` $\to$ `32b`), and VeeR EL2 branch predictors/PMP/debug while bridging all 608 KB of SRAM/ROM over a `728 LUT4` external QSPI RAM/Flash controller (`0` internal BRAMs required).

For the full **Caliptra 2.1 Subsystem** (dual VeeR EL2 cores, MCI, OpenTitan Fuse/Lifecycle controllers, full MIPI I3C + OCP Recovery core, and open-source AXI4 crossbar), see the **`main` (or `caliptra-ss`) branch**. For granular architectural details, phase-by-phase stripping tables, and full boot traces, see **[`DETAILS.md`](DETAILS.md)**.

---

## TL;DR — Bottom-Line Results

### 1. Open-Source FPGA Synthesis & Place-and-Route (`sv2v` + `yosys` + `nextpnr`)

| Target Design / Device | LUT4 / `TRELLIS_COMB` | Flip-Flops (`FF`) | BRAM (`DP16KD`) | DSP (`MULT18X18D` / `MAC16`) | I/O Pins | Placed & Routed `Fmax` |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Radiona ULX3S-85F (`LFE5U-85F-6BG381C`)** ([`fpga/ulx3s_top.sv`](fpga/ulx3s_top.sv)) | **`29,690 / 83,640` (`35%`)** | **`8,062 / 83,640` (`9%`)** | **`0 / 208` (`0%`)** | **`8 / 156` (`5%`)** | **`25 / 365` (`6%`)** | **`17.86 MHz`** *(PASS @ 12.5 MHz)* |
| **Generic Lattice ECP5-45F (`LFE5U-45F-CABGA381`)** ([`fpga/calightra_fpga_top.sv`](fpga/calightra_fpga_top.sv)) | **`30,830 / 43,848` (`70%`)** | **`7,782 / 43,848` (`17%`)** | **`0 / 108` (`0%`)** | **`8 / 72` (`11%`)** | **`151 / 245` (`61%`)** | **`16.86 MHz`** *(PASS @ 12.0 MHz)* |
| **Lattice iCE40 Synthesis (`synth_ice40 -dsp`)** ([`calightra_spi_top`](fpga/calightra_fpga_top.sv)) | **`22,995` `SB_LUT4`** *(down from >600k)* | **`7,780` `SB_DFF*`** *(0 latches)* | **`0` BRAMs** | **`4` `SB_MAC16`** | — | — |

### 2. Verilator Build & Simulation Performance (`sim/`)

| Metric | Unstripped Baseline (`patch_v2.1`) | Calightra (`PHASE1` + `NO_COUNTERMEASURES`) | Improvement |
| :--- | :---: | :---: | :---: |
| **Verilator Build Time** | `404.21 s` | **`53.69 s`** | **7.53x faster** (`-86.7%`) |
| **Verilated Archive (`libcaliptra_verilated.a`)** | `108.0 MB` | **`5.6 MB`** | **19.3x smaller** (`-94.8%`) |
| **ROM Boot (`cycle 0` $\to$ `ready_for_mb_processing`)** | `5,548,472` cycles (`3,636.3 s` @ `1.53 kHz`) | **`4,626,321` cycles (`1,821.2 s` @ `2.54 kHz`)** | **`-922,151` cycles (`-16.6%`) / 2.00x faster wall-clock** |
| **Full End-to-End Boot (`ROM` $\to$ `FMC` $\to$ `Runtime` $\to$ `FW_INFO`)** | — | **`31,502,733` cycles (`12,713.6 s` @ `2.48 kHz`)** | Unmodified `caliptra-rom.bin` + `image-bundle-mldsa.bin` passes all KATs, 3 DICE layers, P-384 + ML-DSA-87 `FW_LOAD`, `ready_for_runtime=1`, and `FW_INFO` (`396` bytes, `fips_status=0`) |

---

## Radiona ULX3S-85F Host Interface (`fpga/ulx3s_top.sv` + `fpga/ulx3s_v20.lpf`)

- **ESP32 SPI-to-AXI4-Lite Host Bridge (`wifi_gpio14` SCLK, `wifi_gpio13` MOSI, `wifi_gpio12` MISO, `wifi_gpio4` CS_N)**: 96-bit SPI transactions let the onboard ESP32 program fuses, assert `BOOTFSM_GO`, stream firmware into the mailbox, and read status CSRs.
- **External QSPI RAM/Flash Bridge (`qspi_csn`, `qspi_sck`, `qspi_io[3:0]` on `gp/gn[5..7]`)**: Maps all 608 KB of Caliptra SRAM/ROM (`96 KB` ROM + `128 KB` ICCM + `128 KB` DCCM + `256 KB` Mailbox SRAM) over a 6-pin QSPI interface using `0` internal BRAMs (leaving all `208` `DP16KD` EBR blocks / `416 KB` free on the `85F`).
- **USB-UART Console (`ftdi_rxd` @ `115200 8N1`) & 8 Status LEDs (`led[7:0]`)**: Streams Caliptra `CPTRA_GENERIC_OUTPUT_WIRES` console bytes over USB and displays live boot milestones on LEDs `D7..D0`.

---

## Quick Start

### Prerequisites (Ubuntu / Debian)
```bash
sudo apt-get install -y verilator yosys nextpnr-ice40 nextpnr-ecp5 fpga-icestorm fpga-trellis ccache
# Plus sv2v (https://github.com/zachjs/sv2v/releases) in PATH
```

### 1. Verilator Simulation (`sim/`)
```bash
# Build Phase 2 Verilator simulator (~53 seconds)
make -C sim phase2

# Run ROM boot + KATs to ready_for_mb_processing (4,626,321 cycles)
make -C sim run-phase2

# Run full end-to-end boot: ROM -> FMC -> Runtime -> FW_INFO (31,502,733 cycles)
make -C sim run-full-phase2
```

### 2. Open-Source FPGA Synthesis & Place-and-Route (`fpga/`)
```bash
# Synthesize, place-and-route, and pack Radiona ULX3S-85F bitstream (35% LUT4, 17.86 MHz Fmax)
make -C fpga ulx3s-85f

# Synthesize for Lattice iCE40 (22,995 SB_LUT4) or place-and-route on generic ECP5-45F (70% LUT4)
make -C fpga ice40
make -C fpga pnr-ecp5

# Run baseline vs. stripped synthesis comparison on individual blocks (el2_veer, hmac_ctrl, aes, ecc_top)
make -C fpga blocks
```

---

## Documentation & License

- **[`DETAILS.md`](DETAILS.md)**: Full architectural diagrams, stripping phases (`CALIGHTRA_PHASE1`, `CALIGHTRA_NO_COUNTERMEASURES`, `CALIGHTRA_NO_BP`, `CALIGHTRA_ICE40`), block-by-block LUT4/FF breakdown, FPGA board comparison table, and 31.5M-cycle boot log.
- **[`LICENSE`](LICENSE)**: Licensed under the **Apache License, Version 2.0** (`SPDX-License-Identifier: Apache-2.0`), matching upstream Caliptra.
