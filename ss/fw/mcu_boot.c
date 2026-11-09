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
// Calightra-SS MCU Boot Firmware
// Runs on the MCU VeeR EL2 core (0x8000_0000), exercises the open-source
// AXI4 crossbar (MCI, OTP, LC, MCU SRAM, MCU MBOX0, SoC SRAM, and Caliptra Core
// SoC Interface), releases Caliptra Core from reset via MCI CPTRA_BOOT_GO,
// performs the fuse/bootfsm handshake, and coordinates Caliptra Core ROM boot.

#include <stdint.h>

// Subsystem AXI Memory Map (soc_address_map_defines.svh)
#define I3C_BASE_ADDR                       0x20004000UL
#define I3C_REG_HCI_VERSION                 (I3C_BASE_ADDR + 0x0000UL)
#define I3C_REG_HC_CONTROL                  (I3C_BASE_ADDR + 0x0004UL)
#define I3C_REG_REC_PROT_CAP_0              (I3C_BASE_ADDR + 0x0104UL)
#define I3C_REG_REC_PROT_CAP_1              (I3C_BASE_ADDR + 0x0108UL)
#define I3C_REG_REC_PROT_CAP_2              (I3C_BASE_ADDR + 0x010CUL)
#define I3C_REG_REC_DEVICE_STATUS_0         (I3C_BASE_ADDR + 0x0130UL)
#define I3C_REG_REC_RECOVERY_STATUS         (I3C_BASE_ADDR + 0x0140UL)
#define I3C_REG_STBY_CR_CONTROL             (I3C_BASE_ADDR + 0x0184UL)
#define I3C_REG_STBY_CR_DEVICE_ADDR         (I3C_BASE_ADDR + 0x0188UL)
#define I3C_REG_STBY_CR_VIRT_DEVICE_ADDR    (I3C_BASE_ADDR + 0x01B8UL)

#define MCI_BASE_ADDR                       0x21000000UL
#define MCI_REG_HW_FLOW_STATUS              (MCI_BASE_ADDR + 0x0034UL)
#define MCI_REG_SECURITY_STATE              (MCI_BASE_ADDR + 0x0040UL)
#define MCI_REG_CPTRA_BOOT_GO               (MCI_BASE_ADDR + 0x0108UL)
#define MCI_REG_FW_REV_ID_0                 (MCI_BASE_ADDR + 0x0114UL)
#define MCI_REG_GENERIC_OUTPUT_WIRES_0      (MCI_BASE_ADDR + 0x0408UL)
#define MCI_REG_GENERIC_OUTPUT_WIRES_1      (MCI_BASE_ADDR + 0x040CUL)
#define MCI_REG_DEBUG_OUT                   (MCI_BASE_ADDR + 0x0414UL)

#define MCU_MBOX0_SRAM_BASE_ADDR            0x21400000UL
#define MCU_MBOX0_CSR_MBOX_LOCK             0x21600000UL
#define MCU_MBOX0_CSR_MBOX_CMD              0x21600008UL
#define MCU_MBOX0_CSR_MBOX_DLEN             0x2160000CUL
#define MCU_MBOX0_CSR_MBOX_EXECUTE          0x21600010UL

#define MCU_SRAM_BASE_ADDR                  0x21C00000UL

#define OTP_CTRL_BASE_ADDR                  0x70000000UL
#define OTP_CTRL_STATUS                     (OTP_CTRL_BASE_ADDR + 0x0010UL)

#define LC_CTRL_BASE_ADDR                   0x70000400UL
#define LC_CTRL_STATUS                      (LC_CTRL_BASE_ADDR + 0x0004UL)
#define LC_CTRL_LC_STATE                    (LC_CTRL_BASE_ADDR + 0x0038UL)
#define LC_CTRL_LC_TRANSITION_CNT           (LC_CTRL_BASE_ADDR + 0x003CUL)

