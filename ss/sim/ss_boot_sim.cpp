// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Calightra-SS Verilator C++ Harness
// Loads MCU ROM (mcu_rom.bin) and Caliptra Core ROM (rom-2.1.3.bin),
// releases subsystem reset, and monitors concurrent execution of the
// MCU VeeR EL2 core and Caliptra Core VeeR EL2 core over the open-source
// AXI4 crossbar (calightra_ss_axi_xbar).

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "Vcalightra_ss_verilated.h"
#include "Vcalightra_ss_verilated___024root.h"
#include "verilated.h"

static bool load_rom64(const char* path, QData* dest, size_t max_qwords, const char* label) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) {
        fprintf(stderr, "ERROR: Failed to open %s image: %s\n", label, path);
        return false;
    }
    size_t sz = f.tellg();
    f.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(sz, 0);
    f.read(reinterpret_cast<char*>(buf.data()), sz);

    size_t num_qwords = (sz + 7) / 8;
    if (num_qwords > max_qwords) {
        fprintf(stderr, "ERROR: %s image (%zu bytes) exceeds memory capacity (%zu bytes)\n",
                label, sz, max_qwords * 8);
        return false;
    }
    for (size_t i = 0; i < max_qwords; i++) {
        dest[i] = 0;
    }
    for (size_t i = 0; i < sz; i++) {
        size_t qw = i / 8;
        size_t by = i % 8;
        dest[qw] |= static_cast<QData>(buf[i]) << (by * 8);
    }
    printf("[SIM] Loaded %s (%zu bytes, %zu 64-bit words) from %s\n",
           label, sz, num_qwords, path);
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* mcu_rom_path   = "../fw/mcu_rom.bin";
    const char* cptra_rom_path = "../../fw/caliptra-rom.bin";
    uint64_t    max_cycles     = 10000000ULL;

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--mcu-rom=", 10) == 0) {
            mcu_rom_path = argv[i] + 10;
        } else if (strncmp(argv[i], "--cptra-rom=", 12) == 0) {
            cptra_rom_path = argv[i] + 12;
        } else if (strncmp(argv[i], "--max-cycles=", 13) == 0) {
            max_cycles = strtoull(argv[i] + 13, nullptr, 10);
        }
    }

    auto* dut = new Vcalightra_ss_verilated;

    // Initialize inputs
    dut->core_clk           = 0;
    dut->cptra_ss_pwrgood_i = 0;
    dut->cptra_ss_rst_b_i   = 0;
    dut->soc_awvalid        = 0;
    dut->soc_awaddr         = 0;
    dut->soc_awuser         = 0x00000001;
    dut->soc_wvalid         = 0;
    dut->soc_wdata          = 0;
    dut->soc_wstrb          = 0;
    dut->soc_bready         = 1;
    dut->soc_arvalid        = 0;
    dut->soc_araddr         = 0;
    dut->soc_aruser         = 0x00000001;
    dut->soc_rready         = 1;

    if (!load_rom64(mcu_rom_path,
                    dut->rootp->calightra_ss_verilated__DOT__mcu_rom.m_storage,
                    2048, "MCU ROM")) {
        return 1;
    }
    if (!load_rom64(cptra_rom_path,
                    dut->rootp->calightra_ss_verilated__DOT__imem_rom.m_storage,
                    12288, "Caliptra Core ROM")) {
        return 1;
    }

    auto start_time = std::chrono::steady_clock::now();

    uint32_t last_mci_milestone = 0;
    uint8_t  last_cptra_char    = 0;
    bool     prev_mcu_rst_b     = false;
    bool     prev_cptra_rst_b   = false;
    bool     prev_rdy_fuses     = false;
    bool     prev_rdy_mb        = false;
    bool     mcu_passed         = false;

    printf("[SIM] Starting Calightra-SS simulation (max_cycles = %llu)...\n",
           static_cast<unsigned long long>(max_cycles));
    fflush(stdout);

    uint64_t cycle = 0;
    for (; cycle < max_cycles; cycle++) {
        if (cycle == 15) {
            dut->cptra_ss_pwrgood_i = 1;
            printf("[SIM @ %7llu] Asserted cptra_ss_pwrgood_i = 1\n",
                   static_cast<unsigned long long>(cycle));
        }
        if (cycle == 40) {
            dut->cptra_ss_rst_b_i = 1;
            printf("[SIM @ %7llu] Deasserted cptra_ss_rst_b_i = 1\n",
                   static_cast<unsigned long long>(cycle));
        }

        // Falling clock edge
        dut->core_clk = 0;
        dut->eval();

        // Rising clock edge
        dut->core_clk = 1;
        dut->eval();

        // Track reset releases from MCI boot sequencer
        if (dut->cptra_ss_mcu_rst_b_o && !prev_mcu_rst_b) {
            prev_mcu_rst_b = true;
            printf("[SIM @ %7llu] MCI Boot Sequencer released MCU reset (cptra_ss_mcu_rst_b_o = 1)\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }
        if (dut->cptra_ss_mci_cptra_rst_b_o && !prev_cptra_rst_b) {
            prev_cptra_rst_b = true;
            printf("[SIM @ %7llu] MCI released Caliptra Core reset (cptra_ss_mci_cptra_rst_b_o = 1)\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }

        // Track MCU console output (MCI_REG_DEBUG_OUT @ 0x2100_0414)
        if (dut->mci_debug_char_valid_o) {
            uint8_t ch = dut->mci_debug_char_o;
            if (ch == 0xFF) {
                printf("\n[SIM @ %7llu] MCU signaled TEST PASS (0xFF) via MCI DEBUG_OUT!\n",
                       static_cast<unsigned long long>(cycle));
                mcu_passed = true;
                break;
            } else if (ch == 0x01) {
                printf("\n[SIM @ %7llu] ERROR: MCU signaled TEST FAIL (0x01) via MCI DEBUG_OUT (GENERIC_1=0x%08x)!\n",
                       static_cast<unsigned long long>(cycle),
                       static_cast<uint32_t>(dut->cptra_ss_mci_generic_output_wires_o >> 32));
                return 2;
            } else if (ch >= 0x20 || ch == '\n' || ch == '\r' || ch == '\t') {
                putchar(ch);
                if (ch == '\n') fflush(stdout);
            }
        }

        // Track MCU milestone register (MCI_REG_GENERIC_OUTPUT_WIRES_0 @ 0x2100_0408)
        uint32_t mci_milestone = static_cast<uint32_t>(dut->cptra_ss_mci_generic_output_wires_o & 0xFFFFFFFFULL);
        if (mci_milestone != last_mci_milestone) {
            last_mci_milestone = mci_milestone;
            printf("[SIM @ %7llu] MCI GENERIC_OUTPUT_WIRES_0 = 0x%08x\n",
                   static_cast<unsigned long long>(cycle), mci_milestone);
            fflush(stdout);
        }

        // Track Caliptra Core console output (CPT_GENERIC_OUTPUT_WIRES_0[7:0])
        uint8_t cptra_ch = static_cast<uint8_t>(dut->cptra_ss_cptra_core_generic_output_wires_o & 0xFFU);
        if (cptra_ch != last_cptra_char) {
            last_cptra_char = cptra_ch;
            if (cptra_ch >= 0x20 || cptra_ch == '\n' || cptra_ch == '\r' || cptra_ch == '\t') {
                putchar(cptra_ch);
                if (cptra_ch == '\n') fflush(stdout);
            }
        }

        // Track Caliptra Core status pins
        if (dut->cptra_ss_ready_for_fuses_o && !prev_rdy_fuses) {
            prev_rdy_fuses = true;
            printf("[SIM @ %7llu] Caliptra Core asserted ready_for_fuses = 1\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }
        if (dut->cptra_ss_ready_for_mb_processing_o && !prev_rdy_mb) {
            prev_rdy_mb = true;
            printf("\n[SIM @ %7llu] Caliptra Core asserted ready_for_mb_processing = 1!\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }

        if (cycle > 0 && (cycle % 500000ULL == 0)) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start_time).count();
            printf("[SIM @ %7llu] Progress: %.2f s elapsed (%.2f kHz), mci_out=0x%08x\n",
                   static_cast<unsigned long long>(cycle), elapsed,
                   (cycle / 1000.0) / elapsed, last_mci_milestone);
            fflush(stdout);
        }
    }

    auto end_time = std::chrono::steady_clock::now();
    double total_sec = std::chrono::duration<double>(end_time - start_time).count();
    double khz = (cycle / 1000.0) / (total_sec > 0.0 ? total_sec : 1e-9);

    printf("================================================================\n");
    printf("Calightra-SS Simulation Summary:\n");
    printf("  Total Cycles            : %llu\n", static_cast<unsigned long long>(cycle));
    printf("  Wall-Clock Time         : %.2f s (%.2f kHz)\n", total_sec, khz);
    printf("  MCU Reset Released      : %s\n", prev_mcu_rst_b ? "YES" : "NO");
    printf("  Caliptra Reset Released : %s\n", prev_cptra_rst_b ? "YES" : "NO");
    printf("  ready_for_fuses         : %s\n", prev_rdy_fuses ? "YES" : "NO");
    printf("  ready_for_mb_processing : %s\n", prev_rdy_mb ? "YES" : "NO");
    printf("  MCI Final Milestone     : 0x%08x\n", last_mci_milestone);
    printf("  Status                  : %s\n", (mcu_passed && prev_rdy_mb) ? "PASS" : "TIMEOUT/FAIL");
    printf("================================================================\n");

    delete dut;
    return (mcu_passed && prev_rdy_mb) ? 0 : 1;
}
