# SPDX-License-Identifier: Apache-2.0

import logging
import random

from boot import boot_init
from bus2csr import dword2int, int2dword
from ccc import CCC
from i3c_controller_fixed import I3cControllerFixed as I3cController
from cocotbext_i3c.i3c_target import I3CTarget
from interface import I3CTopTestInterface
from utils import format_ibi_data, get_interrupt_status

import cocotb
from cocotb.regression import TestFactory
from cocotb.triggers import ClockCycles, Event, RisingEdge, Timer
from common import timeout_task, log_seed

# =============================================================================

TARGET_ADDRESS = 0x5A


async def test_setup(dut, timeout_us=25):
    """
    Sets up controller, target models and top-level core interface
    """

    cocotb.log.setLevel(logging.INFO)
    log_seed(dut)
    cocotb.start_soon(timeout_task(timeout_us))

    i3c_controller = I3cController(
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_ctrl_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_ctrl_i,
        debug_state_o=None,
        speed=12.5e6,
    )

    i3c_target = I3CTarget(  # noqa
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_target_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_target_i,
        debug_state_o=None,
        speed=12.5e6,
    )

    tb = I3CTopTestInterface(dut)
    await tb.setup()

    # Configure the top level
    await boot_init(tb)

    return i3c_controller, i3c_target, tb


# =============================================================================


@cocotb.test()
async def test_rx_desc_stat(dut):

    # Setup
    i3c_controller, _, tb = await test_setup(dut)
    irq = dut.xi3c_wrapper.irq_o

    # Enable the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_ENABLE
    await tb.write_csr_field(csr.base_addr, csr.RX_DESC_STAT_EN, 1)

    # Ensure that irq is low
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    # Send a private write to the target
    tx_data = [random.randint(0, 255) for i in range(4)]
    async def i3c_task():
        await i3c_controller.i3c_write(TARGET_ADDRESS, tx_data)

    cocotb.start_soon(i3c_task())

    # Wait for the interrupt
    while irq.value == 0:
        await RisingEdge(tb.clk)

    # R1: Explicitly assert irq went HIGH
    assert irq.value == 1, "IRQ should be HIGH after RX descriptor ready"

    # R2: Read RX descriptor and validate content
    desc = dword2int(
        await tb.read_csr(tb.reg_map.I3C_EC.TTI.RX_DESC_QUEUE_PORT.base_addr, 4)
    )
    desc_len = desc & 0xFFFF
    err_stat = desc >> 28
    assert err_stat == 0, f"Unexpected error in RX descriptor, err_stat={err_stat}"
    assert desc_len == len(tx_data), (
        f"RX descriptor length mismatch: expected {len(tx_data)}, got {desc_len}"
    )

    # Ensure that irq is low
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    # Dummy wait
    await ClockCycles(tb.clk, 10)

    await tb.teardown()


@cocotb.test()
async def test_tx_desc_stat(dut):

    # Setup
    i3c_controller, _, tb = await test_setup(dut)
    irq = dut.xi3c_wrapper.irq_o

    # Enable the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_ENABLE
    await tb.write_csr_field(csr.base_addr, csr.TX_DESC_STAT_EN, 1)
    await tb.write_csr_field(csr.base_addr, csr.TX_DESC_COMPLETE_EN, 1)

    # Ensure that irq is low
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    ## Write data and descriptor
    #await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DATA_PORT.base_addr, int2dword(0xDEADBEEF), 4)
    #await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DESC_QUEUE_PORT.base_addr, int2dword(4), 4)

    # Send a private read to the target
    async def i3c_task(evt):
        # First read should ba NACKed. as there is no data in the FIFOs
        response = await i3c_controller.i3c_read(TARGET_ADDRESS, 4)
        assert response.nack, "Expected NACK but got ACK"
        data = await i3c_controller.i3c_read(TARGET_ADDRESS, 4)
        assert list(data.data) == [0xEF, 0xBE, 0xAD, 0xDE], f"Data mismatch"
        evt.set()

    async def bus_task(evt):
        # Wait for the interrupt
        while irq.value == 0:
            await RisingEdge(tb.clk)
        # R3: Assert TX_DESC_STAT bit specifically
        intrs = await get_interrupt_status(tb)
        assert intrs["TX_DESC_STAT"] == 1, (
            f"TX_DESC_STAT should be 1 when NACK triggers descriptor request, got {intrs['TX_DESC_STAT']}"
        )
        # Write data and descriptor
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DATA_PORT.base_addr, int2dword(0xDEADBEEF), 4)
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.TX_DESC_QUEUE_PORT.base_addr, int2dword(4), 4)
        # Clear the interrupt
        csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
        await tb.write_csr_field(csr.base_addr, csr.TX_DESC_STAT, 1)
        evt.set()

    done_i3c = Event()
    done_bus = Event()
    cocotb.start_soon(i3c_task(done_i3c))
    cocotb.start_soon(bus_task(done_bus))

    # Wait for the I3C transfer to complete
    await done_i3c.wait()

    # Wait for the bus task transfer to complete
    await done_bus.wait()

    # R4: After the read completes, TX_DESC_COMPLETE should fire
    await ClockCycles(tb.clk, 10)
    intrs = await get_interrupt_status(tb)
    assert intrs["TX_DESC_COMPLETE"] == 1, (
        f"TX_DESC_COMPLETE should be 1 after private read completes, got {intrs['TX_DESC_COMPLETE']}"
    )

    # Clear the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
    await tb.write_csr_field(csr.base_addr, csr.TX_DESC_COMPLETE, 1)

    # Ensure that irq is low
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    # Dummy wait
    await ClockCycles(tb.clk, 10)

    await tb.teardown()

