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
// Loads the real caliptra-mcu-sw ROM (caliptra-mcu-rom-calightra.bin) and
// Caliptra Core ROM (caliptra-rom.bin), services Caliptra ETRNG requests,
// and drives the full 3-stage BMC / I3C recovery flow over the open-source
// AXI4 crossbar (calightra_ss_axi_xbar) and I3C target controller:
//   - Image 0: Caliptra Firmware Bundle (FMC + Runtime) -> Caliptra Mailbox
//   - Image 1: SoC Authorization Manifest               -> Caliptra AHB FIFO
//   - Image 2: MCU Runtime Firmware (mcu_rt.bin)        -> MCU SRAM (0x21c0_0000)

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
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

static bool load_words32(const char* path, std::vector<uint32_t>& out, const char* label) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) {
        fprintf(stderr, "ERROR: Failed to open %s image: %s\n", label, path);
        return false;
    }
    size_t sz = f.tellg();
    f.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(sz, 0);
    f.read(reinterpret_cast<char*>(buf.data()), sz);

    size_t num_dwords = (sz + 3) / 4;
    out.assign(num_dwords, 0);
    for (size_t i = 0; i < sz; i++) {
        out[i / 4] |= static_cast<uint32_t>(buf[i]) << ((i % 4) * 8);
    }
    printf("[SIM] Loaded %s (%zu bytes, %zu DWORDs) from %s\n",
           label, sz, num_dwords, path);
    return true;
}

struct SimHarness {
    // I3C CSR addresses (base = 0x2000_4000, recovery_ifc_base = 0x2000_4100)
    static constexpr uint32_t I3C_EC_STD_BASE             = 0x20004100U;
    static constexpr uint32_t I3C_REG_DEVICE_STATUS_0     = I3C_EC_STD_BASE + 0x30U; // 0x2000_4130
    static constexpr uint32_t I3C_REG_RECOVERY_STATUS     = I3C_EC_STD_BASE + 0x40U; // 0x2000_4140
    static constexpr uint32_t I3C_REG_INDIRECT_FIFO_CTRL0 = I3C_EC_STD_BASE + 0x48U; // 0x2000_4148
    static constexpr uint32_t I3C_REG_INDIRECT_FIFO_CTRL1 = I3C_EC_STD_BASE + 0x4cU; // 0x2000_414c
    static constexpr uint32_t I3C_REG_INDIRECT_FIFO_STAT0 = I3C_EC_STD_BASE + 0x50U; // 0x2000_4150
    static constexpr uint32_t I3C_REG_TTI_TX_DATA_PORT    = 0x2000427cU;
    static constexpr uint32_t I3C_REG_REC_INTF_CFG        = 0x2000430cU;
    static constexpr uint32_t I3C_REG_REC_INTF_W1C        = 0x20004310U;

    enum BmcState {
        BMC_INIT = 0,
        BMC_WAIT_REQ,
        BMC_STREAM_FIFO,
        BMC_WAIT_PENDING,
        BMC_DONE
    };

    Vcalightra_ss_verilated* dut;
    uint64_t cycle = 0;
    uint64_t max_cycles = 60000000ULL;
    std::chrono::steady_clock::time_point start_time;

    uint32_t last_mci_milestone = 0;
    uint8_t  last_cptra_char    = 0;
    bool     prev_mcu_rst_b     = false;
    bool     prev_cptra_rst_b   = false;
    bool     prev_rdy_fuses     = false;
    bool     prev_rdy_mb        = false;
    bool     prev_rdy_rt        = false;
    bool     prev_fw_exec_mcu   = false;
    bool     mcu_passed         = false;
    bool     mcu_failed         = false;
    bool     mcu_entered_recovery = false;
    uint32_t etrng_responses    = 0;
    std::string mcu_line_buf;

    bool in_axi_service = false;

    // Recovery images & BMC state machine
    std::vector<uint32_t> recovery_images[3];
    bool     image_sent[3]  = {false, false, false};
    uint32_t images_completed = 0;
    BmcState bmc_state      = BMC_INIT;
    uint32_t cur_img_idx    = 0;
    size_t   cur_word_idx   = 0;

