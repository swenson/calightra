<!-- SPDX-License-Identifier: Apache-2.0 -->

# Calightra-SS: Stripped Caliptra 2.1 Subsystem for Fast Verilator Simulation & Open-Source FPGAs

**Calightra-SS** (`main` and `caliptra-ss` branches) is a stripped-down, 100% binary-compatible implementation of the full **Caliptra 2.1 Subsystem** ([`chipsalliance/caliptra-ss`](https://github.com/chipsalliance/caliptra-ss) `patch_ss_v2.1` + [`caliptra-rtl`](https://github.com/chipsalliance/caliptra-rtl) `patch_v2.1` + [`adams-bridge`](https://github.com/chipsalliance/adams-bridge) `v2.0.3` + [`i3c-core`](https://github.com/chipsalliance/i3c-core)) engineered to:
1. **Synthesize, place, and route on a single open-source Lattice ECP5-85F FPGA** (**Radiona ULX3S-85F**, `LFE5U-85F-6BG381C`) using `sv2v` + `yosys` + `nextpnr-ecp5` + `ecppack`.
2. **Simulate the full dual-VeeR-EL2 subsystem in Verilator**, booting the real [`chipsalliance/caliptra-mcu-sw`](https://github.com/chipsalliance/caliptra-mcu-sw) (`main-2.1`) Rust MCU ROM ([`ss/mcu-rom/`](ss/mcu-rom/)) alongside the unmodified [`chipsalliance/caliptra-sw`](https://github.com/chipsalliance/caliptra-sw) 2.1 Core ROM (`caliptra-rom.bin`) and firmware (`image-bundle-mldsa.bin`) through the complete **3-stage MIPI I3C / OCP Recovery streaming boot flow** (`ColdBoot` $\to$ `RI_DOWNLOAD_FIRMWARE` $\to$ `Image 0` Caliptra FMC+RT $\to$ `Image 1` MLDSA-87/ECC-384 SoC Authorization Manifest $\to$ `Image 2` MCU Runtime Firmware $\to$ `CM_SHA384` ROM digest check $\to$ `STASH_MEASUREMENT` $\to$ warm reset $\to$ `FwBoot` $\to$ MCU Runtime execution in SRAM @ `0x21C0_0000`).

For the standalone Caliptra Core (`caliptra-rtl` without the subsystem MCU/MCI/I3C/OTP/LC), see [`sim/`](sim/), [`fpga/`](fpga/), or the **`caliptra-core` branch**. For granular architectural details, phase-by-phase stripping tables, and full boot traces, see **[`DETAILS.md`](DETAILS.md)**.

---

## TL;DR — Bottom-Line Results

### 1. What Is Included in `calightra_ss_ulx3s_top` (`ss/fpga/`)
- **Dual VeeR EL2 RISC-V Cores**:
  - **Subsystem MCU (`css_mcu0_el2_veer_wrapper`)**: Boots from MCU ROM (`0x8000_0000`) with `16 KB` DCCM in ECP5 EBR BRAM.
  - **Caliptra Core (`caliptra_top`)**: Boots unmodified `caliptra-rom.bin` with unmasked SHA2-512/384, SHA3/SHAKE256, HMAC, AES-256-GCM, ECDSA/ECDH P-384, ML-DSA-87, and ML-KEM-1024, plus an external QSPI RAM bridge (`calightra_spi_ram_bridge.sv`) for core SRAMs.
- **Full Subsystem Peripherals**:
  - **MCI (`mci_top` @ `0x2100_0000`)**: Boot sequencer, CSRs, `MCU_MBOX0` (`0x2140_0000`), and `MCU_SRAM` (`0x21C0_0000`).
  - **OpenTitan Fuse & Lifecycle Controllers (`otp_ctrl` @ `0x7000_0000`, `lc_ctrl` @ `0x7000_0400`)**: Initialized to `DAI_IDLE` and `LcStTestUnlocked0`.
  - **Full MIPI I3C + OCP Recovery Core (`i3c_wrapper` @ `0x2000_4000`)**: I2C/I3C Standby Target (`0x5A`), Target Transaction Interface (TTI), OCP Recovery protocol handler (`0x5B`, `"OCP RECV"`), and `I3CCSR` wired directly to the ULX3S-85F's onboard **ESP32** and **external J1 GPIO header**.
- **Open-Source Apache-2.0 AXI4 Crossbar ([`ss/rtl/calightra_ss_axi_xbar.sv`](ss/rtl/calightra_ss_axi_xbar.sv))**: Replaces the proprietary simulation VIP interconnect with a `391 LUT4` 5-Manager $\times$ 7-Subordinate AXI4 crossbar with 64b $\leftrightarrow$ 32b width conversion.
- **Independent Open-Source Apache-2.0 MIPI I3C Controller IP ([`ss/rtl/calightra_i3c_ctrl.sv`](ss/rtl/calightra_i3c_ctrl.sv))**: Synthesizable `1,251 LUT4` / `386 FF` MIPI I3C Basic v1.1.1 SDR Controller (Master) with a Xilinx `XI3C`-compatible MMIO register interface (`CMD_FIFO`, `WR_FIFO`, `RD_FIFO`, `RESP_STATUS_FIFO`), broadcast/direct CCC support (`RSTDAA`, `SETDASA`), MIPI I3C `AckHandoff` / `TReadEnd` handoff, hardware odd-parity `T-bit` generation/checking, and hardware SMBus CRC-8 (`0x07`) PEC engine — wired to `caliptra_ss_top` exclusively via the 2-wire `i3c_scl` / `i3c_sda` bus so `i3c-core` never "grades its own homework".

### 2. Open-Source FPGA Synthesis & Place-and-Route (`LFE5U-85F-6BG381C` on Radiona ULX3S-85F)

| Target Design | `TRELLIS_COMB` (LUT4 + Carry) | `TRELLIS_FF` (Flip-Flops) | `DP16KD` (18 Kb BRAM) | `MULT18X18D` (DSP) | `TRELLIS_IO` (Pins) | Placed & Routed `Fmax` | Bitstream |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **[`calightra_ss_ulx3s_top`](ss/fpga/calightra_ss_ulx3s_top.sv)** *(Full Dual-Core `caliptra-ss` + `i3c_wrapper` + AXI4 Xbar)* | **`71,479 / 83,640` (`85%`)** | **`20,317 / 83,640` (`24%`)** | **`16 / 208` (`7%`)** | **`14 / 156` (`8%`)** | **`29 / 365` (`7%`)** | **`15.54 MHz`** *(PASS @ 12.5 MHz)* | [`ss/fpga/calightra_ss_ulx3s_85f.bit`](ss/fpga/calightra_ss_ulx3s_85f.bit) (`1.4 MB`) |
| **[`ulx3s_top`](fpga/ulx3s_top.sv)** *(Standalone `caliptra-rtl` Core)* | **`29,690 / 83,640` (`35%`)** | **`8,062 / 83,640` (`9%`)** | **`0 / 208` (`0%`)** | **`8 / 156` (`5%`)** | **`25 / 365` (`6%`)** | **`17.86 MHz`** *(PASS @ 12.5 MHz)* | [`fpga/calightra_ulx3s_85f.bit`](fpga/calightra_ulx3s_85f.bit) (`721 KB`) |

### 3. Verilator Build & Simulation Performance

| Benchmark | Build Time | Model Size | Sim Speed | Cycles | Wall-Clock Time | Key Result |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **`caliptra-ss` Real `caliptra-mcu-sw` ROM + Full 3-Stage 2-Wire I3C Recovery** ([`ss/sim/`](ss/sim/)) | **`62.88 s`** | `10.1 MB` | **`2.25 kHz`** | **`47,834,229`** | **`21,264.0 s`** | Independent [`calightra_i3c_ctrl`](ss/rtl/calightra_i3c_ctrl.sv) assigns dynamic addresses (`RSTDAA`, `SETDASA` `0x3A`$\to$`0x08`, `0x3B`$\to$`0x09`) over `SCL`/`SDA` $\to$ `ColdBoot` reaches `READY_FOR_MB_PROCESSING=1` $\to$ `RI_DOWNLOAD_FIRMWARE` streams **3 images (`258.8 KB`) over the 2-wire I3C bus with hardware PEC** (`Image 0` Caliptra FMC+RT, `Image 1` MLDSA-87/ECC-384 SoC Manifest, `Image 2` MCU RT) $\to$ `FW_EXEC_CTRL[2]=1` & `ready_for_runtime=1` $\to$ `CM_SHA384` ROM digest & `STASH_MEASUREMENT` $\to$ warm reset $\to$ `FwBoot` jumps to `mcu_rt.bin` @ `0x21C0_0000` (`TEST PASS`) |
| **`caliptra-ss` Real `caliptra-mcu-sw` ROM + Production Core ROM (`READY_FOR_MB_PROCESSING`)** ([`ss/sim/`](ss/sim/)) | **`62.88 s`** | `10.1 MB` | **`2.22 kHz`** | **`7,448,186`** | **`3,354.1 s`** | Real `caliptra-mcu-sw` ROM initializes `LCC`/`OTP`/`I3C`, populates fuses over DAI, verifies PK hashes & mailbox users, boots unmodified `caliptra-rom.bin` through `READY_FOR_MB_PROCESSING=1`, and issues `RI_DOWNLOAD_FIRMWARE` |
| **`caliptra-rtl` Core ROM Boot** ([`sim/`](sim/), vs. unstripped baseline) | **`53.69 s`** *(was `404.2s`, **7.53x faster**)* | **`5.6 MB`** *(was `108 MB`, **19.3x smaller**)* | **`2.54 kHz`** *(was `1.53 kHz`, **1.66x faster**)* | **`4,626,321`** *(was `5,548,472`, **`-16.6%`**)* | **`1,821.2 s`** *(was `3,636.3s`, **2.00x faster**)* | Unmodified `caliptra-rom.bin` (`rom-2.1.3`) passes all ROM KATs and reaches `ready_for_mb_processing=1` |
| **`caliptra-rtl` Full End-to-End Boot** (`ROM` $\to$ `FMC` $\to$ `Runtime` $\to$ `FW_INFO`) | **`53.69 s`** | **`5.6 MB`** | **`2.48 kHz`** | **`31,502,733`** | **`12,713.6 s`** | Unmodified `caliptra-rom.bin` + `image-bundle-mldsa.bin` (`fw-2.1.4`) completes 3 DICE layers, P-384 + ML-DSA-87 `FW_LOAD`, `ready_for_runtime=1`, and `FW_INFO` (`fips_status=0`) |

---

## Radiona ULX3S-85F Host Wiring (ESP32 + External J1 Header)

On the ULX3S-85F ([`ss/fpga/calightra_ss_ulx3s_top.sv`](ss/fpga/calightra_ss_ulx3s_top.sv) + [`ss/fpga/ulx3s_v20.lpf`](ss/fpga/ulx3s_v20.lpf)), both the onboard **ESP32** and an **external host** can interact with the subsystem:
- **ESP32 SPI-to-AXI4 Master (`wifi_gpio14` SCLK, `wifi_gpio13` MOSI, `wifi_gpio12` MISO, `wifi_gpio4` CS_N)**: 96-bit SPI transactions read/write any 32-bit AXI4 address (`MCI`, `Caliptra Core`, `OTP_CTRL`, `LC_CTRL`, `I3C`, `SOC_SRAM`).
- **MIPI I3C / I2C Target + OCP Recovery (`0x5A` / `0x5B`)**:
  - `i3c_scl` (`SITE "F4"`) & `i3c_sda` (`SITE "E3"`): Routed on the ULX3S PCB to **both** the onboard **ESP32 (`GPIO26` / `GPIO25`)** and J1 GPIO header **`gp[11]` / `gn[11]`**.
  - `ext_i3c_scl` (`SITE "A7"`) & `ext_i3c_sda` (`SITE "A8"`): Dedicated external J1 GPIO header pins **`gp[4]` / `gn[4]`** wired-AND to the I3C controller for an external BMC/host or logic analyzer.
- **USB-UART Console (`ftdi_rxd` @ `115200 8N1`)**: Streams live `[MCU]` and Caliptra Core console output over USB.

---

## Quick Start

### Prerequisites (Ubuntu / Debian)
```bash
sudo apt-get install -y verilator yosys nextpnr-ice40 nextpnr-ecp5 fpga-icestorm fpga-trellis gcc-riscv64-unknown-elf ccache
# Plus sv2v (https://github.com/zachjs/sv2v/releases) in PATH
```

### 1. Calightra-SS Dual-Core Subsystem (`ss/`)
```bash
# Build real caliptra-mcu-sw (main-2.1) ROM + signed SoC Manifest + MCU Runtime (ss/mcu-rom/)
make -C ss/mcu-rom

# Run Calightra-SS Verilator simulation through READY_FOR_MB_PROCESSING=1 + RI_DOWNLOAD_FIRMWARE
make -C ss/sim run

# Run full 3-stage I3C Recovery flow (Image 0 FMC+RT + Image 1 SoC Manifest + Image 2 MCU RT -> FwBoot)
make -C ss/sim run-recovery

# Synthesize, place-and-route, and pack the Radiona ULX3S-85F bitstream (ss/fpga/calightra_ss_ulx3s_85f.bit)
make -C ss/fpga clean all
```

### 2. Standalone Calightra Core (`sim/` & `fpga/`)
```bash
# Build and run stripped Caliptra Core Verilator simulator (ROM boot or full ROM -> FMC -> Runtime boot)
make -C sim phase2
make -C sim run-phase2
make -C sim run-full-phase2

# Synthesize and place-and-route standalone Caliptra Core on ULX3S-85F (fpga/calightra_ulx3s_85f.bit)
make -C fpga ulx3s-85f
```

---

## Documentation & License

- **[`DETAILS.md`](DETAILS.md)**: Full architectural diagrams, stripping phases (`CALIGHTRA_PHASE1`, `CALIGHTRA_NO_COUNTERMEASURES`, `CALIGHTRA_NO_BP`, `CALIGHTRA_ICE40`), hierarchical LUT4/FF breakdown, AXI4 crossbar address map, and Verilator boot logs.
- **[`LICENSE`](LICENSE)**: Licensed under the **Apache License, Version 2.0** (`SPDX-License-Identifier: Apache-2.0`), matching upstream Caliptra.