#define CPTRA_SOC_IFC_BASE_ADDR             0xA0030000UL
#define CPTRA_HW_ERROR_FATAL                (CPTRA_SOC_IFC_BASE_ADDR + 0x0000UL)
#define CPTRA_FW_ERROR_FATAL                (CPTRA_SOC_IFC_BASE_ADDR + 0x0008UL)
#define CPTRA_BOOT_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x0038UL)
#define CPTRA_FLOW_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x003CUL)
#define CPTRA_TRNG_DATA_0                   (CPTRA_SOC_IFC_BASE_ADDR + 0x0078UL)
#define CPTRA_TRNG_STATUS                   (CPTRA_SOC_IFC_BASE_ADDR + 0x00ACUL)
#define CPTRA_FUSE_WR_DONE                  (CPTRA_SOC_IFC_BASE_ADDR + 0x00B0UL)
#define CPTRA_BOOTFSM_GO                    (CPTRA_SOC_IFC_BASE_ADDR + 0x00B8UL)
#define CPTRA_WDT_CFG_0                     (CPTRA_SOC_IFC_BASE_ADDR + 0x0110UL)
#define CPTRA_WDT_CFG_1                     (CPTRA_SOC_IFC_BASE_ADDR + 0x0114UL)

#define CPTRA_TRNG_STATUS_DATA_REQ          (1UL << 0)
#define CPTRA_TRNG_STATUS_DATA_WR_DONE      (1UL << 1)

#define CPTRA_FLOW_READY_FOR_FUSES          (1UL << 30)
#define CPTRA_FLOW_READY_FOR_RUNTIME        (1UL << 29)
#define CPTRA_FLOW_READY_FOR_MB_PROCESSING  (1UL << 28)

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

