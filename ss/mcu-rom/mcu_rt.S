/* SPDX-License-Identifier: Apache-2.0 */
/* Minimal Calightra MCU Runtime Firmware loaded to 0x21c0_0000 via I3C Recovery */

.section .text
.global _start
_start:
    /* Set MCI_REG_GENERIC_OUTPUT_WIRES_0 (0x21000408) = 0xCA1100FF */
    li   t0, 0x21000408
    li   t1, 0xCA1100FF
    sw   t1, 0(t0)

    /* Print banner to MCI_REG_DEBUG_OUT (0x21000414) */
    li   t0, 0x21000414
    la   t1, msg_banner
1:
    lbu  t2, 0(t1)
    beqz t2, 2f
    sb   t2, 0(t0)
    addi t1, t1, 1
    j    1b
2:
    /* Signal TEST PASS (0xFF) via MCI_REG_DEBUG_OUT */
    li   t2, 0xFF
    sb   t2, 0(t0)

3:
    wfi
    j    3b

.section .rodata
.balign 4
msg_banner:
    .asciz "\n[mcu-rt] Hello from Calightra MCU Runtime Firmware at 0x21c00000!\n[mcu-rt] Full I3C Recovery Flow (Caliptra FMC/RT + SoC Manifest + MCU RT) COMPLETE!\n"
