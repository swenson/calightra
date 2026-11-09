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

.set mrac,    0x7c0
.set mcause,  0x342
.set mscause, 0x7ff
.set mepc,    0x341
.set mtval,   0x343

.section .text.init, "ax"
.align 4
.global _start
_start:
    la   x1, _trap
    csrw mtvec, x1

    // Configure MRAC (Region Access Control CSR):
    // Region 0x5 (0x5000_0000 DCCM):    no side-effects, uncacheable (0b00)
    // Region 0x8 (0x8000_0000 MCU ROM): no side-effects, uncacheable (0b00)
    // Regions 0x2 (MCI/I3C), 0x6 (PIC), 0x7 (OTP/LC), 0xA (Caliptra), 0xB (SRAM):
    //                                   side-effects, uncacheable (0b10)
    li   t0, 0xAAA8A2AA
    csrw mrac, t0
    fence.i

    la   sp, _stack_top
    call main

.global _finish
_finish:
    // Write 0xFF (pass) or non-zero exit code to MCI DEBUG_OUT (0x21000414)
    li   t0, 0x21000414
    sb   a0, 0(t0)
1:
    wfi
    j    1b

.align 4
_trap:
    // Record trap mcause in MCI GENERIC_OUTPUT_WIRES_1 (0x2100040C)
    li   t0, 0x2100040C
    csrr t1, mcause
    sw   t1, 0(t0)
    // Write '!' and 0x01 (fail) to MCI DEBUG_OUT (0x21000414)
    li   t0, 0x21000414
    li   a0, 0x21
    sb   a0, 0(t0)
    li   a0, 0x01
    sb   a0, 0(t0)
2:
    j    2b
