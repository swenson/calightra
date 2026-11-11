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
// and drives the full 3-stage BMC / OCP Recovery flow over the physical
// 2-wire I3C bus (i3c_scl / i3c_sda) using the open-source calightra_i3c_ctrl
// (XI3C-compatible) I3C Controller IP's MMIO registers:
//   - I3C CCCs: RSTDAA (0x06), SETDASA (0x87: 0x3a->0x08, 0x3b->0x09)
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

static bool load_bytes(const char* path, std::vector<uint8_t>& out, size_t& unpadded_bytes, const char* label) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) {
        fprintf(stderr, "ERROR: Failed to open %s image: %s\n", label, path);
        return false;
    }
    size_t sz = f.tellg();
    f.seekg(0, std::ios::beg);
    out.assign(sz, 0);
    f.read(reinterpret_cast<char*>(out.data()), sz);

    // Ensure unpadded length is 4-byte aligned for DWORD count
    while (out.size() % 4 != 0) {
        out.push_back(0);
    }
    unpadded_bytes = out.size();

    // Pad buffer to a multiple of 256 bytes (64 DWORDs, the I3C indirect FIFO depth)
    // so the final 256-byte chunk fills the FIFO and triggers payload_available_o
    while (out.size() % 256 != 0) {
        out.push_back(0);
    }

    printf("[SIM] Loaded %s (%zu bytes, %zu DWORDs, padded to %zu bytes) from %s\n",
           label, unpadded_bytes, unpadded_bytes / 4, out.size(), path);
    return true;
}

struct SimHarness {
    // Open-source I3C Controller (calightra_i3c_ctrl / XI3C-compatible) MMIO Offsets
    static constexpr uint8_t XI3C_VERSION_OFFSET           = 0x00;
    static constexpr uint8_t XI3C_RESET_OFFSET             = 0x04;
    static constexpr uint8_t XI3C_CR_OFFSET                = 0x08;
    static constexpr uint8_t XI3C_ADDRESS_OFFSET           = 0x0C;
    static constexpr uint8_t XI3C_SR_OFFSET                = 0x10;
    static constexpr uint8_t XI3C_CMD_FIFO_OFFSET          = 0x20;
    static constexpr uint8_t XI3C_WR_FIFO_OFFSET           = 0x24;
    static constexpr uint8_t XI3C_RD_FIFO_OFFSET           = 0x28;
    static constexpr uint8_t XI3C_RESP_STATUS_FIFO_OFFSET  = 0x2C;
    static constexpr uint8_t XI3C_FIFO_LVL_STATUS_OFFSET   = 0x30;
    static constexpr uint8_t XI3C_FIFO_LVL_STATUS_1_OFFSET = 0x34;
    static constexpr uint8_t XI3C_SCL_HIGH_TIME_OFFSET     = 0x38;
    static constexpr uint8_t XI3C_SCL_LOW_TIME_OFFSET      = 0x3C;

    // I3C Bus Addresses (matching caliptra-mcu-sw straps & ModelFpgaSubsystem)
    static constexpr uint8_t I3C_BROADCAST_ADDR            = 0x7E;
    static constexpr uint8_t I3C_MCTP_STATIC_ADDR          = 0x3A;
    static constexpr uint8_t I3C_REC_STATIC_ADDR           = 0x3B;
    static constexpr uint8_t I3C_MCTP_DYNAMIC_ADDR         = 0x08;
    static constexpr uint8_t I3C_REC_DYNAMIC_ADDR          = 0x09;

    // MIPI I3C Common Command Codes (CCCs)
    static constexpr uint8_t CCC_BCAST_RSTDAA              = 0x06;
    static constexpr uint8_t CCC_DIRECT_SETDASA            = 0x87;

