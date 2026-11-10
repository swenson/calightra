// SPDX-License-Identifier: Apache-2.0
// Licensed under the Apache-2.0 license.

#![cfg_attr(target_arch = "riscv32", no_std)]
#![no_main]

#[cfg(target_arch = "riscv32")]
mod io;
#[cfg(target_arch = "riscv32")]
mod riscv;

#[cfg(target_arch = "riscv32")]
#[no_mangle]
pub extern "C" fn main() {
    riscv::rom_entry();
}

#[cfg(not(target_arch = "riscv32"))]
#[no_mangle]
pub extern "C" fn main() {
    println!("nop");
}
