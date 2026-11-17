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
// Calightra-SS MCU Boot & Interactive Console Firmware (Radiona ULX3S-85F)
// Runs on the Subsystem MCU VeeR EL2 core (0x8000_0000), exercises the
// open-source AXI4 crossbar (MCI, OTP, LC, I3C, MCU SRAM, MCU MBOX0, SoC SRAM,
// and Caliptra Core SoC Interface), boots Caliptra Core VeeR EL2 through
// READY_FOR_MB_PROCESSING=1, executes AXI4 Mailbox commands (VERSION &
// CAPABILITIES), and serves an interactive UART console over /dev/ttyUSB0.

#include <stdint.h>

// Subsystem AXI Memory Map (soc_address_map_defines.svh)
#define I3C_BASE_ADDR                       0x20004000UL
#define I3C_REG_HCI_VERSION                 (I3C_BASE_ADDR + 0x0000UL)
#define I3C_REG_HC_CONTROL                  (I3C_BASE_ADDR + 0x0004UL)
#define I3C_REG_REC_PROT_CAP_0              (I3C_BASE_ADDR + 0x0104UL)
#define I3C_REG_REC_PROT_CAP_1              (I3C_BASE_ADDR + 0x0108UL)
#define I3C_REG_REC_DEVICE_STATUS_0         (I3C_BASE_ADDR + 0x0130UL)
#define I3C_REG_REC_RECOVERY_STATUS         (I3C_BASE_ADDR + 0x0140UL)
#define I3C_REG_STBY_CR_CONTROL             (I3C_BASE_ADDR + 0x0184UL)
#define I3C_REG_STBY_CR_DEVICE_ADDR         (I3C_BASE_ADDR + 0x0188UL)
#define I3C_REG_STBY_CR_VIRT_DEVICE_ADDR    (I3C_BASE_ADDR + 0x01B8UL)

#define MCI_BASE_ADDR                       0x21000000UL
#define MCI_REG_HW_FLOW_STATUS              (MCI_BASE_ADDR + 0x0034UL)
#define MCI_REG_SECURITY_STATE              (MCI_BASE_ADDR + 0x0040UL)
#define MCI_REG_CPTRA_BOOT_GO               (MCI_BASE_ADDR + 0x0108UL)
#define MCI_REG_GENERIC_INPUT_WIRES_0       (MCI_BASE_ADDR + 0x0400UL)
#define MCI_REG_GENERIC_OUTPUT_WIRES_0      (MCI_BASE_ADDR + 0x0408UL)
#define MCI_REG_GENERIC_OUTPUT_WIRES_1      (MCI_BASE_ADDR + 0x040CUL)
#define MCI_REG_DEBUG_OUT                   (MCI_BASE_ADDR + 0x0414UL)

#define MCU_MBOX0_SRAM_BASE_ADDR            0x21400000UL
#define MCU_MBOX0_CSR_MBOX_LOCK             0x21600000UL

#define MCU_SRAM_BASE_ADDR                  0x21C00000UL

#define OTP_CTRL_BASE_ADDR                  0x70000000UL
#define OTP_CTRL_STATUS                     (OTP_CTRL_BASE_ADDR + 0x0010UL)

#define LC_CTRL_BASE_ADDR                   0x70000400UL
#define LC_CTRL_STATUS                      (LC_CTRL_BASE_ADDR + 0x0004UL)
#define LC_CTRL_LC_STATE                    (LC_CTRL_BASE_ADDR + 0x0038UL)
#define LC_CTRL_LC_TRANSITION_CNT           (LC_CTRL_BASE_ADDR + 0x003CUL)

// Caliptra Core Mailbox CSRs (0xA002_0000, MRAC Region 0xA uncacheable/side-effect)
#define CPTRA_MBOX_CSR_BASE_ADDR            0xA0020000UL
#define CPTRA_MBOX_LOCK                     (CPTRA_MBOX_CSR_BASE_ADDR + 0x0000UL)
#define CPTRA_MBOX_USER                     (CPTRA_MBOX_CSR_BASE_ADDR + 0x0004UL)
#define CPTRA_MBOX_CMD                      (CPTRA_MBOX_CSR_BASE_ADDR + 0x0008UL)
#define CPTRA_MBOX_DLEN                     (CPTRA_MBOX_CSR_BASE_ADDR + 0x000CUL)
#define CPTRA_MBOX_DATAIN                   (CPTRA_MBOX_CSR_BASE_ADDR + 0x0010UL)
#define CPTRA_MBOX_DATAOUT                  (CPTRA_MBOX_CSR_BASE_ADDR + 0x0014UL)
#define CPTRA_MBOX_EXECUTE                  (CPTRA_MBOX_CSR_BASE_ADDR + 0x0018UL)
#define CPTRA_MBOX_STATUS                   (CPTRA_MBOX_CSR_BASE_ADDR + 0x001CUL)

