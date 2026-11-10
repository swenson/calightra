// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache-2.0 license.

use core::fmt::Write;

use caliptra_mcu_rom_common::{FatalErrorHandler, RomEnv};
use caliptra_mcu_romtime::{Exit, HexWord};

pub(crate) struct CalightraWriter {}
pub(crate) static mut CALIGHTRA_WRITER: CalightraWriter = CalightraWriter {};

/// MCI_REG_DEBUG_OUT (0x2100_0414) monitored by the Verilator / FPGA harness.
const MCI_DEBUG_OUT: *mut u32 = 0x2100_0414 as *mut u32;
/// MCI_REG_GENERIC_OUTPUT_WIRES_1 (0x2100_040C) used to report fatal error codes.
const MCI_GENERIC_OUT_1: *mut u32 = 0x2100_040c as *mut u32;

impl Write for CalightraWriter {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        print_to_console(s);
        Ok(())
    }
}

pub(crate) fn print_to_console(buf: &str) {
    for b in buf.bytes() {
        unsafe {
            core::ptr::write_volatile(MCI_DEBUG_OUT, b as u32);
        }
    }
}

pub(crate) struct CalightraFatalErrorHandler {}
pub(crate) static mut FATAL_ERROR_HANDLER: CalightraFatalErrorHandler =
    CalightraFatalErrorHandler {};

impl FatalErrorHandler for CalightraFatalErrorHandler {
    fn fatal_error(&mut self, code: u32) -> ! {
        let _ = writeln!(CalightraWriter {}, "MCU fatal error: {}", HexWord(code));
        unsafe {
            core::ptr::write_volatile(MCI_GENERIC_OUT_1, code);
        }
        RomEnv::new().mci.set_fw_fatal_error(code);
        exit_calightra(code);
    }
}

pub fn exit_calightra(exit_code: u32) -> ! {
    unsafe {
        let b: u32 = if exit_code == 0 { 0xff } else { 0x01 };
        core::ptr::write_volatile(MCI_DEBUG_OUT, b);
    }
    loop {
        core::hint::spin_loop();
    }
}

pub struct Exiter {}

impl Exit for Exiter {
    fn exit(&mut self, code: u32) {
        exit_calightra(code);
    }
}

pub(crate) static mut EXITER: Exiter = Exiter {};