    // OCP Recovery Protocol Command Codes (OCP Secure Firmware Recovery v1.1)
    static constexpr uint8_t OCP_CMD_PROT_CAP              = 34;
    static constexpr uint8_t OCP_CMD_DEVICE_ID             = 35;
    static constexpr uint8_t OCP_CMD_DEVICE_STATUS         = 36;
    static constexpr uint8_t OCP_CMD_DEVICE_RESET          = 37;
    static constexpr uint8_t OCP_CMD_RECOVERY_CTRL         = 38;
    static constexpr uint8_t OCP_CMD_RECOVERY_STATUS       = 39;
    static constexpr uint8_t OCP_CMD_HW_STATUS             = 40;
    static constexpr uint8_t OCP_CMD_INDIRECT_FIFO_CTRL    = 45;
    static constexpr uint8_t OCP_CMD_INDIRECT_FIFO_STATUS  = 46;
    static constexpr uint8_t OCP_CMD_INDIRECT_FIFO_DATA    = 47;

    enum BmcState {
        BMC_INIT_DA = 0,
        BMC_READ_PROT_CAP,
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
    bool     mcu_i3c_initialized  = false;
    bool     mcu_entered_recovery = false;
    uint32_t etrng_responses    = 0;
    std::string mcu_line_buf;

    bool in_axi_service = false;
    bool in_bmc_service = false;

    // Recovery images & BMC state machine
    std::vector<uint8_t> recovery_images[3];
    size_t   recovery_unpadded_bytes[3] = {0, 0, 0};
    bool     image_sent[3]  = {false, false, false};
    uint32_t images_completed = 0;
    BmcState bmc_state      = BMC_INIT_DA;
    uint32_t cur_img_idx    = 0;
    size_t   cur_byte_idx   = 0;
    uint8_t  next_tid       = 0;

    explicit SimHarness(Vcalightra_ss_verilated* d, uint64_t max_c)
        : dut(d), max_cycles(max_c), start_time(std::chrono::steady_clock::now()) {}

    bool done() const {
        return cycle >= max_cycles || mcu_passed || mcu_failed;
    }

