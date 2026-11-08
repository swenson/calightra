// SPDX-License-Identifier: Apache-2.0
#include "caliptra_verilated.h"
#include "caliptra_reg.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

static constexpr uint32_t DEFAULT_AXI_USER = 0x1;
static constexpr uint32_t CMD_FIRMWARE_LOAD = 0x46574C44; // "FWLD"
static constexpr uint32_t CMD_FW_INFO       = 0x494E464F; // "INFO"

struct SimHarness {
    caliptra_verilated* v = nullptr;
    caliptra_verilated_sig_in in{};
    caliptra_verilated_sig_out out{};
    caliptra_verilated_sig_out pre_posedge_out{};
    uint64_t total_cycles = 0;
    uint64_t prev_uout = ~0ULL;
    bool prev_uout_valid = false;
    bool waiting_for_etrng_clear = false;
    uint32_t etrng_counter = 1;
    bool quiet_uart = false;
    std::string uart_log;

    SimHarness() {
        caliptra_verilated_init_args args{};
        args.security_state = 0; // Unprovisioned, debug unlocked
        uint32_t default_obf_key[8] = {
            0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef,
            0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef
        };
        std::memcpy(args.cptra_obf_key, default_obf_key, sizeof(default_obf_key));
        for (int i = 0; i < 16; ++i) {
            args.cptra_csr_hmac_key[i] = 0x11111111u * (i + 1);
        }
        v = caliptra_verilated_new(&args);
    }

    ~SimHarness() {
        if (v) {
            caliptra_verilated_destroy(v);
        }
    }

    void raw_cycle() {
        total_cycles++;
        in.core_clk = false;
        caliptra_verilated_eval(v, &in, &out);
        pre_posedge_out = out;

        in.core_clk = true;
        caliptra_verilated_eval(v, &in, &out);

        uint64_t uout = out.generic_output_wires & 0x1ffULL;
        if (!prev_uout_valid || uout != prev_uout) {
            if (prev_uout_valid) {
                char c = static_cast<char>(uout & 0xff);
                uart_log.push_back(c);
                if (!quiet_uart) {
                    std::putchar(c);
                    if (c == '\n') std::fflush(stdout);
                }
            }
            prev_uout = uout;
            prev_uout_valid = true;
        }
    }

    void write_rom_u64(uint32_t addr, uint64_t data) {
        in.imem_addr = addr;
        in.imem_wdata = data;
        in.imem_we = true;
        raw_cycle();
        in.imem_we = false;
    }

    void load_rom_image(const std::vector<uint8_t>& img) {
        size_t padded_size = (img.size() + 7) & ~size_t(7);
        for (size_t offset = 0; offset < padded_size; offset += 8) {
            uint64_t word = 0;
            for (size_t b = 0; b < 8 && (offset + b) < img.size(); ++b) {
                word |= uint64_t(img[offset + b]) << (b * 8);
            }
            write_rom_u64(static_cast<uint32_t>(offset / 8), word);
        }
    }

    uint32_t axi_read_u32(uint32_t addr, uint32_t user = DEFAULT_AXI_USER) {
        in.s_axi_araddr = addr;
        in.s_axi_aruser = user;
        in.s_axi_arid = 0;
        in.s_axi_arlen = 0;
        in.s_axi_arsize = 2;
        in.s_axi_arburst = 1;
        in.s_axi_arlock = false;
        in.s_axi_arvalid = true;
        in.s_axi_rready = true;

        while (true) {
            raw_cycle();
            if (pre_posedge_out.s_axi_arready) break;
        }
        in.s_axi_arvalid = false;

        while (!pre_posedge_out.s_axi_rvalid) {
            raw_cycle();
        }
        uint32_t rdata = pre_posedge_out.s_axi_rdata;
        in.s_axi_rready = false;
        return rdata;
    }

    void axi_write_u32(uint32_t addr, uint32_t data, uint32_t user = DEFAULT_AXI_USER) {
        in.s_axi_awaddr = addr;
        in.s_axi_awuser = user;
        in.s_axi_awid = 0;
        in.s_axi_awlen = 0;
        in.s_axi_awsize = 2;
        in.s_axi_awburst = 1;
        in.s_axi_awlock = false;
        in.s_axi_awvalid = true;

        in.s_axi_wdata = data;
        in.s_axi_wstrb = 0xf;
        in.s_axi_wvalid = true;
        in.s_axi_wlast = true;
        in.s_axi_bready = true;

        bool aw_done = false;
        bool w_done = false;
        while (true) {
            raw_cycle();
            if (!aw_done && pre_posedge_out.s_axi_awready) {
                aw_done = true;
                in.s_axi_awvalid = false;
            }
            if (!w_done && pre_posedge_out.s_axi_wready) {
                w_done = true;
                in.s_axi_wvalid = false;
            }
            if (aw_done && w_done) break;
        }

        while (!pre_posedge_out.s_axi_bvalid) {
            raw_cycle();
        }
        in.s_axi_bready = false;
    }