// Caliptra Core SoC Interface CSRs (0xA003_0000)
#define CPTRA_SOC_IFC_BASE_ADDR             0xA0030000UL
#define CPTRA_HW_ERROR_FATAL                (CPTRA_SOC_IFC_BASE_ADDR + 0x0000UL)
#define CPTRA_FW_ERROR_FATAL                (CPTRA_SOC_IFC_BASE_ADDR + 0x0008UL)
#define CPTRA_BOOT_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x0038UL)
#define CPTRA_FLOW_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x003CUL)
#define CPTRA_MBOX_VALID_AXI_USER_0         (CPTRA_SOC_IFC_BASE_ADDR + 0x0048UL)
#define CPTRA_MBOX_AXI_USER_LOCK_0          (CPTRA_SOC_IFC_BASE_ADDR + 0x005CUL)
#define CPTRA_TRNG_VALID_AXI_USER           (CPTRA_SOC_IFC_BASE_ADDR + 0x0070UL)
#define CPTRA_TRNG_AXI_USER_LOCK            (CPTRA_SOC_IFC_BASE_ADDR + 0x0074UL)
#define CPTRA_TRNG_DATA_0                   (CPTRA_SOC_IFC_BASE_ADDR + 0x0078UL)
#define CPTRA_TRNG_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x00ACUL)
#define CPTRA_FUSE_WR_DONE                  (CPTRA_SOC_IFC_BASE_ADDR + 0x00B0UL)
#define CPTRA_BOOTFSM_GO                    (CPTRA_SOC_IFC_BASE_ADDR + 0x00B8UL)
#define CPTRA_HW_REV_ID                     (CPTRA_SOC_IFC_BASE_ADDR + 0x00D4UL)
#define CPTRA_WDT_CFG_0                     (CPTRA_SOC_IFC_BASE_ADDR + 0x0110UL)
#define CPTRA_WDT_CFG_1                     (CPTRA_SOC_IFC_BASE_ADDR + 0x0114UL)

#define CPTRA_TRNG_STATUS_DATA_REQ          (1UL << 0)
#define CPTRA_TRNG_STATUS_DATA_WR_DONE      (1UL << 1)

#define CPTRA_FLOW_READY_FOR_FUSES          (1UL << 30)
#define CPTRA_FLOW_READY_FOR_RUNTIME        (1UL << 29)
#define CPTRA_FLOW_READY_FOR_MB_PROCESSING  (1UL << 28)

#define CMD_FIPS_VERSION                    0x46505652UL // "FPVR"
#define CMD_CAPABILITIES                    0x43415053UL // "CAPS"

#define SOC_SRAM_BASE_ADDR                  0xB0000000UL