int main(void) {
    // Milestone 1: MCU booted from 0x8000_0000 over AXI crossbar
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000001UL);
    mci_puts("\n[MCU] Calightra-SS MCU VeeR EL2 booted from 0x80000000\n");

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
    uint32_t mcu_sram_v0 = mmio_read32(MCU_SRAM_BASE_ADDR + 0x00UL);
    uint32_t mcu_sram_v1 = mmio_read32(MCU_SRAM_BASE_ADDR + 0x04UL);
    if (mcu_sram_v0 != 0xCAFEBABEUL || mcu_sram_v1 != 0x12345678UL) {
        mci_puts("[MCU] ERROR: MCU_SRAM mismatch\n");
        return 1;
    }

    // Acquire MCU_MBOX0 lock before writing MBOX0 SRAM
    (void)mmio_read32(MCU_MBOX0_CSR_MBOX_LOCK);
    mmio_write32(MCU_MBOX0_SRAM_BASE_ADDR + 0x00UL, 0xA5A55A5AUL);
    uint32_t mbox0_v0 = mmio_read32(MCU_MBOX0_SRAM_BASE_ADDR + 0x00UL);
    if (mbox0_v0 != 0xA5A55A5AUL) {
        mci_puts("[MCU] ERROR: MCU_MBOX0 mismatch\n");
        return 2;
    }

    mmio_write32(SOC_SRAM_BASE_ADDR + 0x00UL, 0xDEADC0DEUL);
    if (mmio_read32(SOC_SRAM_BASE_ADDR + 0x00UL) != 0xDEADC0DEUL) {
        mci_puts("[MCU] ERROR: SOC_SRAM mismatch\n");
        return 3;
    }
    mci_puts("[MCU] MCU_SRAM, MCU_MBOX0, and SOC_SRAM verified over AXI4 crossbar\n");

    // Step 2b: Verify & initialize MIPI I3C / OCP Recovery Target (0x2000_4000)
    uint32_t i3c_ver  = mmio_read32(I3C_REG_HCI_VERSION);
    uint32_t i3c_cap0 = mmio_read32(I3C_REG_REC_PROT_CAP_0);
    uint32_t i3c_cap1 = mmio_read32(I3C_REG_REC_PROT_CAP_1);
    mmio_write32(I3C_REG_STBY_CR_CONTROL,          0x80000000UL); // STBY_CR_ENABLE_INIT = 2
    mmio_write32(I3C_REG_STBY_CR_DEVICE_ADDR,      0x805A805AUL); // Main target addr = 0x5A
    mmio_write32(I3C_REG_STBY_CR_VIRT_DEVICE_ADDR, 0x805B805BUL); // Recovery target addr = 0x5B
    mmio_write32(I3C_REG_REC_DEVICE_STATUS_0,      0x00000003UL); // DEV_STATUS = 0x3 (Recovery Ready)
    mmio_write32(I3C_REG_REC_RECOVERY_STATUS,      0x00000001UL); // DEV_REC_STATUS = 0x1 (Awaiting Image)
    mmio_write32(I3C_REG_HC_CONTROL,               0x80000000UL); // BUS_ENABLE = 1
    mci_puts("[MCU] I3C_VER=");
    mci_puthex32(i3c_ver);
    mci_puts(" PROT_CAP=");
    mci_puthex32(i3c_cap0);
    mci_putc('/');
    mci_puthex32(i3c_cap1);
    mci_puts(" ADDR=0x5a/0x5b BUS_EN=1\n");
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000003UL);

    // Step 3: Release Caliptra Core from reset by writing 1 to MCI CPTRA_BOOT_GO
    mci_puts("[MCU] Asserting MCI CPTRA_BOOT_GO (0x21000108) = 1\n");
    mmio_write32(MCI_REG_CPTRA_BOOT_GO, 1UL);
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000004UL);

    // Step 4: Poll Caliptra Core CPTRA_FLOW_STATUS (0xA003_003C) for READY_FOR_FUSES
    mci_puts("[MCU] Waiting for Caliptra Core READY_FOR_FUSES...\n");
    while ((mmio_read32(CPTRA_FLOW_STATUS) & CPTRA_FLOW_READY_FOR_FUSES) == 0UL) {
        // Spin while Caliptra Boot FSM initializes
    }
    mci_puts("[MCU] Caliptra Core READY_FOR_FUSES=1! Programming WDT, FUSE_WR_DONE & BOOTFSM_GO\n");
    mmio_write32(CPTRA_WDT_CFG_0,    0x0FFFFFFFUL);
    mmio_write32(CPTRA_WDT_CFG_1,    0x00000000UL);
    mmio_write32(CPTRA_FUSE_WR_DONE, 1UL);
    mmio_write32(CPTRA_BOOTFSM_GO,   1UL);
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0x00000005UL);

    // Step 5: Monitor Caliptra Core ROM boot & service ETRNG requests over AXI crossbar
    uint32_t last_boot_status = 0xFFFFFFFFUL;
    uint32_t etrng_counter = 1UL;
    while (1) {
        while (1) {
            uint32_t trng_st = mmio_read32(CPTRA_TRNG_STATUS);
            if ((trng_st & (CPTRA_TRNG_STATUS_DATA_REQ | CPTRA_TRNG_STATUS_DATA_WR_DONE)) ==
                CPTRA_TRNG_STATUS_DATA_REQ) {
                for (uint32_t i = 0; i < 12UL; i++) {
                    uint32_t val = (0x9E3779B9UL * (etrng_counter * 13UL + i + 1UL)) ^ (0x6A09E667UL + i);
                    mmio_write32(CPTRA_TRNG_DATA_0 + (i * 4UL), val);
                }
                mmio_write32(CPTRA_TRNG_STATUS, CPTRA_TRNG_STATUS_DATA_WR_DONE);
                etrng_counter++;
            } else {
                break;
            }
        }

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
            mci_puthex32(etrng_counter - 1UL);
            mci_putc('\n');
        }
        if ((flow & CPTRA_FLOW_READY_FOR_MB_PROCESSING) != 0UL) {
            mci_puts("[MCU] Total ETRNG requests serviced: ");
            mci_puthex32(etrng_counter - 1UL);
            mci_putc('\n');
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

    mci_puts("[MCU] Caliptra-SS Full Boot Complete (READY_FOR_MB_PROCESSING=1)!\n");
    mmio_write32(MCI_REG_GENERIC_OUTPUT_WIRES_0, 0xCA1100AAUL);
    return 0xFF;
}
