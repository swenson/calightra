// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache-2.0 license.

use crate::io::{print_to_console, CALIGHTRA_WRITER, EXITER, FATAL_ERROR_HANDLER};

#[cfg(target_arch = "riscv32")]
core::arch::global_asm!(include_str!("start.s"));

use caliptra_mcu_config::{McuMemoryMap, McuStraps};
use caliptra_mcu_rom_common::{RomHooks, RomParameters};

struct LoggingRomHooks;

/// Offset of `mci_reg_fw_extended_error_info[0]` within MCI register block.
const HOOK_BITMASK_OFFSET: usize = 0x70;
/// Offset of `mci_reg_generic_output_wires[0]` within MCI register block.
const GENERIC_OUT_0_OFFSET: usize = 0x408;

fn record_hook_bit(bit: u32) {
    let addr = (MCU_MEMORY_MAP.mci_offset as usize + HOOK_BITMASK_OFFSET) as *mut u32;
    let wire0 = (MCU_MEMORY_MAP.mci_offset as usize + GENERIC_OUT_0_OFFSET) as *mut u32;
    unsafe {
        let cur = core::ptr::read_volatile(addr) | (1u32 << bit);
        core::ptr::write_volatile(addr, cur);
        core::ptr::write_volatile(wire0, cur);
    }
}

fn read_owner_pk_hash_policy() -> caliptra_mcu_rom_common::OwnerPkHashPolicy {
    use tock_registers::interfaces::Readable;
    let mci: caliptra_mcu_romtime::StaticRef<caliptra_mcu_registers_generated::mci::regs::Mci> = unsafe {
        caliptra_mcu_romtime::StaticRef::new(
            MCU_MEMORY_MAP.mci_offset as *const caliptra_mcu_registers_generated::mci::regs::Mci,
        )
    };
    if mci.mci_reg_generic_input_wires[1].get()
        & caliptra_mcu_rom_common::FORCE_FUSE_OWNER_PK_HASH_WIRE_BIT
        != 0
    {
        caliptra_mcu_rom_common::OwnerPkHashPolicy::ForceFuse
    } else {
        caliptra_mcu_rom_common::OwnerPkHashPolicy::DotThenFuse
    }
}

impl RomHooks for LoggingRomHooks {
    fn pre_cold_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_cold_boot");
        record_hook_bit(0);
    }
    fn post_cold_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_cold_boot");
        record_hook_bit(1);
    }
    fn pre_warm_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_warm_boot");
        record_hook_bit(2);
    }
    fn post_warm_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_warm_boot");
        record_hook_bit(3);
    }
    fn pre_fw_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_fw_boot");
        record_hook_bit(4);
    }
    fn post_fw_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_fw_boot");
        record_hook_bit(5);
    }
    fn pre_fw_hitless_update(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_fw_hitless_update");
        record_hook_bit(6);
    }
    fn post_fw_hitless_update(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_fw_hitless_update");
        record_hook_bit(7);
    }
    fn pre_caliptra_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_caliptra_boot");
        record_hook_bit(8);
    }
    fn post_caliptra_boot(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_caliptra_boot");
        record_hook_bit(9);
    }
    fn pre_populate_fuses_to_caliptra(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_populate_fuses_to_caliptra");
        record_hook_bit(10);
    }
    fn post_populate_fuses_to_caliptra(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_populate_fuses_to_caliptra");
        record_hook_bit(11);
    }
    fn pre_load_firmware(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_load_firmware");
        record_hook_bit(12);
    }
    fn post_load_firmware(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_load_firmware");
        record_hook_bit(13);
    }
    fn pre_set_ocp_lock_fuses(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_set_ocp_lock_fuses");
        record_hook_bit(14);
    }
    fn post_set_ocp_lock_fuses(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_set_ocp_lock_fuses");
        record_hook_bit(15);
    }
    fn pre_stable_owner_key_derivation(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_stable_owner_key_derivation");
        record_hook_bit(16);
    }
    fn post_stable_owner_key_derivation(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_stable_owner_key_derivation");
        record_hook_bit(17);
    }
    fn pre_encrypted_firmware_decrypt(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] pre_encrypted_firmware_decrypt");
        record_hook_bit(18);
    }
    fn post_encrypted_firmware_decrypt(&self) {
        caliptra_mcu_romtime::println!("[mcu-rom-hook] post_encrypted_firmware_decrypt");
        record_hook_bit(19);
    }
}

