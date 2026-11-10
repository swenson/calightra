/* SPDX-License-Identifier: Apache-2.0 */
/* Licensed under the Apache-2.0 license. */

ENTRY(_start)

ROM_START    = 0x80000000;
ROM_LENGTH   = 0x00010000;
RAM_START    = 0x50000000;
RAM_LENGTH   = 0x00003C00;
STACK_SIZE   = 0x00002D00;
ESTACK_SIZE  = 0x00000200;
HANDOFF_ADDR = 0x50003C00;
HANDOFF_SIZE = 0x00000400;

/*
 * The last 48 bytes of the ROM image are reserved for a SHA-384 digest that is
 * appended by the build step (see `append_digest.py`). Carve them out of the
 * ROM region so the linker refuses to place code or rodata there.
 */
ROM_DIGEST_SIZE = 48;

MEMORY
{
  ROM     (rx)  : ORIGIN = ROM_START,    LENGTH = ROM_LENGTH - ROM_DIGEST_SIZE
  RAM     (rwx) : ORIGIN = RAM_START,    LENGTH = RAM_LENGTH
  HANDOFF (rw)  : ORIGIN = HANDOFF_ADDR, LENGTH = HANDOFF_SIZE
}

SECTIONS
{
    .text :
    {
        *(.text.init )
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > ROM

    ROM_DATA = .;

    .stack (NOLOAD):
    {
        . = ALIGN(4);
        . = . + STACK_SIZE;
        . = ALIGN(4);
    } > RAM

    .estack (NOLOAD):
    {
        . = ALIGN(4);
        . = . + ESTACK_SIZE;
        . = ALIGN(4);
        PROVIDE(ESTACK_START = . );
    } > RAM

    /DISCARD/ :
    {
        *(.eh_frame*)
    }

    .data : AT(ROM_DATA)
    {
        . = ALIGN(4);
        *(.data*);
        *(.sdata*);
        . = ALIGN(4);
        PROVIDE( GLOBAL_POINTER = . + 0x800 );
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
    } > RAM

    /* Reserve 1 KB at the end of DCCM for the handoff table. */
    .handoff (NOLOAD) :
    {
        KEEP(*(.handoff))
    } > HANDOFF

    _end = . ;
}

BSS_START = ADDR(.bss);
BSS_END = BSS_START + SIZEOF(.bss);
DATA_START = ADDR(.data);
DATA_END = DATA_START + SIZEOF(.data);
ROM_DATA_START = LOADADDR(.data);
STACK_TOP = ORIGIN(RAM) + SIZEOF(.stack);
STACK_ORIGIN = ORIGIN(RAM);