    // Advance one clock cycle and return sampled pre-posedge signals
    void step_cycle(bool* aw_hs = nullptr, bool* w_hs = nullptr, bool* b_hs = nullptr,
                    bool* ar_hs = nullptr, bool* r_hs = nullptr, uint32_t* rdata_out = nullptr,
                    uint32_t* i3c_rdata_out = nullptr) {
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

        if (aw_hs)         *aw_hs         = dut->soc_awvalid && dut->soc_awready;
        if (w_hs)          *w_hs          = dut->soc_wvalid  && dut->soc_wready;
        if (b_hs)          *b_hs          = dut->soc_bvalid  && dut->soc_bready;
        if (ar_hs)         *ar_hs         = dut->soc_arvalid && dut->soc_arready;
        if (r_hs)          *r_hs          = dut->soc_rvalid  && dut->soc_rready;
        if (rdata_out)     *rdata_out     = dut->soc_rdata;
        if (i3c_rdata_out) *i3c_rdata_out = dut->i3c_ctrl_rdata_o;

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
                    if (mcu_line_buf.find("Waiting for Caliptra to be ready for fuses") != std::string::npos) {
                        mcu_i3c_initialized = true;
                    }
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

    // Perform a 32-bit AXI write over the External SoC Manager port (M3) (used ONLY for ETRNG)
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

    // Perform a 32-bit AXI read over the External SoC Manager port (M3) (used ONLY for ETRNG)
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

    // =========================================================================
    // I3C Controller (calightra_i3c_ctrl / XI3C) Register Access & Transactions
    // =========================================================================

    void i3c_ctrl_write(uint8_t addr, uint32_t data) {
        dut->i3c_ctrl_addr_i  = addr;
        dut->i3c_ctrl_wdata_i = data;
        dut->i3c_ctrl_we_i    = 1;
        dut->i3c_ctrl_re_i    = 0;
        step_cycle();
        dut->i3c_ctrl_we_i    = 0;
        service_etrng_if_needed();
    }

    uint32_t i3c_ctrl_read(uint8_t addr) {
        dut->i3c_ctrl_addr_i  = addr;
        dut->i3c_ctrl_we_i    = 0;
        dut->i3c_ctrl_re_i    = 1;
        uint32_t val = 0;
        step_cycle(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, &val);
        dut->i3c_ctrl_re_i    = 0;
        service_etrng_if_needed();
        return val;
    }

    static uint32_t pack_xi3c_cmd(uint8_t target_addr, bool rnw, bool no_rpt_start,
                                  bool pec, uint16_t byte_count, uint8_t tid = 0) {
        return (1U << 0) |
               (static_cast<uint32_t>(no_rpt_start ? 1U : 0U) << 4)  |
               (static_cast<uint32_t>(pec ? 1U : 0U)          << 5)  |
               (static_cast<uint32_t>(rnw ? 1U : 0U)          << 8)  |
               (static_cast<uint32_t>(target_addr & 0x7FU)    << 9)  |
               (static_cast<uint32_t>(byte_count & 0xFFFU)    << 16) |
               (static_cast<uint32_t>(tid & 0xFU)             << 28);
    }

    // Push bytes (packed big-endian 4 bytes/word, matching XI3C WR_FIFO)
    void i3c_push_wr_bytes(const uint8_t* data, size_t len) {
        size_t idx = 0;
        while (idx < len) {
            uint8_t b0 = (idx + 0 < len) ? data[idx + 0] : 0;
            uint8_t b1 = (idx + 1 < len) ? data[idx + 1] : 0;
            uint8_t b2 = (idx + 2 < len) ? data[idx + 2] : 0;
            uint8_t b3 = (idx + 3 < len) ? data[idx + 3] : 0;
            uint32_t word = (static_cast<uint32_t>(b0) << 24) |
                            (static_cast<uint32_t>(b1) << 16) |
                            (static_cast<uint32_t>(b2) << 8)  |
                            (static_cast<uint32_t>(b3) << 0);
            i3c_ctrl_write(XI3C_WR_FIFO_OFFSET, word);
            idx += 4;
        }
    }

    // Wait for a command completion in XI3C_RESP_STATUS_FIFO and return err_code ([11:8])
    uint8_t i3c_wait_resp(uint16_t* rx_count_out = nullptr) {
        while (!done()) {
            uint32_t sr = i3c_ctrl_read(XI3C_SR_OFFSET);
            if ((sr & (1U << 4)) != 0) { // RESP_NOT_EMPTY
                uint32_t resp = i3c_ctrl_read(XI3C_RESP_STATUS_FIFO_OFFSET);
                uint8_t err_code = static_cast<uint8_t>((resp >> 8) & 0xFU);
                if (rx_count_out) {
                    *rx_count_out = static_cast<uint16_t>((resp >> 16) & 0xFFFU);
                }
                if (err_code != 0) {
                    // Resume controller if halted on NACK/error
                    i3c_ctrl_write(XI3C_CR_OFFSET, 0x9U);
                }
                return err_code;
            }
            // Step a few cycles between status polls while servicing ETRNG
            for (int k = 0; k < 8 && !done(); k++) {
                step_cycle();
                service_etrng_if_needed();
            }
        }
        return 0xFF;
    }

    // Send a Broadcast CCC (e.g., RSTDAA = 0x06):
    //   [S, 0x7E+W, CCC, payload..., P]
    bool i3c_send_bcast_ccc(uint8_t ccc, const std::vector<uint8_t>& payload = {}) {
        std::vector<uint8_t> frame;
        frame.push_back(ccc);
        frame.insert(frame.end(), payload.begin(), payload.end());

        i3c_push_wr_bytes(frame.data(), frame.size());
        uint8_t tid = (next_tid++) & 0x7U;
        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(I3C_BROADCAST_ADDR, false, true, false,
                                     static_cast<uint16_t>(frame.size()), tid));
        uint8_t err = i3c_wait_resp();
        return (err == 0);
    }