    explicit SimHarness(Vcalightra_ss_verilated* d, uint64_t max_c)
        : dut(d), max_cycles(max_c), start_time(std::chrono::steady_clock::now()) {}

    bool done() const {
        return cycle >= max_cycles || mcu_passed || mcu_failed;
    }

    // Advance one clock cycle and return sampled pre-posedge AXI handshakes
    void step_cycle(bool* aw_hs = nullptr, bool* w_hs = nullptr, bool* b_hs = nullptr,
                    bool* ar_hs = nullptr, bool* r_hs = nullptr, uint32_t* rdata_out = nullptr) {
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

        // Falling clock edge: settle combinational signals before posedge
        dut->core_clk = 0;
        dut->eval();

        if (aw_hs)     *aw_hs     = dut->soc_awvalid && dut->soc_awready;
        if (w_hs)      *w_hs      = dut->soc_wvalid  && dut->soc_wready;
        if (b_hs)      *b_hs      = dut->soc_bvalid  && dut->soc_bready;
        if (ar_hs)     *ar_hs     = dut->soc_arvalid && dut->soc_arready;
        if (r_hs)      *r_hs      = dut->soc_rvalid  && dut->soc_rready;
        if (rdata_out) *rdata_out = dut->soc_rdata;

        // Rising clock edge
        dut->core_clk = 1;
        dut->eval();

        // Track reset edges
        if (dut->cptra_ss_mcu_rst_b_o && !prev_mcu_rst_b) {
            prev_mcu_rst_b = true;
            printf("[SIM @ %7llu] MCI Boot Sequencer released MCU reset (cptra_ss_mcu_rst_b_o = 1)\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        } else if (!dut->cptra_ss_mcu_rst_b_o && prev_mcu_rst_b) {
            prev_mcu_rst_b = false;
            printf("[SIM @ %7llu] MCI Boot Sequencer asserted MCU reset (cptra_ss_mcu_rst_b_o = 0)\n",
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
            } else if (ch == 0x01) {
                printf("\n[SIM @ %7llu] ERROR: MCU signaled TEST FAIL (0x01) via MCI DEBUG_OUT (GENERIC_1=0x%08x)!\n",
                       static_cast<unsigned long long>(cycle),
                       static_cast<uint32_t>(dut->cptra_ss_mci_generic_output_wires_o >> 32));
                mcu_failed = true;
            } else if (ch >= 0x20 || ch == '\n' || ch == '\r' || ch == '\t') {
                putchar(ch);
                if (ch == '\n') {
                    if (mcu_line_buf.find("Sending RI_DOWNLOAD_FIRMWARE command") != std::string::npos) {
                        mcu_entered_recovery = true;
                    }
                    mcu_line_buf.clear();
                    fflush(stdout);
                } else {
                    mcu_line_buf.push_back(static_cast<char>(ch));
                }
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
            printf("\n[SIM @ %7llu] Caliptra Core asserted ready_for_fuses = 1\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }
        if (dut->cptra_ss_ready_for_mb_processing_o && !prev_rdy_mb) {
            prev_rdy_mb = true;
            printf("\n[SIM @ %7llu] Caliptra Core asserted ready_for_mb_processing = 1!\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }
        if (dut->cptra_ss_ready_for_runtime_o && !prev_rdy_rt) {
            prev_rdy_rt = true;
            printf("\n[SIM @ %7llu] Caliptra Core asserted ready_for_runtime = 1!\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }
        if (dut->cptra_ss_fw_exec_ctrl_2_mcu_o && !prev_fw_exec_mcu) {
            prev_fw_exec_mcu = true;
            printf("\n[SIM @ %7llu] Caliptra Core asserted FW_EXEC_CTRL[2] (MCU runtime ready) = 1!\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
        }

        if (cycle > 0 && (cycle % 500000ULL == 0)) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start_time).count();
            printf("[SIM @ %7llu] Progress: %.2f s elapsed (%.2f kHz)\n",
                   static_cast<unsigned long long>(cycle), elapsed,
                   (cycle / 1000.0) / elapsed);
            fflush(stdout);
        }

        cycle++;
    }

    // Perform a 32-bit AXI write over the External SoC Manager port (M3)
    void axi_write(uint32_t addr, uint32_t data, uint32_t user = 0x00000001) {
        dut->soc_awaddr  = addr;
        dut->soc_awuser  = user;
        dut->soc_awvalid = 1;
        dut->soc_wdata   = data;
        dut->soc_wstrb   = 0xF;
        dut->soc_wvalid  = 1;
        dut->soc_bready  = 1;

        bool aw_done = false;
        bool w_done  = false;
        bool b_done  = false;

        while (!b_done && !done()) {
            bool aw_hs = false, w_hs = false, b_hs = false;
            step_cycle(&aw_hs, &w_hs, &b_hs, nullptr, nullptr, nullptr);
            if (aw_hs) {
                aw_done = true;
                dut->soc_awvalid = 0;
            }
            if (w_hs) {
                w_done = true;
                dut->soc_wvalid = 0;
            }
            if (b_hs) {
                b_done = true;
            }
        }
        dut->soc_awvalid = 0;
        dut->soc_wvalid  = 0;
    }

    // Perform a 32-bit AXI read over the External SoC Manager port (M3)
    uint32_t axi_read(uint32_t addr, uint32_t user = 0x00000001) {
        dut->soc_araddr  = addr;
        dut->soc_aruser  = user;
        dut->soc_arvalid = 1;
        dut->soc_rready  = 1;

        bool ar_done = false;
        bool r_done  = false;
        uint32_t result = 0;

        while (!r_done && !done()) {
            bool ar_hs = false, r_hs = false;
            uint32_t rdata = 0;
            step_cycle(nullptr, nullptr, nullptr, &ar_hs, &r_hs, &rdata);
            if (ar_hs) {
                ar_done = true;
                dut->soc_arvalid = 0;
            }
            if (r_hs) {
                r_done = true;
                result = rdata;
            }
        }
        dut->soc_arvalid = 0;
        return result;
    }

    // Service Caliptra Core external TRNG requests via CPTRA_TRNG_STATUS (0x3003_00ac)
    void service_etrng_if_needed(bool force_poll = false) {
        if (in_axi_service) {
            return;
        }
        bool should_check = dut->cptra_ss_etrng_req_o || force_poll;
        if (!should_check) {
            return;
        }
        in_axi_service = true;
        while (!done()) {
            uint32_t trng_st = axi_read(0x300300acU);
            if ((trng_st & 0x3U) == 0x1U) {
                for (uint32_t i = 0; i < 12; i++) {
                    uint32_t word = (0x9E3779B9U * ((etrng_responses + 1U) * 13U + i + 1U)) ^ (0x6A09E667U + i);
                    axi_write(0x30030078U + i * 4U, word);
                }
                axi_write(0x300300acU, 0x00000002U);
                etrng_responses++;
            } else {
                break;
            }
        }
        in_axi_service = false;
    }

    // Non-blocking BMC / I3C Recovery Agent State Machine
    void service_bmc_recovery() {
        if (in_axi_service || bmc_state == BMC_DONE || cycle < 100) {
            return;
        }
        in_axi_service = true;

        if (bmc_state == BMC_INIT) {
            // Enable I3C Recovery Interface Bypass Mode (REC_INTF_BYPASS = 1)
            axi_write(I3C_REG_REC_INTF_CFG, 0x00000001U);
            printf("[BMC @ %7llu] Enabled I3C Recovery Bypass Mode (REC_INTF_CFG = 0x1)\n",
                   static_cast<unsigned long long>(cycle));
            fflush(stdout);
            bmc_state = BMC_WAIT_REQ;
        } else if (bmc_state == BMC_WAIT_REQ) {
            if (prev_rdy_mb && (cycle % 500ULL == 0)) {
                uint32_t dev_st = axi_read(I3C_REG_DEVICE_STATUS_0);
                uint32_t rec_st = axi_read(I3C_REG_RECOVERY_STATUS);
                uint32_t dev_status_code = dev_st & 0xFFU;
                uint32_t rec_status_code = rec_st & 0xFU;
                uint32_t img_idx         = (rec_st >> 4) & 0xFU;

                if (dev_status_code == 0x3U && rec_status_code == 0x1U &&
                    img_idx < 3U && !image_sent[img_idx]) {
                    cur_img_idx  = img_idx;
                    cur_word_idx = 0;
                    uint32_t img_dwords = static_cast<uint32_t>(recovery_images[cur_img_idx].size());

                    // Ensure REC_PAYLOAD_DONE is 0 and write image size (in DWORDs) to INDIRECT_FIFO_CTRL_1
                    axi_write(I3C_REG_REC_INTF_CFG, 0x00000001U);
                    axi_write(I3C_REG_INDIRECT_FIFO_CTRL1, img_dwords);

                    printf("\n[BMC @ %7llu] Recovery request detected for Image %u: %u DWORDs (%u bytes)\n",
                           static_cast<unsigned long long>(cycle), cur_img_idx,
                           img_dwords, img_dwords * 4U);
                    fflush(stdout);
                    bmc_state = BMC_STREAM_FIFO;
                }
            }
        } else if (bmc_state == BMC_STREAM_FIFO) {
            if (cycle % 32ULL == 0) {
                uint32_t fifo_st = axi_read(I3C_REG_INDIRECT_FIFO_STAT0);
                bool fifo_empty = (fifo_st & 0x1U) != 0;
                if (fifo_empty) {
                    const auto& img = recovery_images[cur_img_idx];
                    size_t remaining = img.size() - cur_word_idx;
                    size_t chunk = std::min<size_t>(64, remaining);

                    for (size_t i = 0; i < chunk; i++) {
                        axi_write(I3C_REG_TTI_TX_DATA_PORT, img[cur_word_idx + i]);
                    }
                    cur_word_idx += chunk;

                    if (cur_word_idx >= img.size()) {
                        if (chunk < 64) {
                            // Partial final block (< 64 DWORDs): assert REC_PAYLOAD_DONE (bit 1)
                            axi_write(I3C_REG_REC_INTF_CFG, 0x00000003U);
                        }
                        printf("\n[BMC @ %7llu] Finished streaming Image %u (%zu/%zu DWORDs), waiting for DEVICE_STATUS_PENDING...\n",
                               static_cast<unsigned long long>(cycle), cur_img_idx,
                               cur_word_idx, img.size());
                        fflush(stdout);
                        bmc_state = BMC_WAIT_PENDING;
                    }
                }
            }
        } else if (bmc_state == BMC_WAIT_PENDING) {
            if (cycle % 200ULL == 0) {
                uint32_t dev_st = axi_read(I3C_REG_DEVICE_STATUS_0);
                if ((dev_st & 0xFFU) == 0x4U) {
                    // Clear REC_PAYLOAD_DONE = 0 and activate image (ACTIVATE_REC_IMG = 0xF)
                    axi_write(I3C_REG_REC_INTF_CFG, 0x00000001U);
                    axi_write(I3C_REG_REC_INTF_W1C, 0x00000F00U);
                    image_sent[cur_img_idx] = true;
                    images_completed++;

                    printf("\n[BMC @ %7llu] Activated Recovery Image %u (RECOVERY_CTRL.ACTIVATE_REC_IMG = 0xF)!\n",
                           static_cast<unsigned long long>(cycle), cur_img_idx);
                    fflush(stdout);

                    if (cur_img_idx == 2U) {
                        bmc_state = BMC_DONE;
                    } else {
                        bmc_state = BMC_WAIT_REQ;
                    }
                }
            }
        }

        in_axi_service = false;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* mcu_rom_path      = "../mcu-rom/caliptra-mcu-rom-calightra.bin";
    const char* cptra_rom_path    = "../../fw/caliptra-rom-with-log.bin";
    const char* bundle_path       = "../../fw/image-bundle-mldsa.bin";
    const char* soc_manifest_path = "../mcu-rom/soc_manifest.bin";
    const char* mcu_rt_path       = "../mcu-rom/mcu_rt.bin";
    uint64_t    max_cycles        = 60000000ULL;
    bool        stop_at_recovery  = false;

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--mcu-rom=", 10) == 0) {
            mcu_rom_path = argv[i] + 10;
        } else if (strncmp(argv[i], "--cptra-rom=", 12) == 0) {
            cptra_rom_path = argv[i] + 12;
        } else if (strncmp(argv[i], "--bundle=", 9) == 0) {
            bundle_path = argv[i] + 9;
        } else if (strncmp(argv[i], "--soc-manifest=", 15) == 0) {
            soc_manifest_path = argv[i] + 15;
        } else if (strncmp(argv[i], "--mcu-rt=", 9) == 0) {
            mcu_rt_path = argv[i] + 9;
        } else if (strncmp(argv[i], "--max-cycles=", 13) == 0) {
            max_cycles = strtoull(argv[i] + 13, nullptr, 10);
        } else if (strcmp(argv[i], "--stop-at-recovery") == 0) {
            stop_at_recovery = true;
        } else if (strcmp(argv[i], "--full-recovery") == 0) {
            stop_at_recovery = false;
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
    dut->i3c_scl_i          = 1;
    dut->i3c_sda_i          = 1;

    if (!load_rom64(mcu_rom_path,
                    dut->rootp->calightra_ss_verilated__DOT__mcu_rom.m_storage,
                    8192, "MCU ROM")) {
        return 1;
    }
    if (!load_rom64(cptra_rom_path,
                    dut->rootp->calightra_ss_verilated__DOT__imem_rom.m_storage,
                    12288, "Caliptra Core ROM")) {
        return 1;
    }

    SimHarness sim(dut, max_cycles);

    if (!load_words32(bundle_path, sim.recovery_images[0], "Recovery Image 0 (Caliptra FW Bundle)")) {
        return 1;
    }
    if (!load_words32(soc_manifest_path, sim.recovery_images[1], "Recovery Image 1 (SoC Manifest)")) {
        return 1;
    }
    if (!load_words32(mcu_rt_path, sim.recovery_images[2], "Recovery Image 2 (MCU Runtime)")) {
        return 1;
    }

    printf("[SIM] Starting Calightra-SS simulation (max_cycles = %llu)...\n",
           static_cast<unsigned long long>(max_cycles));
    fflush(stdout);

    while (!sim.done()) {
        sim.step_cycle();
        sim.service_etrng_if_needed();
        if (!stop_at_recovery) {
            sim.service_bmc_recovery();
        } else if (sim.prev_rdy_mb && sim.mcu_entered_recovery) {
            for (int k = 0; k < 50000 && !sim.done(); k++) {
                sim.step_cycle();
                sim.service_etrng_if_needed();
            }
            sim.mcu_passed = true;
            break;
        }
    }

    auto end_time = std::chrono::steady_clock::now();
    double total_sec = std::chrono::duration<double>(end_time - sim.start_time).count();
    double khz = (sim.cycle / 1000.0) / (total_sec > 0.0 ? total_sec : 1e-9);

    printf("================================================================\n");
    printf("Calightra-SS Simulation Summary:\n");
    printf("  Total Cycles            : %llu\n", static_cast<unsigned long long>(sim.cycle));
    printf("  Wall-Clock Time         : %.2f s (%.2f kHz)\n", total_sec, khz);
    printf("  MCU Reset Released      : %s\n", sim.prev_mcu_rst_b ? "YES" : "NO");
    printf("  Caliptra Reset Released : %s\n", sim.prev_cptra_rst_b ? "YES" : "NO");
    printf("  ready_for_fuses         : %s\n", sim.prev_rdy_fuses ? "YES" : "NO");
    printf("  ready_for_mb_processing : %s\n", sim.prev_rdy_mb ? "YES" : "NO");
    printf("  ready_for_runtime       : %s\n", sim.prev_rdy_rt ? "YES" : "NO");
    printf("  FW_EXEC_CTRL[2] (MCU)   : %s\n", sim.prev_fw_exec_mcu ? "YES" : "NO");
    printf("  ETRNG Requests Serviced : %u\n", sim.etrng_responses);
    printf("  I3C Recovery Images     : %u / 3\n", sim.images_completed);
    printf("  Status                  : %s\n", (sim.mcu_passed && sim.prev_rdy_mb) ? "PASS" : "TIMEOUT/FAIL");
    printf("================================================================\n");

    delete dut;
    return (sim.mcu_passed && sim.prev_rdy_mb) ? 0 : 1;
}