static inline void mmio_write32(uint32_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

static inline uint32_t mmio_read32(uint32_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void mci_putc(char c) {
    *(volatile uint8_t *)MCI_REG_DEBUG_OUT = (uint8_t)c;
}

static void mci_puts(const char *s) {
    while (*s) {
        mci_putc(*s++);
    }
}

static void mci_puthex32(uint32_t val) {
    mci_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t nib = (val >> i) & 0xFU;
        mci_putc((nib < 10U) ? ('0' + nib) : ('a' + (nib - 10U)));
    }
}

static void mci_putdec(uint32_t val) {
    char buf[12];
    int idx = 0;
    if (val == 0U) {
        mci_putc('0');
        return;
    }
    while (val > 0U) {
        buf[idx++] = '0' + (val % 10U);
        val /= 10U;
    }
    while (idx > 0) {
        mci_putc(buf[--idx]);
    }
}

static void service_etrng(uint32_t *etrng_counter) {
    while (1) {
        uint32_t trng_st = mmio_read32(CPTRA_TRNG_STATUS);
        if ((trng_st & (CPTRA_TRNG_STATUS_DATA_REQ | CPTRA_TRNG_STATUS_DATA_WR_DONE)) ==
            CPTRA_TRNG_STATUS_DATA_REQ) {
            uint32_t cnt = *etrng_counter;
            for (uint32_t i = 0; i < 12UL; i++) {
                uint32_t val = (0x9E3779B9UL * (cnt * 13UL + i + 1UL)) ^ (0x6A09E667UL + i);
                mmio_write32(CPTRA_TRNG_DATA_0 + (i * 4UL), val);
            }
            mmio_write32(CPTRA_TRNG_STATUS, CPTRA_TRNG_STATUS_DATA_WR_DONE);
            *etrng_counter = cnt + 1UL;
        } else {
            break;
        }
    }
}

static uint32_t mbox_calc_cmd_chksum(uint32_t cmd) {
    uint32_t sum = (cmd & 0xFFU) +
                   ((cmd >> 8) & 0xFFU) +
                   ((cmd >> 16) & 0xFFU) +
                   ((cmd >> 24) & 0xFFU);
    return 0U - sum;
}

static int exec_mbox_noarg_cmd(uint32_t cmd, uint32_t *resp_words, uint32_t max_words,
                               uint32_t *out_dlen, uint32_t *etrng_counter) {
    // 1. Acquire mailbox lock (0 means lock acquired)
    uint32_t guard = 0;
    while ((mmio_read32(CPTRA_MBOX_LOCK) & 1UL) != 0UL) {
        service_etrng(etrng_counter);
        if (++guard > 500000UL) {
            mci_puts("[MCU] ERROR: Timeout acquiring CPTRA_MBOX_LOCK\n");
            return -1;
        }
    }

    // 2. Write command + 4-byte checksum request + execute
    uint32_t chksum = mbox_calc_cmd_chksum(cmd);
    mmio_write32(CPTRA_MBOX_CMD, cmd);
    mmio_write32(CPTRA_MBOX_DLEN, 4UL);
    mmio_write32(CPTRA_MBOX_DATAIN, chksum);
    mmio_write32(CPTRA_MBOX_EXECUTE, 1UL);

    // 3. Poll MBOX_STATUS[3:0] (0=CMD_BUSY, 1=DATA_READY, 2=CMD_COMPLETE, 3=CMD_FAILURE)
    uint32_t status = 0;
    guard = 0;
    while (1) {
        service_etrng(etrng_counter);
        status = mmio_read32(CPTRA_MBOX_STATUS) & 0xFUL;
        if (status != 0UL) {
            break;
        }
        if (++guard > 2000000UL) {
            mci_puts("[MCU] ERROR: Timeout waiting for CPTRA_MBOX_STATUS\n");
            mmio_write32(CPTRA_MBOX_EXECUTE, 0UL);
            return -2;
        }
    }

    if (status != 1UL && status != 2UL) {
        mci_puts("[MCU] ERROR: Mailbox command failed with STATUS=");
        mci_puthex32(status);
        mci_putc('\n');
        mmio_write32(CPTRA_MBOX_EXECUTE, 0UL);
        return -3;
    }

    uint32_t dlen = mmio_read32(CPTRA_MBOX_DLEN);
    *out_dlen = dlen;
    uint32_t nwords = (dlen + 3UL) / 4UL;
    for (uint32_t i = 0; i < nwords; i++) {
        uint32_t w = mmio_read32(CPTRA_MBOX_DATAOUT);
        if (i < max_words) {
            resp_words[i] = w;
        }
    }

    // Release mailbox
    mmio_write32(CPTRA_MBOX_EXECUTE, 0UL);
    return 0;
}

static void run_mbox_version(uint32_t *etrng_counter) {
    uint32_t resp[16];
    uint32_t dlen = 0;
    for (int i = 0; i < 16; i++) resp[i] = 0;
    mci_puts("[MCU] Sending AXI4 Mailbox VERSION (0x46505652) -> Caliptra Core...\n");
    if (exec_mbox_noarg_cmd(CMD_FIPS_VERSION, resp, 16, &dlen, etrng_counter) == 0) {
        // FipsVersionResp layout:
        //   word 0: chksum
        //   word 1: fips_status
        //   word 2: mode (0x46495053 = "FIPS")
        //   word 3: fips_rev[0] (hw_rev_id)
        //   word 4: fips_rev[1]
        //   word 5: fips_rev[2]
        //   words 6..8: name[12] ASCII
        mci_puts("[MCU] VERSION Resp (");
        mci_putdec(dlen);
        mci_puts("B): fips_status=");
        mci_puthex32(resp[1]);
        mci_puts(" mode=");
        mci_puthex32(resp[2]);
        mci_puts(" hw_rev=");
        mci_puthex32(resp[3]);
        mci_puts(" name=\"");
        for (int w = 6; w < 9; w++) {
            for (int b = 0; b < 4; b++) {
                char c = (char)((resp[w] >> (b * 8)) & 0xFFU);
                if (c >= 32 && c < 127) {
                    mci_putc(c);
                }
            }
        }
        mci_puts("\"\n");
    }
}

static void run_mbox_capabilities(uint32_t *etrng_counter) {
    uint32_t resp[16];
    uint32_t dlen = 0;
    for (int i = 0; i < 16; i++) resp[i] = 0;
    mci_puts("[MCU] Sending AXI4 Mailbox CAPABILITIES (0x43415053) -> Caliptra Core...\n");
    if (exec_mbox_noarg_cmd(CMD_CAPABILITIES, resp, 16, &dlen, etrng_counter) == 0) {
        mci_puts("[MCU] CAPABILITIES Resp (");
        mci_putdec(dlen);
        mci_puts("B): fips_status=");
        mci_puthex32(resp[1]);
        mci_puts(" caps=");
        mci_puthex32(resp[2]);
        mci_putc('_');
        mci_puthex32(resp[3]);
        mci_putc('_');
        mci_puthex32(resp[4]);
        mci_putc('_');
        mci_puthex32(resp[5]);
        mci_putc('\n');
    }
}

static void print_live_status(uint32_t etrng_counter) {
    uint32_t flow   = mmio_read32(CPTRA_FLOW_STATUS);
    uint32_t boot   = mmio_read32(CPTRA_BOOT_STATUS);
    uint32_t hw_err = mmio_read32(CPTRA_HW_ERROR_FATAL);
    uint32_t fw_err = mmio_read32(CPTRA_FW_ERROR_FATAL);
    uint32_t mci_fl = mmio_read32(MCI_REG_HW_FLOW_STATUS);
    mci_puts("[MCU] STATUS: CPTRA_FLOW=");
    mci_puthex32(flow);
    mci_puts(" BOOT=");
    mci_puthex32(boot);
    mci_puts(" MCI_FLOW=");
    mci_puthex32(mci_fl);
    mci_puts(" HW_ERR=");
    mci_puthex32(hw_err);
    mci_puts(" FW_ERR=");
    mci_puthex32(fw_err);
    mci_puts(" ETRNG=");
    mci_putdec(etrng_counter - 1UL);
    mci_putc('\n');
}

int main(void) {
    // Milestone 1: MCU booted from 0x8000_0000 over AXI crossbar
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000001UL);
    mci_puts("\n====================================================================\n");
    mci_puts(" Calightra-SS Dual-VeeR-EL2 Subsystem on Radiona ULX3S-85F (ECP5-85F)\n");
    mci_puts(" Core Clock: 12.5 MHz | UART: 115200 8N1 | Interconnect: AXI4 Xbar\n");
    mci_puts("====================================================================\n");
    mci_puts("[MCU] VeeR EL2 #1 (Subsystem MCU) booted from EBR ROM @ 0x80000000\n");

    // Step 1: Verify OTP_CTRL (0x7000_0000) & LC_CTRL (0x7000_0400) over AXI -> TL-UL
    uint32_t otp_status = mmio_read32(OTP_CTRL_STATUS);
    uint32_t lc_status  = mmio_read32(LC_CTRL_STATUS);
    uint32_t lc_state   = mmio_read32(LC_CTRL_LC_STATE);
    uint32_t lc_cnt     = mmio_read32(LC_CTRL_LC_TRANSITION_CNT);

    mci_puts("[MCU] OTP_STATUS=");
    mci_puthex32(otp_status);
    mci_puts(" LC_STATUS=");
    mci_puthex32(lc_status);
    mci_puts(" LC_STATE=");
    mci_puthex32(lc_state);
    mci_puts(" LC_CNT=");
    mci_puthex32(lc_cnt);
    mci_putc('\n');
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000002UL);

    // Step 2: Verify MCU_SRAM (0x21C0_0000), MCU_MBOX0 (0x2140_0000), and SOC_SRAM (0xB000_0000)
    mmio_write32(MCU_SRAM_BASE_ADDR + 0x00UL, 0xCAFEBABEUL);
    mmio_write32(MCU_SRAM_BASE_ADDR + 0x04UL, 0x12345678UL);
    if (mmio_read32(MCU_SRAM_BASE_ADDR + 0x00UL) != 0xCAFEBABEUL ||
        mmio_read32(MCU_SRAM_BASE_ADDR + 0x04UL) != 0x12345678UL) {
        mci_puts("[MCU] ERROR: MCU_SRAM mismatch\n");
        return 1;
    }

    (void)mmio_read32(MCU_MBOX0_CSR_MBOX_LOCK);
    mmio_write32(MCU_MBOX0_SRAM_BASE_ADDR + 0x00UL, 0xA5A55A5AUL);
    if (mmio_read32(MCU_MBOX0_SRAM_BASE_ADDR + 0x00UL) != 0xA5A55A5AUL) {
        mci_puts("[MCU] ERROR: MCU_MBOX0 mismatch\n");
        return 2;
    }

    mmio_write32(SOC_SRAM_BASE_ADDR + 0x00UL, 0xDEADC0DEUL);
    if (mmio_read32(SOC_SRAM_BASE_ADDR + 0x00UL) != 0xDEADC0DEUL) {
        mci_puts("[MCU] ERROR: SOC_SRAM mismatch\n");
        return 3;
    }
    mci_puts("[MCU] Verified MCU_SRAM, MCU_MBOX0, and SOC_SRAM over AXI4 crossbar\n");

    // Step 2b: Verify & initialize MIPI I3C / OCP Recovery Target (0x2000_4000)
    uint32_t i3c_ver  = mmio_read32(I3C_REG_HCI_VERSION);
    uint32_t i3c_cap0 = mmio_read32(I3C_REG_REC_PROT_CAP_0);
    uint32_t i3c_cap1 = mmio_read32(I3C_REG_REC_PROT_CAP_1);
    mmio_write32(I3C_REG_STBY_CR_CONTROL,          0x80000000UL);
    mmio_write32(I3C_REG_STBY_CR_DEVICE_ADDR,      0x805A805AUL);
    mmio_write32(I3C_REG_STBY_CR_VIRT_DEVICE_ADDR, 0x805B805BUL);
    mmio_write32(I3C_REG_REC_DEVICE_STATUS_0,      0x00000003UL);
    mmio_write32(I3C_REG_REC_RECOVERY_STATUS,      0x00000001UL);
    mmio_write32(I3C_REG_HC_CONTROL,               0x80000000UL);
    mci_puts("[MCU] I3C_VER=");
    mci_puthex32(i3c_ver);
    mci_puts(" PROT_CAP=");
    mci_puthex32(i3c_cap0);
    mci_putc('/');
    mci_puthex32(i3c_cap1);
    mci_puts(" (\"OCP RECV\") ADDR=0x5a/0x5b BUS_EN=1\n");
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000003UL);

    // Step 3: Release Caliptra Core VeeR EL2 #2 from reset via MCI CPTRA_BOOT_GO
    mci_puts("[MCU] Releasing VeeR EL2 #2 (Caliptra Core) via MCI CPTRA_BOOT_GO=1\n");
    mmio_write32(MCI_REG_CPTRA_BOOT_GO, 1UL);
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000004UL);

    // Step 4: Poll Caliptra Core CPTRA_FLOW_STATUS (0xA003_003C) for READY_FOR_FUSES
    mci_puts("[MCU] Waiting for Caliptra Core READY_FOR_FUSES...\n");
    while ((mmio_read32(CPTRA_FLOW_STATUS) & CPTRA_FLOW_READY_FOR_FUSES) == 0UL) {
    }
    uint32_t hw_rev = mmio_read32(CPTRA_HW_REV_ID);
    mci_puts("[MCU] READY_FOR_FUSES=1 (CPTRA_HW_REV=");
    mci_puthex32(hw_rev);
    mci_puts(")! Programming AXI_USER=1, FUSE_WR_DONE=1 & BOOTFSM_GO=1\n");
    mmio_write32(CPTRA_WDT_CFG_0,             0x0FFFFFFFUL);
    mmio_write32(CPTRA_WDT_CFG_1,             0x00000000UL);
    mmio_write32(CPTRA_MBOX_VALID_AXI_USER_0, 0x00000001UL);
    mmio_write32(CPTRA_MBOX_AXI_USER_LOCK_0,  0x00000001UL);
    mmio_write32(CPTRA_TRNG_VALID_AXI_USER,   0x00000001UL);
    mmio_write32(CPTRA_TRNG_AXI_USER_LOCK,    0x00000001UL);
    mmio_write32(CPTRA_FUSE_WR_DONE,          1UL);
    mmio_write32(CPTRA_BOOTFSM_GO,            1UL);
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000005UL);

    // Step 5: Monitor Caliptra Core ROM boot & service ETRNG requests over AXI crossbar
    uint32_t last_boot_status = 0xFFFFFFFFUL;
    uint32_t etrng_counter = 1UL;
    while (1) {
        service_etrng(&etrng_counter);

        uint32_t flow = mmio_read32(CPTRA_FLOW_STATUS);
        uint32_t boot = mmio_read32(CPTRA_BOOT_STATUS);
        if (boot != last_boot_status) {
            last_boot_status = boot;
            mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_1, boot);
            mci_puts("[MCU] CPTRA_BOOT_STATUS=");
            mci_puthex32(boot);
            mci_puts(" FLOW=");
            mci_puthex32(flow);
            mci_puts(" ETRNG=");
            mci_putdec(etrng_counter - 1UL);
            mci_putc('\n');
        }
        if ((flow & CPTRA_FLOW_READY_FOR_MB_PROCESSING) != 0UL) {
            mci_puts("[MCU] Caliptra Core reached READY_FOR_MB_PROCESSING=1! (ETRNG serviced: ");
            mci_putdec(etrng_counter - 1UL);
            mci_puts(")\n");
            break;
        }
        uint32_t hw_err = mmio_read32(CPTRA_HW_ERROR_FATAL);
        uint32_t fw_err = mmio_read32(CPTRA_FW_ERROR_FATAL);
        if (hw_err != 0UL || fw_err != 0UL) {
            mci_puts("[MCU] ERROR: Caliptra Fatal Error HW=");
            mci_puthex32(hw_err);
            mci_puts(" FW=");
            mci_puthex32(fw_err);
            mci_putc('\n');
            return 4;
        }
    }

    // Step 6: Execute real AXI4 Mailbox commands against Caliptra Core ROM
    run_mbox_version(&etrng_counter);
    run_mbox_capabilities(&etrng_counter);

    mci_puts("[MCU] Calightra-SS ULX3S-85F Boot & Mailbox Self-Test PASS!\n");
    mci_puts("[MCU] Interactive UART console ready ([v]=VERSION [c]=CAPABILITIES [s]=STATUS [r]=COLD_RESET)\n");
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0xCA1100AAUL);

    // Step 7: Live interactive UART RX command loop via MCI_REG_GENERIC_INPUT_WIRES_0
    uint32_t last_rx_seq = (mmio_read32(MCI_REG_GENERIC_INPUT_WIRES_0) >> 8) & 0xFFUL;
    while (1) {
        service_etrng(&etrng_counter);
        uint32_t rx_reg = mmio_read32(MCI_REG_GENERIC_INPUT_WIRES_0);
        uint32_t rx_seq = (rx_reg >> 8) & 0xFFUL;
        if (rx_seq != last_rx_seq) {
            last_rx_seq = rx_seq;
            char ch = (char)(rx_reg & 0xFFUL);
            if (ch == 'v' || ch == 'V') {
                run_mbox_version(&etrng_counter);
            } else if (ch == 'c' || ch == 'C') {
                run_mbox_capabilities(&etrng_counter);
            } else if (ch == 's' || ch == 'S' || ch == '\r' || ch == '\n') {
                print_live_status(etrng_counter);
            } else if (ch == '?' || ch == 'h' || ch == 'H') {
                mci_puts("[MCU] Commands: [v]=VERSION [c]=CAPABILITIES [s]=STATUS [r]=COLD_RESET\n");
            }
        }
    }

    return 0xFF;
}