    // Send a Direct SETDASA CCC (0x87) to assign dynamic_addr to static_addr:
    //   Cmd 1: [S,  0x7E+W, 0x87] (No_Repeated_Start = 0)
    //   Cmd 2: [Sr, static_addr+W, (dynamic_addr << 1), P] (No_Repeated_Start = 1)
    bool i3c_send_setdasa(uint8_t static_addr, uint8_t dynamic_addr) {
        uint8_t ccc_byte = CCC_DIRECT_SETDASA;
        uint8_t da_byte  = static_cast<uint8_t>(dynamic_addr << 1);

        i3c_push_wr_bytes(&ccc_byte, 1);
        i3c_push_wr_bytes(&da_byte, 1);

        uint8_t tid1 = (next_tid++) & 0x7U;
        uint8_t tid2 = (next_tid++) & 0x7U;
        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(I3C_BROADCAST_ADDR, false, false, false, 1, tid1));
        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(static_addr, false, true, false, 1, tid2));

        uint8_t err1 = i3c_wait_resp();
        uint8_t err2 = i3c_wait_resp();
        return (err1 == 0) && (err2 == 0);
    }

    // Perform an OCP Recovery Block Write over I3C SDR with hardware PEC:
    //   [S, target_addr+W, cmd_code, len_lsb, len_msb, payload[0..len-1], PEC_W, P]
    bool i3c_recovery_block_write(uint8_t target_addr, uint8_t cmd_code,
                                  const uint8_t* payload, size_t len) {
        std::vector<uint8_t> packet(3 + len);
        packet[0] = cmd_code;
        packet[1] = static_cast<uint8_t>(len & 0xFFU);
        packet[2] = static_cast<uint8_t>((len >> 8) & 0xFFU);
        if (len > 0 && payload != nullptr) {
            std::memcpy(&packet[3], payload, len);
        }

        i3c_push_wr_bytes(packet.data(), packet.size());
        uint8_t tid = (next_tid++) & 0x7U;
        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(target_addr, /*rnw=*/false, /*no_rpt_start=*/true,
                                     /*pec=*/true, static_cast<uint16_t>(packet.size()), tid));
        uint8_t err = i3c_wait_resp();
        if (err != 0) {
            printf("[I3C @ %7llu] WARN: Block write cmd=%u len=%zu returned err=%u\n",
                   static_cast<unsigned long long>(cycle), cmd_code, len, err);
            return false;
        }
        // Allow recovery_receiver internal ExecCsrWrite / ExecFifoWrite to complete
        // and return to Idle before starting the next I3C transaction.
        int post_cycles = (cmd_code == OCP_CMD_INDIRECT_FIFO_DATA) ? 160 : 32;
        for (int k = 0; k < post_cycles && !done(); k++) {
            step_cycle();
            service_etrng_if_needed();
        }
        return true;
    }

    // Perform an OCP Recovery Block Read over I3C SDR with Repeated Start and hardware PEC:
    //   Cmd 1 (Write): [S,  target_addr+W, cmd_code, PEC_W] (No_Repeated_Start = 0, PEC = 1)
    //   Cmd 2 (Read) : [Sr, target_addr+R, len_lsb, len_msb, data[0..expected_len-1], PEC_R, P]
    bool i3c_recovery_block_read(uint8_t target_addr, uint8_t cmd_code,
                                 size_t expected_len, std::vector<uint8_t>& out) {
        // Flush any stale RD_FIFO words
        while ((i3c_ctrl_read(XI3C_SR_OFFSET) & (1U << 15)) != 0 && !done()) {
            (void)i3c_ctrl_read(XI3C_RD_FIFO_OFFSET);
        }

        i3c_push_wr_bytes(&cmd_code, 1);

        uint16_t read_bytes = static_cast<uint16_t>(expected_len + 2);
        uint8_t tid1 = (next_tid++) & 0x7U;
        uint8_t tid2 = (next_tid++) & 0x7U;

        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(target_addr, /*rnw=*/false, /*no_rpt_start=*/false,
                                     /*pec=*/true, 1, tid1));
        i3c_ctrl_write(XI3C_CMD_FIFO_OFFSET,
                       pack_xi3c_cmd(target_addr, /*rnw=*/true, /*no_rpt_start=*/true,
                                     /*pec=*/true, read_bytes, tid2));

        uint8_t err1 = i3c_wait_resp();
        uint16_t rx_cnt = 0;
        uint8_t err2 = i3c_wait_resp(&rx_cnt);
        if (err1 != 0 || err2 != 0) {
            printf("[I3C @ %7llu] WARN: Block read addr=0x%02x cmd=%u exp=%zu returned err1=%u err2=%u rx_cnt=%u\n",
                   static_cast<unsigned long long>(cycle), target_addr, cmd_code, expected_len, err1, err2, rx_cnt);
            fflush(stdout);
            return false;
        }

        size_t words_to_pop = (read_bytes + 3) / 4;
        std::vector<uint8_t> raw;
        raw.reserve(words_to_pop * 4);
        for (size_t w = 0; w < words_to_pop; w++) {
            uint32_t word = i3c_ctrl_read(XI3C_RD_FIFO_OFFSET);
            raw.push_back(static_cast<uint8_t>((word >> 24) & 0xFFU));
            raw.push_back(static_cast<uint8_t>((word >> 16) & 0xFFU));
            raw.push_back(static_cast<uint8_t>((word >> 8)  & 0xFFU));
            raw.push_back(static_cast<uint8_t>((word >> 0)  & 0xFFU));
        }

        out.assign(raw.begin() + 2, raw.begin() + 2 + expected_len);
        return true;
    }

    // =========================================================================
    // BMC / I3C Recovery Agent State Machine (pure wire-level I3C via XI3C MMIO)
    // =========================================================================
    void service_bmc_recovery() {
        if (in_axi_service || in_bmc_service || bmc_state == BMC_DONE) {
            return;
        }
        // Wait until MCU ROM has initialized the I3C target & PHY
        if (!mcu_i3c_initialized) {
            return;
        }

        in_bmc_service = true;

        if (bmc_state == BMC_INIT_DA) {
            uint32_t ver = i3c_ctrl_read(XI3C_VERSION_OFFSET);
            printf("\n[BMC-I3C @ %7llu] Initializing calightra_i3c_ctrl (VERSION = 0x%08x)\n",
                   static_cast<unsigned long long>(cycle), ver);

            // Enable I3C controller (CR.EN = 1) and configure 9-clocks/bit SDR timing
            i3c_ctrl_write(XI3C_CR_OFFSET, 0x1U);
            i3c_ctrl_write(XI3C_SCL_HIGH_TIME_OFFSET, 4U);
            i3c_ctrl_write(XI3C_SCL_LOW_TIME_OFFSET,  5U);

            // 1. Broadcast RSTDAA (0x06)
            bool ok_rstdaa = i3c_send_bcast_ccc(CCC_BCAST_RSTDAA);
            // 2. Direct SETDASA (0x87): static 0x3A -> dynamic 0x08 (MCTP target)
            bool ok_da0 = i3c_send_setdasa(I3C_MCTP_STATIC_ADDR, I3C_MCTP_DYNAMIC_ADDR);
            // 3. Direct SETDASA (0x87): static 0x3B -> dynamic 0x09 (OCP Recovery virtual target)
            bool ok_da1 = i3c_send_setdasa(I3C_REC_STATIC_ADDR, I3C_REC_DYNAMIC_ADDR);

            printf("[BMC-I3C @ %7llu] Dynamic Address Assignment over I3C wire: RSTDAA=%s, SETDASA(0x3a->0x08)=%s, SETDASA(0x3b->0x09)=%s\n",
                   static_cast<unsigned long long>(cycle),
                   ok_rstdaa ? "ACK" : "NACK",
                   ok_da0    ? "ACK" : "NACK",
                   ok_da1    ? "ACK" : "NACK");
            fflush(stdout);

            if (ok_rstdaa && ok_da0 && ok_da1) {
                bmc_state = BMC_READ_PROT_CAP;
            }
        } else if (bmc_state == BMC_READ_PROT_CAP) {
            if (cycle % 500ULL == 0) {
                std::vector<uint8_t> prot_cap;
                if (i3c_recovery_block_read(I3C_REC_DYNAMIC_ADDR, OCP_CMD_PROT_CAP, 15, prot_cap)) {
                    std::string magic(reinterpret_cast<const char*>(prot_cap.data()), 8);
                    uint16_t ver = static_cast<uint16_t>(prot_cap[8]) |
                                   (static_cast<uint16_t>(prot_cap[9]) << 8);
                    uint16_t caps = static_cast<uint16_t>(prot_cap[10]) |
                                    (static_cast<uint16_t>(prot_cap[11]) << 8);
                    printf("[BMC-I3C @ %7llu] Read PROT_CAP from I3C target 0x%02x: magic=\"%s\", version=0x%04x, agent_caps=0x%04x\n",
                           static_cast<unsigned long long>(cycle), I3C_REC_DYNAMIC_ADDR,
                           magic.c_str(), ver, caps);
                    fflush(stdout);
                    bmc_state = BMC_WAIT_REQ;
                }
            }
        } else if (bmc_state == BMC_WAIT_REQ) {
            if (prev_rdy_mb && mcu_entered_recovery && (cycle % 500ULL == 0)) {
                std::vector<uint8_t> dev_st;
                std::vector<uint8_t> rec_st;
                if (i3c_recovery_block_read(I3C_REC_DYNAMIC_ADDR, OCP_CMD_DEVICE_STATUS, 7, dev_st) &&
                    i3c_recovery_block_read(I3C_REC_DYNAMIC_ADDR, OCP_CMD_RECOVERY_STATUS, 2, rec_st)) {
                    uint8_t dev_status_code = dev_st[0];
                    uint8_t prot_err        = dev_st[1];
                    uint8_t rec_status_code = rec_st[0] & 0x0FU;
                    uint8_t img_idx         = (rec_st[0] >> 4) & 0x0FU;

                    if (dev_status_code == 0x3U && rec_status_code == 0x1U &&
                        img_idx < 3U && !image_sent[img_idx]) {
                        cur_img_idx  = img_idx;
                        cur_byte_idx = 0;
                        uint32_t img_dwords = static_cast<uint32_t>(recovery_unpadded_bytes[cur_img_idx] / 4);

                        // 1. Write RECOVERY_CTRL (cmd 38, 3 bytes): CMS=0, REC_IMG_SEL=0, ACTIVATE=0
                        const uint8_t rec_ctrl[3] = {0x00, 0x00, 0x00};
                        i3c_recovery_block_write(I3C_REC_DYNAMIC_ADDR, OCP_CMD_RECOVERY_CTRL, rec_ctrl, 3);

                        // 2. Write INDIRECT_FIFO_CTRL (cmd 45, 6 bytes): CMS=0, RESET=1, IMAGE_SIZE (in DWORDs, LE)
                        const uint8_t fifo_ctrl[6] = {
                            0x00,
                            0x01,
                            static_cast<uint8_t>((img_dwords >> 0)  & 0xFFU),
                            static_cast<uint8_t>((img_dwords >> 8)  & 0xFFU),
                            static_cast<uint8_t>((img_dwords >> 16) & 0xFFU),
                            static_cast<uint8_t>((img_dwords >> 24) & 0xFFU)
                        };
                        i3c_recovery_block_write(I3C_REC_DYNAMIC_ADDR, OCP_CMD_INDIRECT_FIFO_CTRL, fifo_ctrl, 6);

                        printf("\n[BMC-I3C @ %7llu] I3C Recovery request for Image %u (prot_err=0x%02x): %u DWORDs (%zu bytes, padded to %zu bytes)\n",
                               static_cast<unsigned long long>(cycle), cur_img_idx, prot_err,
                               img_dwords, recovery_unpadded_bytes[cur_img_idx],
                               recovery_images[cur_img_idx].size());
                        fflush(stdout);
                        bmc_state = BMC_STREAM_FIFO;
                    }
                }
            }
        } else if (bmc_state == BMC_STREAM_FIFO) {
            std::vector<uint8_t> fifo_st;
            if (i3c_recovery_block_read(I3C_REC_DYNAMIC_ADDR, OCP_CMD_INDIRECT_FIFO_STATUS, 20, fifo_st)) {
                bool fifo_empty = (fifo_st[0] & 0x1U) != 0;
                if (fifo_empty) {
                    const auto& img = recovery_images[cur_img_idx];
                    size_t chunk_bytes = std::min<size_t>(256, img.size() - cur_byte_idx);

                    if (i3c_recovery_block_write(I3C_REC_DYNAMIC_ADDR, OCP_CMD_INDIRECT_FIFO_DATA,
                                                 &img[cur_byte_idx], chunk_bytes)) {
                        cur_byte_idx += chunk_bytes;
                        if ((cur_byte_idx % 16384U) == 0 || cur_byte_idx >= img.size()) {
                            printf("[BMC-I3C @ %7llu] Image %u progress: %zu / %zu bytes\n",
                                   static_cast<unsigned long long>(cycle), cur_img_idx,
                                   cur_byte_idx, img.size());
                            fflush(stdout);
                        }

                        if (cur_byte_idx >= img.size()) {
                            printf("\n[BMC-I3C @ %7llu] Finished streaming Image %u over I3C (%zu/%zu bytes), waiting for DEVICE_STATUS_PENDING...\n",
                                    static_cast<unsigned long long>(cycle), cur_img_idx,
                                   cur_byte_idx, img.size());
                            fflush(stdout);
                            bmc_state = BMC_WAIT_PENDING;
                        }
                    }
                } else {
                    // Wait while MCU ROM drains the 64-DWORD Indirect FIFO
                    for (int k = 0; k < 150 && !done(); k++) {
                        step_cycle();
                        service_etrng_if_needed();
                    }
                }
            }
        } else if (bmc_state == BMC_WAIT_PENDING) {
            if (cycle % 200ULL == 0) {
                std::vector<uint8_t> dev_st;
                if (i3c_recovery_block_read(I3C_REC_DYNAMIC_ADDR, OCP_CMD_DEVICE_STATUS, 7, dev_st)) {
                    if (dev_st[0] == 0x4U) {
                        // Write RECOVERY_CTRL (cmd 38, 3 bytes): CMS=0, REC_IMG_SEL=0, ACTIVATE_REC_IMG=0x0F
                        const uint8_t act_ctrl[3] = {0x00, 0x00, 0x0F};
                        i3c_recovery_block_write(I3C_REC_DYNAMIC_ADDR, OCP_CMD_RECOVERY_CTRL, act_ctrl, 3);

                        image_sent[cur_img_idx] = true;
                        images_completed++;

                        printf("\n[BMC-I3C @ %7llu] Activated Recovery Image %u over I3C (RECOVERY_CTRL = {0x00, 0x00, 0x0F})!\n",
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
        }

        in_bmc_service = false;
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
    dut->i3c_ctrl_addr_i    = 0;
    dut->i3c_ctrl_wdata_i   = 0;
    dut->i3c_ctrl_we_i      = 0;
    dut->i3c_ctrl_re_i      = 0;

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

    if (!load_bytes(bundle_path, sim.recovery_images[0], sim.recovery_unpadded_bytes[0],
                    "Recovery Image 0 (Caliptra FW Bundle)")) {
        return 1;
    }
    if (!load_bytes(soc_manifest_path, sim.recovery_images[1], sim.recovery_unpadded_bytes[1],
                    "Recovery Image 1 (SoC Manifest)")) {
        return 1;
    }
    if (!load_bytes(mcu_rt_path, sim.recovery_images[2], sim.recovery_unpadded_bytes[2],
                    "Recovery Image 2 (MCU Runtime)")) {
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
