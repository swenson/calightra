# SPDX-License-Identifier: Apache-2.0

import logging
import random

from bus2csr import dword2int, int2dword
from interface import I3CTopTestInterface

import cocotb
from cocotb.triggers import Timer
from common import timeout_task, log_seed

TRANSACTION_COUNT = 1024


async def initialize(dut, fclk=333.0, timeout=50):
    """
    Common test initialization routine
    """

    cocotb.log.setLevel(logging.DEBUG)
    log_seed(dut)

    # Start the background timeout task
    await cocotb.start(timeout_task(timeout))

    tb = I3CTopTestInterface(dut)
    await tb.setup(fclk)
    return tb


async def test_read(tb, reg):
    # try reading empty fifo multiple times
    for _ in range(TRANSACTION_COUNT):
        data = dword2int(
            await tb.read_csr(reg, 4)
        )
        # we should not stall and the data should be read as zero
        assert data == 0, f"Expected zero from empty FIFO read, got 0x{data:08X}"


@cocotb.test()
async def test_empty_rx_desc_read(dut):
    tb = await initialize(dut)
    await test_read(tb, tb.reg_map.I3C_EC.TTI.RX_DESC_QUEUE_PORT.base_addr)

    await tb.teardown()


@cocotb.test()
async def test_empty_rx_data_read(dut):
    tb = await initialize(dut)
    await test_read(tb, tb.reg_map.I3C_EC.TTI.RX_DATA_PORT.base_addr)

    await tb.teardown()


@cocotb.test()
async def test_empty_indirect_fifo_read(dut):
    tb = await initialize(dut)
    await test_read(tb, tb.reg_map.I3C_EC.SECFWRECOVERYIF.INDIRECT_FIFO_DATA.base_addr)

    await tb.teardown()

@cocotb.test()
async def test_full_tx_desc_write(dut):
    tb = await initialize(dut)
    for _ in range(TRANSACTION_COUNT):
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DESC_QUEUE_PORT.base_addr, int2dword(random.randint(0, 0xffffffff)), 4)
    # Bus must not stall — verify it's still responsive
    data = dword2int(await tb.read_csr(tb.reg_map.I3CBASE.HCI_VERSION.base_addr, 4))
    assert data == 0x120, f"Bus stalled: HCI_VERSION read returned 0x{data:X} after {TRANSACTION_COUNT} TX_DESC writes"

    await tb.teardown()

@cocotb.test()
async def test_full_tx_data_write(dut):
    tb = await initialize(dut)
    for _ in range(TRANSACTION_COUNT):
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DATA_PORT.base_addr, int2dword(random.randint(0, 0xffffffff)), 4)
    # Bus must not stall — verify it's still responsive
    data = dword2int(await tb.read_csr(tb.reg_map.I3CBASE.HCI_VERSION.base_addr, 4))
    assert data == 0x120, f"Bus stalled: HCI_VERSION read returned 0x{data:X} after {TRANSACTION_COUNT} TX_DATA writes"

    await tb.teardown()

@cocotb.test()
async def test_full_ibi_write(dut):
    tb = await initialize(dut)
    for _ in range(TRANSACTION_COUNT):
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.IBI_PORT.base_addr, int2dword(random.randint(0, 0xffffffff)), 4)
    # Bus must not stall — verify it's still responsive
    data = dword2int(await tb.read_csr(tb.reg_map.I3CBASE.HCI_VERSION.base_addr, 4))
    assert data == 0x120, f"Bus stalled: HCI_VERSION read returned 0x{data:X} after {TRANSACTION_COUNT} IBI writes"

    await tb.teardown()
