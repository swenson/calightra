/*++
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache-2.0 license.

File Name:

    start.s

Abstract:

    Startup code for Calightra-SS bare-metal RISC-V MCU ROM

--*/

.option norvc

.section .text.init
.global _start
_start:

.option push
.option norelax
    la gp, GLOBAL_POINTER
.option pop

    # Initialize the stack pointer
    la sp, STACK_TOP

    # Configure mtvec with the address of the exception handler in direct mode
    la t0, _exception_handler
    csrw mtvec, t0

    # Initialize MRAC (Region Access Control Register, CSR 0x7c0)
    la     t0, CALIGHTRA_MRAC_VALUE
    lw     t1, 0(t0)
    csrw   0x7c0, t1
    fence.i

    # Zero BSS in DCCM
    la t0, BSS_START
    la t1, BSS_END
copy_bss:
    bge t0, t1, end_copy_bss
    sw x0, 0(t0)
    addi t0, t0, 4
    j copy_bss
end_copy_bss:

    # Copy initialized data from ROM to DCCM
    la t0, ROM_DATA_START
    la t1, DATA_START
    la t2, DATA_END
copy_data:
    bge t1, t2, end_copy_data
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j copy_data
end_copy_data:

    # Call main entry point
    call main

.section .text.init
.align 8

_exception_handler:
    # Save SP to mscratch
    csrw mscratch, sp

    # Switch to the exception stack
    la sp, ESTACK_START

    # Jump to common Rust exception handler
    jal exception_handler