    void process_etrng() {
        if (waiting_for_etrng_clear && !out.etrng_req) {
            waiting_for_etrng_clear = false;
        }
        if (out.etrng_req && !waiting_for_etrng_clear) {
            waiting_for_etrng_clear = true;
            for (uint32_t i = 0; i < 12; ++i) {
                // Deterministic non-zero entropy stream
                uint32_t val = 0x9e3779b9u * (etrng_counter * 13u + i + 1u) ^ (0x6a09e667u + i);
                axi_write_u32(CLP_SOC_IFC_REG_CPTRA_TRNG_DATA_0 + i * 4, val);
            }
            etrng_counter++;
            // Set DATA_WR_DONE (bit 1 = 0x2)
            axi_write_u32(CLP_SOC_IFC_REG_CPTRA_TRNG_STATUS, 0x2);
            if (!quiet_uart) {
                std::printf("  [ETRNG #%u serviced at cyc %llu]\n",
                    etrng_counter - 1, (unsigned long long)total_cycles);
            }
        }
    }

    void step() {
        raw_cycle();
        process_etrng();
    }

    void check_fatal_error(const char* stage) {
        if (out.cptra_error_fatal) {
            uint32_t hw_err = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_HW_ERROR_FATAL);
            uint32_t fw_err = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_FW_ERROR_FATAL);
            uint32_t boot_st = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_BOOT_STATUS);
            std::fprintf(stderr,
                "\n[FATAL ERROR] during %s at cycle %llu: HW_ERR=0x%08x FW_ERR=0x%08x BOOT_STATUS=0x%08x\n",
                stage, (unsigned long long)total_cycles, hw_err, fw_err, boot_st);
            std::exit(1);
        }
        if (total_cycles % 50000 == 0) {
            uint32_t fw_nerr = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_FW_ERROR_NON_FATAL);
            if (fw_nerr != 0) {
                uint32_t hw_nerr = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_HW_ERROR_NON_FATAL);
                uint32_t ext0 = axi_read_u32(CLP_SOC_IFC_REG_CPTRA_FW_EXTENDED_ERROR_INFO_0);
                std::fprintf(stderr,
                    "\n[NON-FATAL ERROR] during %s at cycle %llu: HW_NERR=0x%08x FW_NERR=0x%08x EXT0=0x%08x\n",
                    stage, (unsigned long long)total_cycles, hw_nerr, fw_nerr, ext0);
                std::exit(1);
            }
        }
    }
};

