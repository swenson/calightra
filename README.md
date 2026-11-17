<!-- SPDX-License-Identifier: Apache-2.0 -->

# Calightra & Calightra-SS: Stripped Caliptra 2.1 RTL for Verilator, WebAssembly & Small Open-Source FPGAs

**Calightra** / **Calightra-SS** adapts [`chipsalliance/caliptra-ss`](https://github.com/chipsalliance/caliptra-ss) (`patch_ss_v2.1`) + [`caliptra-rtl`](https://github.com/chipsalliance/caliptra-rtl) (`patch_v2.1`) + [`adams-bridge`](https://github.com/chipsalliance/adams-bridge) (`v2.0.3`) + [`i3c-core`](https://github.com/chipsalliance/i3c-core) across two distinct stripping tiers with very different hardware capabilities:

> [!IMPORTANT]
> **Critical Distinction Between the Verilator/WASM Builds and the `CALIGHTRA_ICE40` FPGA Builds:**
> - **Verilator (`sim/`, `ss/sim/`) & Browser WebAssembly (`wasm/`, `www/`) — Unmasked Crypto Included (`CALIGHTRA_PHASE1` + `CALIGHTRA_NO_COUNTERMEASURES`)**: Retains all Caliptra 2.1 cryptographic engines (`SHA2-256`, `SHA2-384/512`, `SHA512_ACC`, `SHA3/SHAKE256`, `HMAC`, `AES-256-GCM`, `DOE`, `ECDSA/ECDH P-384`, `ML-DSA-87`, `ML-KEM-1024`), `KeyVault`, `PCRVault`, `DataVault`, and `axi_dma_top` (with side-channel masking/blinding countermeasures, SRAM ECC, and PMP/debug removed). Boots the **unmodified upstream production Caliptra 2.1 ROM** (`caliptra-rom.bin` / `caliptra-rom-with-log.bin`) and signed firmware bundle (`image-bundle-mldsa.bin`).
> - **Lattice ECP5-85F FPGA Builds (`fpga/`, `ss/fpga/`) — Crypto Engines, Vaults & AXI DMA Stubbed Out (`+ CALIGHTRA_ICE40`)**: Upstream Caliptra's unmasked parallel ASIC crypto blocks + flip-flop vaults total **`~410,000` LUT4s** (`ecc_top` P-384 alone is `125,677` LUTs, `adams-bridge` ML-DSA-87/ML-KEM-1024 is `~180,000+` LUTs, `aes_clp_wrapper` is `25,232` LUTs, `hmac_ctrl` is `17,925` LUTs) — roughly **5x larger than the entire `83,640`-LUT Lattice ECP5-85F** on the Radiona ULX3S-85F. Consequently, `CALIGHTRA_ICE40` **stubs out all cryptographic accelerators, `KeyVault`/`PCRVault`/`DataVault`, WDT, and `axi_dma_top`**. The current FPGA bitstreams **cannot** boot the real `caliptra-rom.bin` or verify signed firmware; `ss/fpga/` boots a standalone C MCU test ROM (`ss/fw/mcu_boot.c`) alongside `caliptra-sw`'s non-cryptographic **`fake-caliptra-rom.bin`** in on-chip EBR BRAM.

For granular architectural details, phase-by-phase stripping tables, exact what-is-included vs. what-is-stubbed breakdowns, and boot traces, see **[`DETAILS.md`](DETAILS.md)**.

---

## TL;DR — Bottom-Line Results

### 1. What Is Actually in `calightra_ss_ulx3s_top` (`ss/fpga/`, `CALIGHTRA_ICE40`)
- **Included Hardware RTL (Synthesized & Verified on Physical Radiona ULX3S-85F)**:
  - **Subsystem MCU (`css_mcu0_el2_veer_wrapper`)**: Stripped VeeR EL2 RISC-V core (`CALIGHTRA_NO_BP`, no PMP/div/bitmanip) booting `ss/fw/mcu_boot.c` (`8 KB` EBR ROM @ `0x8000_0000`) with `16 KB` EBR DCCM.
  - **Caliptra Core (`caliptra_top` with `CALIGHTRA_ICE40` stubs)**: Stripped VeeR EL2 RISC-V core + `soc_ifc_top` + `mbox` controller, booting upstream **`fw/fake-caliptra-rom.bin`** from `96 KB` on-chip EBR IMEM with `128 KB` mapped EBR DCCM (`PersistentData` + `Stack`) and `4 KB` EBR Mailbox SRAM, servicing `VERSION` (`"Caliptra RTM"`) and `CAPABILITIES` mailbox commands over AXI4.
  - **MCI (`mci_top` @ `0x2100_0000`)**: Boot sequencer, CSRs (readback-pruned via `CALIGHTRA_ICE40`), `MCU_MBOX0` (`4 KB` EBR @ `0x2140_0000`), and `MCU_SRAM` (`4 KB` EBR @ `0x21C0_0000`).
  - **OpenTitan Fuse & Lifecycle Controllers (`otp_ctrl` @ `0x7000_0000`, `lc_ctrl` @ `0x7000_0400`)**: Initialized to `DAI_IDLE` and `LcStTestUnlocked0`.
  - **MIPI I3C + OCP Recovery Target (`i3c_wrapper` @ `0x2000_4000`)**: I2C/I3C Standby Target, TTI, OCP Recovery protocol handler (`"OCP RECV"`), and `I3CCSR` (active-controller queues pruned via `CALIGHTRA_ICE40`).
  - **Open-Source AXI4 Crossbar ([`ss/rtl/calightra_ss_axi_xbar.sv`](ss/rtl/calightra_ss_axi_xbar.sv))**: `391 LUT4` 5-Manager $\times$ 7-Subordinate AXI4 crossbar with 64b $\leftrightarrow$ 32b width conversion, plus dual `4 KB` EBR USB-UART TX FIFOs and `115200 8N1` RX console on `/dev/ttyUSB0`.
- **Excluded / Stubbed Out on FPGA (`CALIGHTRA_ICE40`)**:
  - **All Caliptra Core Cryptographic Accelerators**: `sha256_ctrl`, `sha512_ctrl`, `sha512_acc_top`, `sha3_ctrl`, `hmac_ctrl`, `aes_clp_wrapper`, `doe_ctrl`, `ecc_top` (P-384), and `abr_top` (Adams Bridge ML-DSA-87 / ML-KEM-1024) are stubbed on AHB (`hrdata = 0x3`).
  - **All Hardware Vaults & Core AXI DMA**: `key_vault`, `pcr_vault`, `data_vault`, `wdt`, and `axi_dma_top` are stubbed out.
  - **Real `caliptra-rom.bin` & `caliptra-mcu-sw` ROM**: Because hardware KATs, DICE crypto, vaults, and `axi_dma_top` are absent in `CALIGHTRA_ICE40`, the current FPGA bitstream runs `ss/fw/mcu_boot.c` + `fw/fake-caliptra-rom.bin` (not `caliptra-rom.bin` or `ss/mcu-rom/`). Note also that [`calightra_i3c_ctrl.sv`](ss/rtl/calightra_i3c_ctrl.sv) is instantiated in the Verilator harness (`ss/sim/`), not inside `calightra_ss_ulx3s_top.sv`.

### 2. Open-Source FPGA Synthesis & Place-and-Route (`LFE5U-85F-6BG381C` on Radiona ULX3S-85F — **Crypto/Vaults/DMA Stubbed via `CALIGHTRA_ICE40`**)

| Target Design (`CALIGHTRA_ICE40`) | `TRELLIS_COMB` (LUT4 + Carry) | `TRELLIS_FF` (Flip-Flops) | `DP16KD` (18 Kb BRAM) | `MULT18X18D` (DSP) | Placed & Routed `Fmax` | What Boots |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **[`calightra_ss_ulx3s_top`](ss/fpga/calightra_ss_ulx3s_top.sv)** *(Dual VeeR EL2 + `mci` + `i3c` + `soc_ifc`/`mbox` + EBR SRAMs; **no crypto/vaults/DMA**)* | **`71,512 / 83,640` (`85%`)** | **`20,682 / 83,640` (`24%`)** | **`133 / 208` (`63%`)** | **`14 / 156` (`8%`)** | **`17.09 MHz`** *(PASS @ 12.5 MHz)* | Self-contained on bare ULX3S-85F (`mcu_boot.c` + `fake-caliptra-rom.bin`; live log in [`ss/fpga/ulx3s_hardware_uart.log`](ss/fpga/ulx3s_hardware_uart.log)) |
| **[`ulx3s_top`](fpga/ulx3s_top.sv)** *(Single VeeR EL2 + `soc_ifc`/`mbox` + QSPI bridge; **no crypto/vaults/DMA**)* | **`29,690 / 83,640` (`35%`)** | **`8,062 / 83,640` (`9%`)** | **`0 / 208` (`0%`)** | **`8 / 156` (`5%`)** | **`17.86 MHz`** *(PASS @ 12.5 MHz)* | Requires external QSPI RAM/Flash on GPIO header; **cannot** boot real `caliptra-rom.bin` |

### 3. Verilator Build & Simulation Benchmarks (Unmasked Crypto RTL Included — `CALIGHTRA_ICE40` **NOT** Defined)

| Benchmark | Build Time | Model Size | Sim Speed | Cycles | Wall-Clock Time | Exact Firmware & Key Result |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **`caliptra-ss` Real `caliptra-mcu-sw` ROM + 3-Stage 2-Wire I3C Recovery (Fake Core ROM/Bundle)** ([`ss/sim/`](ss/sim/), `make run-recovery`) | `62.88 s` | `10.1 MB` | `2.25 kHz` | `47,834,229` | `21,264.0 s` | Real `caliptra-mcu-sw` ROM + **`fake-caliptra-rom.bin`** + **`fake-image-bundle-mldsa.bin`** + signed `soc_manifest.bin` + `mcu_rt.bin`: [`calightra_i3c_ctrl`](ss/rtl/calightra_i3c_ctrl.sv) streams all 3 images over 2-wire `SCL`/`SDA` with PEC $\to$ ML-DSA-87 + ECC-384 SoC manifest verify $\to$ `CM_SHA384` ROM digest $\to$ warm reset $\to$ `mcu_rt.bin` @ `0x21C0_0000` (`TEST PASS`, [`ss_i3c_recovery_sim.log`](ss/sim/ss_i3c_recovery_sim.log)) |
| **`caliptra-ss` C MCU ROM + Production Core ROM** ([`ss/sim/`](ss/sim/), [`ss_boot_sim.log`](ss/sim/ss_boot_sim.log)) | `60.73 s` | `10.1 MB` | `2.18 kHz` | `5,136,713` | `2,351.2 s` | `ss/fw/mcu_rom.bin` + **unmodified `caliptra-rom.bin`** passes all hardware ROM KATs + `IDevID` and reaches `READY_FOR_MB_PROCESSING=1` |
| **`caliptra-rtl` Standalone Core ROM Boot** ([`sim/`](sim/), vs. unstripped baseline) | `53.69 s` *(was `404.2s`, **7.53x faster**)* | `5.6 MB` *(was `108 MB`, **19.3x smaller**)* | `2.54 kHz` *(was `1.53 kHz`)* | `4,626,321` *(was `5,548,472`)* | `1,821.2 s` *(was `3,636.3s`)* | **Unmodified `caliptra-rom.bin`** (`rom-2.1.3`) passes all ROM KATs and reaches `ready_for_mb_processing=1` |
| **`caliptra-rtl` Standalone Core Full End-to-End Boot** (`ROM` $\to$ `FMC` $\to$ `Runtime` $\to$ `FW_INFO`) | `53.69 s` | `5.6 MB` | `2.48 kHz` | `31,502,733` | `12,713.6 s` | **Unmodified `caliptra-rom.bin` + `image-bundle-mldsa.bin`** (`fw-2.1.4`) completes 3 DICE layers, P-384 + ML-DSA-87 `FW_LOAD`, `ready_for_runtime=1`, and `FW_INFO` (`fips_status=0`) |

---

## Radiona ULX3S-85F Pin Wiring (`ss/fpga/ulx3s_v20.lpf`)

- **USB-UART Console (`ftdi_rxd` `L4`, `ftdi_txd` `M1` @ `115200 8N1`)**: Streams `[MCU]` and Caliptra Core `fake-caliptra-rom.bin` console output over `/dev/ttyUSB0` and accepts interactive commands (`v` = `VERSION`, `c` = `CAPABILITIES`, `s` = `STATUS`, `r` = hardware cold reset).
- **ESP32 SPI-to-AXI4 Master (`esp_sck` `wifi_gpio16` `L1`, `esp_cs_n` `wifi_gpio5` `N4`, `esp_mosi` `wifi_gpio17` `N3`, `esp_miso` `wifi_gpio12` `K1`)**: 96-bit SPI transactions read/write 32-bit AXI4 addresses across the subsystem crossbar.
- **MIPI I3C / I2C Target Pins (`0x5A` / `0x5B`)**:
  - `i3c_scl` (`F4`) & `i3c_sda` (`E3`): Shared on the ULX3S PCB between onboard ESP32 (`wifi_gpio26` / `wifi_gpio25`) and J1 header (`gp[11]` / `gn[11]`).
  - `ext_i3c_scl` (`A7`) & `ext_i3c_sda` (`A8`): Dedicated J1 header pins (`gp[4]` / `gn[4]`).

---

## Browser RTL Simulator (WebAssembly — GitHub Pages)

Try **Calightra's stripped Caliptra 2.1 Core RTL** (`CALIGHTRA_PHASE1` + `CALIGHTRA_NO_COUNTERMEASURES`, **without** `CALIGHTRA_ICE40` — so all unmasked crypto engines and vaults are present) in your browser at **[`https://swenson.github.io/calightra/`](https://swenson.github.io/calightra/)**:
- **Stripped Core RTL in a `3.5 MB` `.wasm` Binary ([`wasm/`](wasm/), [`www/`](www/))**: Compiles Calightra's modified `caliptra_top` (`VeeR EL2` + Adams Bridge ML-DSA-87/ML-KEM-1024 + unmasked SHA2-512/384, SHA3/SHAKE256, HMAC, AES-256-GCM, P-384 ECC, KeyVault, PCR Vault, Mailbox SRAM, and SoC Interface) via Verilator + Emscripten (`-msimd128`).
- **Real Caliptra 2.1 ROM & Firmware by Default + Optional Fake-ROM Mode**: Defaults to unmodified upstream `caliptra-rom-with-log.bin` + `image-bundle-mldsa.bin`, with UI selectors to switch between Real ROM and `fake-caliptra-rom.bin`.

---

## Quick Start

### 1. Calightra-SS Dual-Core Subsystem (`ss/`)
```bash
# Build real caliptra-mcu-sw (main-2.1) ROM + signed SoC Manifest + MCU Runtime (for Verilator ss/sim/)
make -C ss/mcu-rom

# Run Verilator 3-stage I3C Recovery flow (real caliptra-mcu-sw ROM + fake Core ROM/bundle + signed SoC Manifest)
make -C ss/sim run-recovery

# Run Verilator full production-crypto 3-stage I3C Recovery flow (real caliptra-mcu-sw ROM + real Core ROM/bundle)
make -C ss/sim run-recovery-full

# Synthesize & P&R ULX3S-85F bitstream (CALIGHTRA_ICE40: crypto/vaults/DMA stubbed, boots mcu_boot.c + fake-caliptra-rom.bin)
make -C ss/fpga clean all

# Program ULX3S-85F SRAM over JTAG and capture live /dev/ttyUSB0 UART logs
python3 ss/fpga/ulx3s_run.py --bit ss/fpga/calightra_ss_ulx3s_85f.bit --port /dev/ttyUSB0
```

### 2. Standalone Calightra Core (`sim/` & `fpga/`)
```bash
# Build and run stripped Caliptra Core Verilator simulator (full unmasked crypto, boots real caliptra-rom.bin)
make -C sim phase2
make -C sim run-phase2
make -C sim run-full-phase2

# Synthesize standalone non-crypto CPU/mailbox shell on ULX3S-85F (CALIGHTRA_ICE40: crypto/vaults/DMA stubbed)
make -C fpga ulx3s-85f
```

### 3. Browser RTL Simulator (`wasm/` & `www/`)
```bash
./build-wasm.sh
node tests/browser/boot-test.mjs
```

---

## Documentation & License

- **[`DETAILS.md`](DETAILS.md)**: Detailed architecture, exact stripping phase definitions (`CALIGHTRA_PHASE1`, `CALIGHTRA_NO_COUNTERMEASURES`, `CALIGHTRA_NO_BP`, `CALIGHTRA_ICE40`), block-level LUT4 costs showing why upstream ASIC crypto exceeds an 85K-LUT ECP5, AXI4 crossbar map, and boot traces.
- **[`LICENSE`](LICENSE)**: Licensed under the **Apache License, Version 2.0** (`SPDX-License-Identifier: Apache-2.0`), matching upstream Caliptra.