@cocotb.test()
async def test_ibi_done(dut):

    # Setup
    i3c_controller, _, tb = await test_setup(dut)
    irq = dut.xi3c_wrapper.irq_o

    target = i3c_controller.add_target(TARGET_ADDRESS)
    target.set_bcr_fields(ibi_req_capable=True, ibi_payload=True)

    # Enable IBI ACK-ing
    i3c_controller.enable_ibi(True)

    # Send a broadcast CCC to initialize bus timers (need STOP to start counting)
    await i3c_controller.i3c_ccc_write(ccc=CCC.BCAST.RSTDAA)

    # Enable the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_ENABLE
    await tb.write_csr_field(csr.base_addr, csr.IBI_DONE_EN, 1)

    # Ensure interrupt status
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    intrs = await get_interrupt_status(tb)
    assert intrs["IBI_DONE"] == 0, f"IBI_DONE expected 0, got {intrs['IBI_DONE']}"

    # Send an IBI
    mdb = 0xAA
    ibi_data = format_ibi_data(mdb, [])
    for word in ibi_data:
        await tb.write_csr(tb.reg_map.I3C_EC.TTI.IBI_PORT.base_addr, int2dword(word), 4)

    # Wait for the IBI to be serviced
    response = await i3c_controller.wait_for_ibi()

    # R5: Verify IBI response data correctness
    expected_ibi = bytearray([TARGET_ADDRESS, mdb])
    assert response == expected_ibi, (
        f"IBI data mismatch: expected [{' '.join(f'0x{b:02X}' for b in expected_ibi)}], "
        f"got [{' '.join(f'0x{b:02X}' for b in response)}]"
    )

    # Ensure interrupt status
    await ClockCycles(tb.clk, 10)
    assert irq.value == 1, f"IRQ expected 1, got {int(irq.value)}"

    intrs = await get_interrupt_status(tb)
    assert intrs["IBI_DONE"] == 1, f"IBI_DONE expected 1, got {intrs['IBI_DONE']}"

    # Read LAST_IBI_STATUS, the irq should go low
    dword2int(await tb.read_csr(tb.reg_map.I3C_EC.TTI.STATUS.base_addr, 4))

    # Ensure interrupt status
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    intrs = await get_interrupt_status(tb)
    assert intrs["IBI_DONE"] == 0, f"IBI_DONE expected 0, got {intrs['IBI_DONE']}"

    # Dummy wait
    await ClockCycles(tb.clk, 10)

    await tb.teardown()


async def test_interrupt_force(dut, fields):
    """
    Tests interrupt force and clear capability
    """

    # Setup
    i3c_controller, _, tb = await test_setup(dut, timeout_us=2)
    irq = dut.xi3c_wrapper.irq_o

    f_ena, f_force, f_sts = fields

    # Ensure that irq is low
    await ClockCycles(tb.clk, 10)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    # Disable the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_ENABLE
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_ena), 0)

    # Force the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_FORCE
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_force), 1)
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_force), 0)

    # Ensure that interrupt does not get asserted
    await ClockCycles(tb.clk, 20)
    assert irq.value == 0, f"IRQ expected 0, got {int(irq.value)}"

    # Ensure that the status is 0
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
    sts = await tb.read_csr_field(csr.base_addr, getattr(csr, f_sts))
    assert sts == 0, f"Status mismatch: expected 0, got {sts}"

    # Enable the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_ENABLE
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_ena), 1)

    # Force the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_FORCE
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_force), 1)
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_force), 0)

    # Wait for the interrupt
    while irq.value == 0:
        await RisingEdge(tb.clk)

    # Ensure that the status is 1
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
    sts = await tb.read_csr_field(csr.base_addr, getattr(csr, f_sts))
    assert sts == 1, f"Status mismatch: expected 1, got {sts}"

    # Clear the interrupt
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
    await tb.write_csr_field(csr.base_addr, getattr(csr, f_sts), 1)

    # Wait for the interrupt to go low
    while irq.value == 1:
        await RisingEdge(tb.clk)

    # Ensure that the status is 0
    csr = tb.reg_map.I3C_EC.TTI.INTERRUPT_STATUS
    sts = await tb.read_csr_field(csr.base_addr, getattr(csr, f_sts))
    assert sts == 0, f"Status mismatch: expected 0, got {sts}"

    # Dummy wait
    await ClockCycles(tb.clk, 10)


tf = TestFactory(test_function=test_interrupt_force)
tf.add_option(
    "fields",
    [
        ("TX_DESC_STAT_EN", "TX_DESC_STAT_FORCE", "TX_DESC_STAT"),
        ("RX_DESC_STAT_EN", "RX_DESC_STAT_FORCE", "RX_DESC_STAT"),
        ("RX_DESC_THLD_STAT_EN", "RX_DESC_THLD_FORCE", "RX_DESC_THLD_STAT"),
        ("RX_DATA_THLD_STAT_EN", "RX_DATA_THLD_FORCE", "RX_DATA_THLD_STAT"),
        ("IBI_DONE_EN", "IBI_DONE_FORCE", "IBI_DONE"),
    ],
)
tf.generate_tests()