static std::vector<uint8_t> read_binary_file(const std::string& path) {
    std::ifstream ifs(path, std::ios::binary | std::ios::ate);
    if (!ifs) {
        std::fprintf(stderr, "Failed to open file: %s\n", path.c_str());
        std::exit(1);
    }
    std::streamsize sz = ifs.tellg();
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(sz);
    if (sz > 0 && !ifs.read(reinterpret_cast<char*>(buf.data()), sz)) {
        std::fprintf(stderr, "Failed to read file: %s\n", path.c_str());
        std::exit(1);
    }
    return buf;
}

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::string rom_path = "../fw/caliptra-rom-with-log.bin";
    std::string fw_path  = "../fw/image-bundle-mldsa.bin";
    uint64_t max_cycles  = 35000000ULL;
    bool quiet_uart      = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--rom" && i + 1 < argc) {
            rom_path = argv[++i];
        } else if (arg == "--fw" && i + 1 < argc) {
            fw_path = argv[++i];
        } else if (arg == "--max-cycles" && i + 1 < argc) {
            max_cycles = std::strtoull(argv[++i], nullptr, 0);
        } else if (arg == "--quiet") {
            quiet_uart = true;
        }
    }

    auto rom_bytes = read_binary_file(rom_path);
    auto fw_bytes  = read_binary_file(fw_path);
    std::printf("=== Calightra Verilator Boot Benchmark ===\n");
    std::printf("ROM image : %s (%zu bytes)\n", rom_path.c_str(), rom_bytes.size());
    std::printf("FW bundle : %s (%zu bytes)\n", fw_path.c_str(), fw_bytes.size());

    auto t_start = std::chrono::steady_clock::now();
    SimHarness sim;
    sim.quiet_uart = quiet_uart;

    // 1. Preload ROM into IMEM before reset deassertion
    sim.load_rom_image(rom_bytes);

    // 2. Assert pwrgood and rst_b, wait for ready_for_fuses
    sim.in.cptra_pwrgood = true;
    sim.raw_cycle();
    sim.in.cptra_rst_b = true;
    sim.raw_cycle();

    while (!sim.out.ready_for_fuses) {
        sim.raw_cycle();
    }
    uint64_t cyc_fuses = sim.total_cycles;
    std::printf("[Stage 1] ready_for_fuses high at cycle %llu\n", (unsigned long long)cyc_fuses);

    // 3. Program fuses & boot configuration
    // Set WDT timeout high enough for boot
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_WDT_CFG_0, 0x0FFFFFFF);
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_WDT_CFG_1, 0x00000000);

    // Set valid AXI users (0..4) and lock them
    for (uint32_t i = 0; i < 5; ++i) {
        sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_MBOX_VALID_AXI_USER_0 + i * 4, i);
        sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_MBOX_AXI_USER_LOCK_0 + i * 4, 1);
    }

    // Set fuse valid AXI user and lock it
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_FUSE_VALID_AXI_USER, DEFAULT_AXI_USER);
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_FUSE_AXI_USER_LOCK, 1);

    // Program UDS seed, Field Entropy, Vendor PK Hash, and Owner PK Hash
    // matching libcaliptra/examples/generic/main.c for image-bundle-mldsa.bin
    static const uint32_t default_uds_seed[16] = {
        0x00010203u, 0x04050607u, 0x08090a0bu, 0x0c0d0e0fu,
        0x10111213u, 0x14151617u, 0x18191a1bu, 0x1c1d1e1fu,
        0x20212223u, 0x24252627u, 0x28292a2bu, 0x2c2d2e2fu,
        0x30313233u, 0x34353637u, 0x38393a3bu, 0x3c3d3e3fu
    };
    static const uint32_t default_field_entropy[8] = {
        0x80818283u, 0x84858687u, 0x88898a8bu, 0x8c8d8e8fu,
        0x90919293u, 0x94959697u, 0x98999a9bu, 0x9c9d9e9fu
    };
    static const uint32_t vendor_pk_hash[12] = {
        0x30399676u, 0xa17e3e97u, 0x3677b3ffu, 0x862f4bf2u,
        0xd1932d88u, 0x4778453cu, 0x376fe00du, 0xc93fb8aau,
        0x0770f3ebu, 0xf3411a08u, 0x53e9c57eu, 0xce8a2980u
    };
    static const uint32_t owner_pk_hash[12] = {
        0x48afdb07u, 0x3c5e0d4eu, 0xe4649046u, 0x8ef81f2cu,
        0xf57249b6u, 0xe76a28f5u, 0xfca4de69u, 0x6a7d3e2eu,
        0xd3efc4e6u, 0x77431854u, 0x3e95307au, 0x54988bd7u
    };
    for (uint32_t i = 0; i < 16; ++i) {
        sim.axi_write_u32(CLP_SOC_IFC_REG_FUSE_UDS_SEED_0 + i * 4, default_uds_seed[i]);
    }
    for (uint32_t i = 0; i < 8; ++i) {
        sim.axi_write_u32(CLP_SOC_IFC_REG_FUSE_FIELD_ENTROPY_0 + i * 4, default_field_entropy[i]);
    }
    for (uint32_t i = 0; i < 12; ++i) {
        sim.axi_write_u32(CLP_SOC_IFC_REG_FUSE_VENDOR_PK_HASH_0 + i * 4, vendor_pk_hash[i]);
        sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_OWNER_PK_HASH_0 + i * 4, owner_pk_hash[i]);
    }

    // FUSE_PQC_KEY_TYPE = 1 (MLDSA)
    sim.axi_write_u32(CLP_SOC_IFC_REG_FUSE_PQC_KEY_TYPE, 1);

    // Lock fuses and trigger BootFSM
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_FUSE_WR_DONE, 1);
    sim.axi_write_u32(CLP_SOC_IFC_REG_CPTRA_BOOTFSM_GO, 1);
    uint32_t flow_st = sim.axi_read_u32(CLP_SOC_IFC_REG_CPTRA_FLOW_STATUS);
    std::printf("[Stage 1b] Fuses written & BOOTFSM_GO set at cycle %llu (FLOW_STATUS=0x%08x)\n",
        (unsigned long long)sim.total_cycles, flow_st);

    // 4. Step until ROM is ready for mailbox processing (KATs + Key Ladder complete)
    while (!sim.out.ready_for_mb_processing) {
        sim.step();
        if (sim.total_cycles % 50000 == 0) {
            auto t_now = std::chrono::steady_clock::now();
            double sec_el = std::chrono::duration<double>(t_now - t_start).count();
            uint32_t bst = sim.axi_read_u32(CLP_SOC_IFC_REG_CPTRA_BOOT_STATUS);
            std::printf("  [cyc %llu | %.2fs | %.2f kHz] BOOT_STATUS=0x%08x etrng_req=%d err_fatal=%d\n",
                (unsigned long long)sim.total_cycles,
                sec_el,
                (sim.total_cycles / 1000.0) / sec_el,
                bst,
                (int)sim.out.etrng_req,
                (int)sim.out.cptra_error_fatal);
        }
        sim.check_fatal_error("ROM Boot / KATs");
        if (sim.total_cycles > max_cycles) {
            std::fprintf(stderr, "\n[TIMEOUT] waiting for ready_for_mb_processing at cycle %llu\n",
                (unsigned long long)sim.total_cycles);
            return 1;
        }
    }
    uint64_t cyc_rom_ready = sim.total_cycles;
    auto t_rom_ready = std::chrono::steady_clock::now();
    double sec_rom = std::chrono::duration<double>(t_rom_ready - t_start).count();
    std::printf("\n[Stage 2] ROM ready_for_mb_processing at cycle %llu (%.2f s, %.2f kHz)\n",
        (unsigned long long)cyc_rom_ready, sec_rom, (cyc_rom_ready / 1000.0) / sec_rom);

    // 5. Upload firmware bundle via mailbox FW_LOAD (0x46574C44)
    uint32_t lock_val = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_LOCK);
    if (lock_val != 0) {
        std::fprintf(stderr, "Failed to acquire mailbox lock for FW_LOAD (read %u)\n", lock_val);
        return 1;
    }
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_CMD, CMD_FIRMWARE_LOAD);
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_DLEN, static_cast<uint32_t>(fw_bytes.size()));

    size_t num_words = (fw_bytes.size() + 3) / 4;
    for (size_t i = 0; i < num_words; ++i) {
        uint32_t word = 0;
        for (size_t b = 0; b < 4 && (i * 4 + b) < fw_bytes.size(); ++b) {
            word |= uint32_t(fw_bytes[i * 4 + b]) << (b * 8);
        }
        sim.axi_write_u32(CLP_MBOX_CSR_MBOX_DATAIN, word);
        sim.process_etrng();
    }
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 1);

    uint64_t cyc_fw_uploaded = sim.total_cycles;
    auto t_fw_uploaded = std::chrono::steady_clock::now();
    std::printf("\n[Stage 3] FW_LOAD uploaded (%zu bytes) at cycle %llu\n",
        fw_bytes.size(), (unsigned long long)cyc_fw_uploaded);

    // 6. Wait for FW_LOAD completion and then ready_for_runtime
    bool mbox_done = false;
    uint64_t cyc_fw_verified = 0;
    while (!sim.out.ready_for_runtime) {
        sim.step();
        if (sim.total_cycles % 50000 == 0) {
            auto t_now = std::chrono::steady_clock::now();
            double sec_el = std::chrono::duration<double>(t_now - t_start).count();
            uint32_t bst = sim.axi_read_u32(CLP_SOC_IFC_REG_CPTRA_BOOT_STATUS);
            uint32_t flw = sim.axi_read_u32(CLP_SOC_IFC_REG_CPTRA_FLOW_STATUS);
            uint32_t mst = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_STATUS);
            std::printf("  [cyc %llu | %.2fs | %.2f kHz] BOOT_STATUS=0x%08x FLOW=0x%08x MBOX_ST=0x%08x\n",
                (unsigned long long)sim.total_cycles,
                sec_el,
                (sim.total_cycles / 1000.0) / sec_el,
                bst, flw, mst);
        }
        if (sim.total_cycles % 2000 == 0) {
            sim.check_fatal_error("FW_LOAD / FMC / Runtime Boot");
        }
        if (!mbox_done && (sim.total_cycles % 2000 == 0)) {
            uint32_t st = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_STATUS) & 0xF;
            if (st != 0) { // No longer CMD_BUSY
                if (st != 2) { // Expect CMD_COMPLETE (2)
                    std::fprintf(stderr, "\n[ERROR] FW_LOAD mailbox status=%u (expected 2)\n", st);
                    return 1;
                }
                sim.axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0);
                mbox_done = true;
                cyc_fw_verified = sim.total_cycles;
                auto t_now = std::chrono::steady_clock::now();
                double sec_ver = std::chrono::duration<double>(t_now - t_fw_uploaded).count();
                std::printf("\n[Stage 4] ROM FW_LOAD verified & loaded at cycle %llu (+%llu cyc, %.2f s)\n",
                    (unsigned long long)cyc_fw_verified,
                    (unsigned long long)(cyc_fw_verified - cyc_fw_uploaded),
                    sec_ver);
            }
        }
        if (sim.total_cycles > max_cycles) {
            std::fprintf(stderr, "\n[TIMEOUT] waiting for ready_for_runtime at cycle %llu\n",
                (unsigned long long)sim.total_cycles);
            return 1;
        }
    }
    if (!mbox_done) {
        sim.axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0);
    }

    uint64_t cyc_rt_ready = sim.total_cycles;
    auto t_rt_ready = std::chrono::steady_clock::now();
    double sec_total = std::chrono::duration<double>(t_rt_ready - t_start).count();
    std::printf("\n[Stage 5] Runtime ready_for_runtime HIGH at cycle %llu (Total: %.2f s, %.2f kHz)\n",
        (unsigned long long)cyc_rt_ready, sec_total, (cyc_rt_ready / 1000.0) / sec_total);

    // 7. Execute FW_INFO (0x494E464F) mailbox command to prove Runtime is live!
    lock_val = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_LOCK);
    if (lock_val != 0) {
        std::fprintf(stderr, "Failed to acquire mailbox lock for FW_INFO (read %u)\n", lock_val);
        return 1;
    }
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_CMD, CMD_FW_INFO);
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_DLEN, 4);
    // Checksum for 0x494E464F ("INFO") with 0 payload bytes:
    // 0 - (0x4F + 0x46 + 0x4E + 0x49) = 0xFFFFFED4
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_DATAIN, 0xFFFFFED4u);
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 1);

    uint32_t info_status = 0;
    while (info_status == 0) {
        for (int i = 0; i < 200; ++i) {
            sim.step();
            sim.check_fatal_error("Runtime FW_INFO");
        }
        info_status = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_STATUS) & 0xF;
    }
    if (info_status != 1) { // Expect DATA_READY (1)
        std::fprintf(stderr, "\n[ERROR] FW_INFO mailbox status=%u (expected 1=DATA_READY)\n", info_status);
        return 1;
    }
    uint32_t resp_dlen = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_DLEN);
    std::vector<uint32_t> resp_words((resp_dlen + 3) / 4);
    for (size_t i = 0; i < resp_words.size(); ++i) {
        resp_words[i] = sim.axi_read_u32(CLP_MBOX_CSR_MBOX_DATAOUT);
    }
    sim.axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0);
    sim.step();

    auto t_end = std::chrono::steady_clock::now();
    double sec_end = std::chrono::duration<double>(t_end - t_start).count();

    std::printf("\n[Stage 6] Runtime FW_INFO response received (%u bytes) at cycle %llu!\n",
        resp_dlen, (unsigned long long)sim.total_cycles);
    if (resp_words.size() >= 10) {
        std::printf("  fips_status : 0x%08x\n", resp_words[1]);
        std::printf("  fw_svn      : %u\n", resp_words[3]);
        char rom_rev[21] = {0}, fmc_rev[21] = {0}, rt_rev[21] = {0};
        std::memcpy(rom_rev, &resp_words[7], 20);
        std::memcpy(fmc_rev, &resp_words[12], 20);
        std::memcpy(rt_rev,  &resp_words[17], 20);
        std::printf("  rom_rev     : %.20s\n", rom_rev);
        std::printf("  fmc_rev     : %.20s\n", fmc_rev);
        std::printf("  rt_rev      : %.20s\n", rt_rev);
    }

    std::printf("\n=== SUMMARY ===\n");
    std::printf("  ROM Boot + KATs : %10llu cycles\n", (unsigned long long)cyc_rom_ready);
    std::printf("  FW Upload       : %10llu cycles\n", (unsigned long long)(cyc_fw_uploaded - cyc_rom_ready));
    std::printf("  FW Verify/Load  : %10llu cycles\n", (unsigned long long)(cyc_fw_verified - cyc_fw_uploaded));
    std::printf("  FMC + RT Boot   : %10llu cycles\n", (unsigned long long)(cyc_rt_ready - cyc_fw_verified));
    std::printf("  Total Cycles    : %10llu cycles\n", (unsigned long long)sim.total_cycles);
    std::printf("  Wall-Clock Time : %10.2f seconds\n", sec_end);
    std::printf("  Effective Speed : %10.2f kHz\n", (sim.total_cycles / 1000.0) / sec_end);
    std::printf("===============\n");

    return 0;
}
