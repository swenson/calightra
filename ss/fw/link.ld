/* SPDX-License-Identifier: Apache-2.0 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM  (rx)  : ORIGIN = 0x80000000, LENGTH = 16K
    DCCM (rwx) : ORIGIN = 0x50000000, LENGTH = 16K
}

SECTIONS
{
    . = ORIGIN(ROM);
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))
        *(.text*)
        . = ALIGN(4);
    } > ROM

    .rodata : ALIGN(4)
    {
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(8);
    } > ROM

    .bss (NOLOAD) : ALIGN(4)
    {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(16);
    } > DCCM

    _stack_top = ORIGIN(DCCM) + LENGTH(DCCM) - 64;
}
