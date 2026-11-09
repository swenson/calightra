# SPDX-License-Identifier: Apache-2.0

"""
Prosecutor Test: tSCO Violation on Write-ACK Handoff

This test was originally a prosecutor test that proved the DUT violated
the tSCO timing spec on the virtual target ACK path. The RTL has since
been fixed. The test is retained as a regression guard.

Spec requirement (S5.1.2.3.1 step 2, Table 87):
  "After the I3C Target sees the rising edge of SCL, it releases the SDA
   line to High-Z."
  tSCO (Clock in to Data Out for Target) max = 12ns
"""

import logging

from boot import boot_init
from bus2csr import dword2int, int2dword
from ccc import CCC
from i3c_controller_fixed import I3cControllerFixed as I3cController
from cocotbext_i3c.i3c_target import I3CTarget
from interface import I3CTopTestInterface

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from common import timeout_task, log_seed

TARGET_STATIC_ADDR = 0x5A
TARGET_DYNAMIC_ADDR = 0x52

# tSCO max from I3C spec Table 87 (Push-Pull timing)
TSCO_MAX_NS = 12


async def test_setup(dut, timeout_us=50):
    """Sets up controller, target models and top-level core interface."""

    cocotb.log.setLevel(logging.DEBUG)
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

    i3c_target = I3CTarget(
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_target_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_target_i,
        debug_state_o=None,
        speed=12.5e6,
    )

    tb = I3CTopTestInterface(dut)
    await tb.setup()

    await boot_init(tb)

    # Disable bus monitor -- we are testing its assertion directly
    if tb.bus_monitor:
        tb.bus_monitor.stop()
        tb.bus_monitor = None

    return i3c_controller, i3c_target, tb


async def measure_tsco_on_next_ack(dut, tb, max_wait_cycles=5000):
    """
    Monitors bus_scl and sda_oe to measure tSCO on the next ACK event.

    Returns (tsco_ns, ack_time, release_time) or raises AssertionError.
    """
    bus_scl = dut.bus_scl
    sda_oe = dut.xi3c_wrapper.sda_oe
    sda_o = dut.xi3c_wrapper.sda_o

    ack_scl_rise_time = None
    sda_oe_release_time = None

    # Phase 1: Wait for ACK condition (SCL rise with DUT driving SDA low)
    prev_scl = 0
    for _ in range(max_wait_cycles):
        await RisingEdge(tb.clk)
        try:
            scl = int(bus_scl.value)
            oe = int(sda_oe.value)
            so = int(sda_o.value)
        except ValueError:
            prev_scl = 0
            continue

        if scl == 1 and prev_scl == 0:
            if oe == 1 and so == 0:
                ack_scl_rise_time = cocotb.utils.get_sim_time('ns')
                dut._log.info(
                    f"ACK detected: SCL rose at {ack_scl_rise_time:.3f}ns "
                    f"with sda_oe=1, sda_o=0"
                )
                break
        prev_scl = scl

    assert ack_scl_rise_time is not None, \
        "Never detected ACK condition (SCL rise with DUT driving SDA low)"

    # Phase 2: Measure how long until sda_oe goes to 0
    for _ in range(max_wait_cycles):
        await RisingEdge(tb.clk)
        try:
            oe = int(sda_oe.value)
        except ValueError:
            continue

        if oe == 0:
            sda_oe_release_time = cocotb.utils.get_sim_time('ns')
            break

    assert sda_oe_release_time is not None, \
        "sda_oe never went to 0 after ACK"

    tsco_actual = sda_oe_release_time - ack_scl_rise_time
    return tsco_actual, ack_scl_rise_time, sda_oe_release_time


@cocotb.test()
async def test_tsco_write_ack_handoff(dut):
    """
    PROSECUTOR TEST: Verifies tSCO timing on write-ACK handoff.

    Per I3C spec S5.1.2.3.1 step 2 and Table 87:
      After the Target sees the rising edge of SCL during ACK, it shall
      release SDA to Hi-Z within tSCO (max 12ns).

    This test sends a private write to the target, then measures the time
    between the ACK SCL rising edge and the sda_oe deassertion.
    """

    i3c_controller, i3c_target, tb = await test_setup(dut)

    # Send SETDASA to assign dynamic address
    await i3c_controller.i3c_ccc_write(
        ccc=CCC.DIRECT.SETDASA,
        directed_data=[(TARGET_STATIC_ADDR, [TARGET_DYNAMIC_ADDR << 1])]
    )
    await ClockCycles(tb.clk, 50)

    # Start a private write in background
    tx_data = [0xDE, 0xAD, 0xBE, 0xEF]
    cocotb.start_soon(i3c_controller.i3c_write(TARGET_DYNAMIC_ADDR, tx_data))

    # Measure tSCO on the address ACK
    tsco, t_rise, t_release = await measure_tsco_on_next_ack(dut, tb)

    dut._log.info(f"tSCO measurement (private write ACK):")
    dut._log.info(f"  ACK SCL rise:   {t_rise:.3f}ns")
    dut._log.info(f"  sda_oe release: {t_release:.3f}ns")
    dut._log.info(f"  tSCO actual:    {tsco:.3f}ns")
    dut._log.info(f"  tSCO max:       {TSCO_MAX_NS}ns (Table 87)")

    assert tsco <= TSCO_MAX_NS, (
        f"tSCO VIOLATION: DUT took {tsco:.3f}ns to release SDA after "
        f"ACK SCL rise (max {TSCO_MAX_NS}ns per I3C spec Table 87, S5.1.2.3.1). "
        f"The Target shall release SDA to Hi-Z within tSCO of the SCL rising edge."
    )

    dut._log.info("PASS: tSCO within spec limit")
    await ClockCycles(tb.clk, 500)
    await tb.teardown()


