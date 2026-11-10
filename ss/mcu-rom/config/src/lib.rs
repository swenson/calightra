// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache-2.0 license

#![cfg_attr(target_arch = "riscv32", no_std)]

use caliptra_mcu_config::{McuMemoryMap, McuStraps, MemoryRegionType};

/// Calightra-SS memory map matching `caliptra-ss/src/integration/rtl/soc_address_map_defines.svh`
/// and `ss/rtl/calightra_ss_axi_xbar.sv`.
pub const CALIGHTRA_MEMORY_MAP: McuMemoryMap = McuMemoryMap {
    rom_offset: 0x8000_0000,
    rom_size: 64 * 1024,
    rom_stack_size: 0x2d00,
    rom_estack_size: 0x200,
    rom_properties: MemoryRegionType::MEMORY,

    dccm_offset: 0x5000_0000,
    dccm_size: 16 * 1024,
    dccm_properties: MemoryRegionType::MEMORY,

    sram_offset: 0x21c0_0000,
    sram_size: 512 * 1024,
    sram_properties: MemoryRegionType::MEMORY,

    storage_size: 0x400,

    pic_offset: 0x6000_0000,
    pic_properties: MemoryRegionType::MMIO,

    i3c_offset: 0x2000_4000,
    i3c_size: 0x1000,
    i3c_properties: MemoryRegionType::MMIO,

    i3c1_offset: 0x2000_5000,
    i3c1_size: 0x1000,
    i3c1_properties: MemoryRegionType::MMIO,

    mci_offset: 0x2100_0000,
    mci_size: 0xa0_0028,
    mci_properties: MemoryRegionType::MMIO,

    mbox_offset: 0x3002_0000,
    mbox_size: 0x28,
    mbox_properties: MemoryRegionType::MMIO,

    soc_offset: 0x3003_0000,
    soc_size: 0x5e0,
    soc_properties: MemoryRegionType::MMIO,

    otp_offset: 0x7000_0000,
    otp_size: 0x140,
    otp_properties: MemoryRegionType::MMIO,

    lc_offset: 0x7000_0400,
    lc_size: 0x8c,
    lc_properties: MemoryRegionType::MMIO,

    handoff_offset: 0x5000_3C00,
    handoff_size: 1024,

    staging_sram_offset: 0xb000_0000,
    staging_sram_size: 256 * 1024,
};

pub const CALIGHTRA_MCU_STRAPS: McuStraps = McuStraps {
    i3c_static_addr: 0x3a,
    i3c1_static_addr: 0x3c,
    active_i3c: 0,
    cptra_wdt_cfg0: 200_000_000,
    cptra_wdt_cfg1: 200_000_000,
    mcu_wdt_cfg0: 800_000_000,
    mcu_wdt_cfg1: 1,
    mcu_wdt_cfg0_manufacturing: 800_000_000,
    mcu_wdt_cfg1_manufacturing: 1,
    mcu_wdt_cfg0_debug: 800_000_000,
    mcu_wdt_cfg1_debug: 1,
};

/// The MRAC value which should be populated for this memory map. This corresponds to a value
/// utilized within the global start assembly and thus must be unmangled.
#[no_mangle]
pub static CALIGHTRA_MRAC_VALUE: u32 = CALIGHTRA_MEMORY_MAP.compute_mrac();