// Re-export these so the common ROM and runtime can use them
#[no_mangle]
#[used]
pub static MCU_MEMORY_MAP: McuMemoryMap = caliptra_mcu_config_calightra::CALIGHTRA_MEMORY_MAP;

#[no_mangle]
#[used]
pub static MCU_STRAPS: McuStraps = caliptra_mcu_config_calightra::CALIGHTRA_MCU_STRAPS;

pub extern "C" fn rom_entry() -> ! {
    print_to_console("\nCalightra MCU ROM (caliptra-mcu-sw main-2.1)\n");
    unsafe {
        #[allow(static_mut_refs)]
        caliptra_mcu_romtime::set_printer(&mut CALIGHTRA_WRITER);
    }
    unsafe {
        #[allow(static_mut_refs)]
        caliptra_mcu_rom_common::set_fatal_error_handler(&mut FATAL_ERROR_HANDLER);
    }
    unsafe {
        #[allow(static_mut_refs)]
        caliptra_mcu_romtime::set_exiter(&mut EXITER);
    }

    caliptra_mcu_romtime::println!("[mcu-rom] Starting Calightra MCU ROM");

    // In Calightra-SS, MCU LSU strap and SoC BFM use AXI user 0x0000_0001.
    let axi_user0 = 1u32;
    let cptra_mbox_users = [axi_user0, 0, 0, 0, 0];
    let mci_mbox0_users = [axi_user0, 0, 0, 0, 0];
    // MBOX1 is not instantiated (MCU_MBOX1_SIZE_KB = 0), so leave mci_mbox1_axi_users unconfigured.
    let mci_mbox1_users = [0u32; 5];

    let hooks = LoggingRomHooks;

    caliptra_mcu_rom_common::rom_start(RomParameters {
        owner_pk_hash_policy: read_owner_pk_hash_policy(),
        otp_enable_integrity_check: false,
        otp_enable_consistency_check: false,
        itrng_entropy_bypass_mode: true,
        cptra_mbox_axi_users: cptra_mbox_users,
        cptra_fuse_axi_user: axi_user0,
        cptra_trng_axi_user: axi_user0,
        mci_mbox0_axi_users: mci_mbox0_users,
        mci_mbox1_axi_users: mci_mbox1_users,
        hooks: Some(&hooks),
        mcu_fw_sram_exec_region_size: Some(
            (MCU_MEMORY_MAP.sram_size - MCU_MEMORY_MAP.storage_size) / 4096
                - caliptra_mcu_rom_common::MCU_SRAM_DEFAULT_PROTECTED_REGION_BLOCKS
                - 1,
        ),
        ..Default::default()
    });

    let addr = MCU_MEMORY_MAP.sram_offset;
    caliptra_mcu_romtime::println!("[mcu-rom] Jumping to firmware at {:08x}", addr);
    exit_rom(addr);
}

fn exit_rom(addr: u32) -> ! {
    unsafe {
        core::arch::asm! {
            "// Clear the stack
            la a0, STACK_ORIGIN      // dest
            la a1, STACK_SIZE        // len
            add a1, a1, a0
        1:
            sw zero, 0(a0)
            addi a0, a0, 4
            bltu a0, a1, 1b

            // Clear all registers
            li x1,  0; li x2,  0; li x3,  0; li x4,  0;
            li x5,  0; li x6,  0; li x7,  0; li x8,  0;
            li x9,  0; li x10, 0; li x11, 0; li x12, 0;
            li x14, 0; li x15, 0; li x16, 0;
            li x17, 0; li x18, 0; li x19, 0; li x20, 0;
            li x21, 0; li x22, 0; li x23, 0; li x24, 0;
            li x25, 0; li x26, 0; li x27, 0; li x28, 0;
            li x29, 0; li x30, 0; li x31, 0;

            // jump to runtime
            jr a3",
            in("a3") addr,
            options(noreturn),
        }
    }
}