@cocotb.test()
async def test_tsco_setdasa_virtual_target(dut):
    """
    PROSECUTOR TEST: Verifies tSCO timing on SETDASA to virtual target.

    The bus monitor has detected a tSCO violation specifically during
    SETDASA directed to the virtual target address (0x5B). This test
    measures tSCO during that specific transaction.

    This test was originally written as a prosecutor test when the virtual
    target ACK path had a 46ns tSCO delay. The RTL has since been fixed
    and this test now passes as a regression guard.
    """

    i3c_controller, i3c_target, tb = await test_setup(dut)

    # Measure tSCO during SETDASA to the virtual target
    # The SETDASA CCC directed phase sends: Sr + static_addr/W + DA_byte
    # The ACK on static_addr/W is where we measure tSCO.

    VIRT_STATIC_ADDR = 0x5B
    VIRT_DYNAMIC_ADDR = 0x53

    # Start SETDASA in background
    async def setdasa_task():
        await i3c_controller.i3c_ccc_write(
            ccc=CCC.DIRECT.SETDASA,
            directed_data=[(VIRT_STATIC_ADDR, [VIRT_DYNAMIC_ADDR << 1])]
        )

    cocotb.start_soon(setdasa_task())

    # Measure tSCO on the ACK (there will be multiple ACKs in SETDASA:
    # one for broadcast 7E, one for the directed static addr).
    # We measure ALL ACKs and report the worst case.
    worst_tsco = 0
    worst_info = ""
    ack_count = 0

    bus_scl = dut.bus_scl
    sda_oe = dut.xi3c_wrapper.sda_oe
    sda_o = dut.xi3c_wrapper.sda_o
    prev_scl = 0
    max_wait_cycles = 10000
    measuring = False
    ack_scl_rise_time = None

    for _ in range(max_wait_cycles):
        await RisingEdge(tb.clk)
        try:
            scl = int(bus_scl.value)
            oe = int(sda_oe.value)
            so = int(sda_o.value)
        except ValueError:
            prev_scl = 0
            continue

        if not measuring:
            # Look for ACK: SCL rise with DUT driving SDA low
            if scl == 1 and prev_scl == 0 and oe == 1 and so == 0:
                ack_scl_rise_time = cocotb.utils.get_sim_time('ns')
                measuring = True
                ack_count += 1
        else:
            # Wait for sda_oe to go to 0
            if oe == 0:
                release_time = cocotb.utils.get_sim_time('ns')
                tsco = release_time - ack_scl_rise_time
                info = (
                    f"ACK #{ack_count}: SCL rise={ack_scl_rise_time:.3f}ns, "
                    f"release={release_time:.3f}ns, tSCO={tsco:.3f}ns"
                )
                dut._log.info(info)
                if tsco > worst_tsco:
                    worst_tsco = tsco
                    worst_info = info
                measuring = False

        prev_scl = scl

        # Stop after SETDASA completes (bus goes idle)
        if ack_count >= 2 and not measuring:
            break

    dut._log.info(f"Total ACKs measured: {ack_count}")
    dut._log.info(f"Worst tSCO: {worst_tsco:.3f}ns")
    dut._log.info(f"  Detail: {worst_info}")
    dut._log.info(f"  tSCO max: {TSCO_MAX_NS}ns (Table 87)")

    assert worst_tsco <= TSCO_MAX_NS, (
        f"tSCO VIOLATION: Worst-case tSCO during SETDASA to virtual target "
        f"was {worst_tsco:.3f}ns (max {TSCO_MAX_NS}ns per I3C spec Table 87, "
        f"S5.1.2.3.1 step 2). "
        f"Detail: {worst_info}"
    )

    dut._log.info("PASS: All tSCO measurements within spec limit")
    await ClockCycles(tb.clk, 50)
    await tb.teardown()
