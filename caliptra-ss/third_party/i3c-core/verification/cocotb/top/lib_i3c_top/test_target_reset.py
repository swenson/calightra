# SPDX-License-Identifier: Apache-2.0

import logging

from boot import boot_init
from ccc import CCC
from i3c_controller_fixed import I3cControllerFixed as I3cController
from interface import I3CTopTestInterface

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer
from common import log_seed

TGT_ADR = 0x5A

# Timing constants from I3C spec (in nanoseconds)
T_HIGH_MIN_NS = 260  # SCL Clock High Period minimum
T_R_CL_MAX_NS = 120  # SCL Signal Rise Time maximum
T_DIG_H_MIN_NS = T_HIGH_MIN_NS - T_R_CL_MAX_NS  # = 140ns minimum

# System clock frequency
SYSTEM_CLOCK_FREQ_MHZ = 333.0
SYSTEM_CLOCK_PERIOD_NS = 1000.0 / SYSTEM_CLOCK_FREQ_MHZ  # ~3ns


# =============================================================================
# TEST SETUP FUNCTIONS
# =============================================================================


async def test_setup(
    dut,
    disable_monitor: bool = False,
    system_clock_mhz: float = SYSTEM_CLOCK_FREQ_MHZ,
):
    """
    Sets up controller, target models and top-level core interface.

    Args:
        dut: Device under test
        disable_monitor: If True, disable the I3cController's background monitor.
                         Required for stress tests that directly manipulate bus signals.
        system_clock_mhz: System clock frequency in MHz (default 333MHz)
    """
    cocotb.log.setLevel(logging.DEBUG)
    log_seed(dut)

    i3c_controller = I3cController(
        sda_i=dut.bus_sda,
        sda_o=dut.sda_sim_ctrl_i,
        scl_i=dut.bus_scl,
        scl_o=dut.scl_sim_ctrl_i,
        debug_state_o=None,
        speed=12.5e6,
    )

    if disable_monitor:
        # IMPORTANT: Disable the I3cController's background monitor!
        # The monitor detects START conditions and responds by clocking SCL,
        # which interferes with our direct bus manipulation in stress tests.
        i3c_controller.monitor_enable.clear()
        # Wait for the monitor to become idle
        await i3c_controller.monitor_idle.wait()

    # We don't need target BFM in this test
    dut.sda_sim_target_i.value = 1
    dut.scl_sim_target_i.value = 1

    # Set initial signals
    dut.peripheral_reset_done_i.value = 0

    tb = I3CTopTestInterface(dut)
    await tb.setup(fclk=system_clock_mhz)
    await ClockCycles(tb.clk, 50)
    await boot_init(tb, fclk=system_clock_mhz)

    return i3c_controller, tb


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================


async def do_pattern_reset(dut, tb, i3c_controller, expect_escalation=False):
    dut._log.info(
        f"Initiating reset with Target Reset Pattern (expect escalation set to {expect_escalation})"
    )
    await i3c_controller.send_target_reset_pattern()

    # Core should initiate peripheral reset after Target Reset Pattern
    assert dut.peripheral_reset_o == (not expect_escalation), f"Reset output mismatch: expected (not expect_escalation), got {int(dut.peripheral_reset_o)}"
    assert dut.escalated_reset_o == expect_escalation, f"Reset output mismatch: expected expect_escalation, got {int(dut.escalated_reset_o)}"
    await RisingEdge(tb.clk)

    # Indicate that peripheral reset is finished
    dut.peripheral_reset_done_i.value = not expect_escalation
    await RisingEdge(tb.clk)

    # Peripheral reset should be deasserted at this point
    await ReadOnly()
    assert dut.peripheral_reset_o == 0, f"Reset output mismatch: expected 0, got {int(dut.peripheral_reset_o)}"
    assert dut.escalated_reset_o == expect_escalation, f"Reset output mismatch: expected expect_escalation, got {int(dut.escalated_reset_o)}"

    # Clear reset done
    await RisingEdge(tb.clk)
    dut.peripheral_reset_done_i.value = 0


async def wait_for_reset_detection(dut, tb, timeout_cycles: int = 1000) -> bool:
    """
    Wait for reset detection with timeout.

    Returns:
        True if reset was detected, False if timeout
    """
    for _ in range(timeout_cycles):
        await RisingEdge(tb.clk)
        await ReadOnly()
        if dut.peripheral_reset_o.value == 1 or dut.escalated_reset_o.value == 1:
            # Exit read-only phase before returning
            await RisingEdge(tb.clk)
            return True
    # Exit read-only phase before returning
    await RisingEdge(tb.clk)
    return False


async def check_no_reset_detection(dut, tb, wait_cycles: int = 200) -> bool:
    """
    Verify that no reset is detected within the wait period.

    Returns:
        True if no reset detected (expected), False if reset was detected (unexpected)
    """
    for _ in range(wait_cycles):
        await RisingEdge(tb.clk)
        await ReadOnly()
        if dut.peripheral_reset_o.value == 1 or dut.escalated_reset_o.value == 1:
            # Exit read-only phase before returning
            await RisingEdge(tb.clk)
            return False
    # Exit read-only phase before returning
    await RisingEdge(tb.clk)
    return True


async def clear_reset_state(dut, tb):
    """Clear any pending reset state"""
    # Ensure we're not in a read-only phase before writing
    await RisingEdge(tb.clk)
    dut.peripheral_reset_done_i.value = 1
    await RisingEdge(tb.clk)
    await RisingEdge(tb.clk)
    dut.peripheral_reset_done_i.value = 0
    await RisingEdge(tb.clk)


# =============================================================================
# FUNCTIONAL TESTS
# =============================================================================


@cocotb.test()
async def test_target_peripheral_reset(dut):
    i3c_controller, tb = await test_setup(dut)

    await do_pattern_reset(dut, tb, i3c_controller)

    await tb.teardown()


@cocotb.test()
async def test_target_escalated_reset(dut):
    i3c_controller, tb = await test_setup(dut)

    await do_pattern_reset(dut, tb, i3c_controller)

    # Clear escalated reset by sending GETSTATUS
    await i3c_controller.i3c_ccc_read(ccc=CCC.DIRECT.GETSTATUS, addr=TGT_ADR, count=2)

    await do_pattern_reset(dut, tb, i3c_controller)
    await ClockCycles(tb.clk, 10)

    await do_pattern_reset(dut, tb, i3c_controller, True)
    await ClockCycles(tb.clk, 10)


# =============================================================================
# STRESS TESTS
# =============================================================================

    await tb.teardown()


@cocotb.test()
async def test_reset_at_min_timing(dut):
    """
    CP1, CP11: Valid reset at exact spec minimum timing (tDIG_H = 140ns).

    This tests the target reset detector when the bus operates at the
    minimum timing specified by I3C (140ns per transition).
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info(f"Testing reset pattern at minimum timing: tDIG_H = {T_DIG_H_MIN_NS}ns")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    reset_detected = await wait_for_reset_detection(dut, tb)
    assert reset_detected, "Reset should be detected at minimum spec timing"

    await clear_reset_state(dut, tb)
    dut._log.info("PASS: Reset detected at minimum timing")

    await tb.teardown()


@cocotb.test()
async def test_13_transitions_fails(dut):
    """
    CP2: Only 13 SDA transitions should NOT trigger reset.

    The spec requires exactly 14 SDA transitions. With only 13,
    the FSM should remain in AwaitPattern state.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing 13 SDA transitions (should NOT trigger reset)")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=13,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb)
    assert no_reset, "Reset should NOT be detected with only 13 transitions"

    dut._log.info("PASS: 13 transitions correctly did not trigger reset")

    await tb.teardown()


@cocotb.test()
async def test_15_transitions_before_scl(dut):
    """
    CP2: 15 SDA transitions before SCL rise should NOT trigger reset.

    Extra transitions beyond 14 while SCL is still low should prevent
    the pattern from being recognized.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing 15 SDA transitions (should NOT trigger reset)")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=15,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    # Let's just verify the behavior
    reset_detected = await wait_for_reset_detection(dut, tb, timeout_cycles=500)

    assert not reset_detected, "Reset should NOT be detected with 15 transitions (extra transitions invalidate pattern)"
    dut._log.info("PASS: 15 transitions correctly did not trigger reset")

    await tb.teardown()


@cocotb.test()
async def test_scl_glitch_during_pattern(dut):
    """
    CP3: SCL goes high briefly during SDA transitions.

    When SCL goes stable high during the 14 SDA transitions,
    the transition counter should reset and pattern detection should fail.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing SCL glitch during SDA pattern")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_with_scl_glitch(
        glitch_at_transition=7,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb)
    assert no_reset, "Reset should NOT be detected when SCL glitches during pattern"

    dut._log.info("PASS: SCL glitch correctly prevented reset detection")

    await tb.teardown()


@cocotb.test()
async def test_sda_stable_low_during_await_scl(dut):
    """
    CP4: SDA goes stable low while waiting for SCL rise.

    In AwaitSCL state, if SDA becomes stable low, FSM should abort
    back to AwaitPattern.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing SDA stable low during AwaitSCL")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_with_sda_stable_low(
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb)
    assert no_reset, "Reset should NOT be detected when SDA stable low in AwaitSCL"

    dut._log.info("PASS: SDA stable low correctly aborted AwaitSCL")

    await tb.teardown()


@cocotb.test()
async def test_scl_drops_during_await_sr(dut):
    """
    CP7: SCL goes low before START condition detected.

    In AwaitSr state, if SCL becomes stable low before START is detected,
    FSM should abort back to AwaitPattern.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing SCL drop during AwaitSr")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_with_scl_drop_await_sr(
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb)
    assert no_reset, "Reset should NOT be detected when SCL drops in AwaitSr"

    dut._log.info("PASS: SCL drop correctly aborted AwaitSr")

    await tb.teardown()


@cocotb.test()
async def test_scl_drops_during_await_p(dut):
    """
    CP7: SCL goes low before STOP condition detected.

    In AwaitP state, if SCL becomes stable low before STOP is detected,
    FSM should abort back to AwaitPattern.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing SCL drop during AwaitP")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_with_scl_drop_await_p(
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb)
    assert no_reset, "Reset should NOT be detected when SCL drops in AwaitP"

    dut._log.info("PASS: SCL drop correctly aborted AwaitP")

    await tb.teardown()


@cocotb.test()
async def test_back_to_back_resets(dut):
    """
    CP10: Multiple valid resets in succession.

    Verify that the FSM returns cleanly to initial state after reset
    and can detect subsequent reset patterns.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing back-to-back reset patterns")

    for iteration in range(3):
        dut._log.info(f"Reset iteration {iteration + 1}")

        await i3c_controller.set_bus_idle()
        await ClockCycles(tb.clk, 10)

        await i3c_controller.send_target_reset_pattern_stress(
            num_transitions=14,
            tdig_h_ns=T_DIG_H_MIN_NS,
        )

        reset_detected = await wait_for_reset_detection(dut, tb)
        assert reset_detected, f"Reset {iteration + 1} should be detected"

        await clear_reset_state(dut, tb)
        await ClockCycles(tb.clk, 20)

    dut._log.info("PASS: All back-to-back resets detected correctly")

    await tb.teardown()


@cocotb.test()
async def test_reset_after_failed_pattern(dut):
    """
    Verify FSM recovers after a failed pattern and can detect subsequent valid reset.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing recovery after failed pattern")

    # First, send a failed pattern (SCL glitch)
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_with_scl_glitch(
        glitch_at_transition=5,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    no_reset = await check_no_reset_detection(dut, tb, wait_cycles=100)
    assert no_reset, "First pattern (with glitch) should not trigger reset"

    # Now send a valid pattern
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 20)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )

    reset_detected = await wait_for_reset_detection(dut, tb)
    assert reset_detected, "Valid reset after failed pattern should be detected"

    await clear_reset_state(dut, tb)
    dut._log.info("PASS: FSM recovered and detected valid reset after failed pattern")

    await tb.teardown()


@cocotb.test()
async def test_first_edge_must_be_falling(dut):
    """
    CP12: Pattern counting starts on negative edge.

    Per FSM logic, the first counted transition must be a falling edge.
    Starting with a rising edge should not count toward the 14 transitions.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing first edge polarity requirement")

    # Manually control the bus to start with SDA low
    # This means first edge will be rising (positive) instead of falling
    i3c_controller.sda = 0  # Start low
    i3c_controller.scl = 0
    await Timer(T_DIG_H_MIN_NS, "ns")

    # Generate 14 transitions starting with positive edge
    sda_val = 0
    for _ in range(14):
        sda_val = 0 if sda_val else 1
        i3c_controller.sda = sda_val
        await Timer(T_DIG_H_MIN_NS, "ns")

    # After 14 toggles starting from 0, we end at 0 (even number of toggles)
    await Timer(T_DIG_H_MIN_NS, "ns")
    i3c_controller.scl = 1
    await Timer(T_DIG_H_MIN_NS, "ns")

    # SDA is currently 0, need to go high for proper START setup
    i3c_controller.sda = 1
    await Timer(T_DIG_H_MIN_NS, "ns")

    # Try START (SDA falling while SCL high)
    i3c_controller.sda = 0
    await Timer(T_DIG_H_MIN_NS, "ns")

    # Try STOP (SDA rising while SCL high)
    i3c_controller.sda = 1
    await Timer(T_DIG_H_MIN_NS, "ns")

    # Per FSM: first counted edge is negative, and counter only counts
    # when sda_transition_count_q != 0 for positive edges
    # So first positive edge doesn't count, meaning we only get 13 valid transitions
    no_reset = await check_no_reset_detection(dut, tb)

    assert no_reset, "Reset should NOT be detected when first edge is rising (only 13 valid transitions counted)"
    dut._log.info("PASS: First edge polarity requirement verified — rising start prevents reset")

    await tb.teardown()


@cocotb.test()
async def test_timing_at_2x_minimum(dut):
    """
    Verify reset detection works at 2x minimum timing (more relaxed timing).
    This serves as a sanity check that the detector isn't too strict.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    relaxed_timing = T_DIG_H_MIN_NS * 2  # 280ns
    dut._log.info(f"Testing reset at relaxed timing: tDIG_H = {relaxed_timing}ns")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=relaxed_timing,
    )

    reset_detected = await wait_for_reset_detection(dut, tb)
    assert reset_detected, "Reset should be detected at relaxed timing"

    await clear_reset_state(dut, tb)
    dut._log.info("PASS: Reset detected at 2x minimum timing")

    await tb.teardown()


@cocotb.test()
async def test_very_fast_timing_below_spec(dut):
    """
    Test with timing faster than spec minimum (aggressive timing).
    This tests if the detector can keep up with fast transitions.

    Note: 40ns is the default tdig_h in cocotbext-i3c, which is below
    the I3C spec minimum of 140ns.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    # Use fast timing (40ns) - this is below spec but tests fast operation
    fast_timing = 40.0  # ns
    dut._log.info(f"Testing reset at fast timing: tDIG_H = {fast_timing}ns (below spec)")

    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 10)

    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=fast_timing,
    )

    # At 333MHz (3ns period), 40ns = ~13 clock cycles
    # This should still be detectable
    reset_detected = await wait_for_reset_detection(dut, tb)

    assert reset_detected, "Reset should be detected even at fast timing (40ns tDIG_H)"
    dut._log.info("PASS: Reset detected at fast timing (below spec minimum)")

    await tb.teardown()


@cocotb.test()
async def test_mixed_valid_and_invalid_patterns(dut):
    """
    Send a mix of valid and invalid patterns to stress the FSM transitions.
    """
    i3c_controller, tb = await test_setup(dut, disable_monitor=True)

    dut._log.info("Testing mixed valid/invalid pattern sequence")

    # Pattern 1: Invalid (SCL glitch)
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 20)
    dut._log.info("Sending pattern: invalid_scl_glitch, expect_reset=False")
    await i3c_controller.send_target_reset_pattern_with_scl_glitch(
        tdig_h_ns=T_DIG_H_MIN_NS,
    )
    no_reset = await check_no_reset_detection(dut, tb, wait_cycles=100)
    assert no_reset, "Pattern 'invalid_scl_glitch' should NOT trigger reset"

    # Pattern 2: Valid (14 transitions)
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 20)
    dut._log.info("Sending pattern: valid_14_transitions, expect_reset=True")
    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )
    reset_detected = await wait_for_reset_detection(dut, tb)
    assert reset_detected, "Pattern 'valid_14_transitions' should trigger reset"
    await clear_reset_state(dut, tb)

    # Pattern 3: Invalid (13 transitions)
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 20)
    dut._log.info("Sending pattern: invalid_13_transitions, expect_reset=False")
    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=13,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )
    no_reset = await check_no_reset_detection(dut, tb, wait_cycles=100)
    assert no_reset, "Pattern 'invalid_13_transitions' should NOT trigger reset"

    # Pattern 4: Valid (14 transitions)
    await i3c_controller.set_bus_idle()
    await ClockCycles(tb.clk, 20)
    dut._log.info("Sending pattern: valid_14_transitions, expect_reset=True")
    await i3c_controller.send_target_reset_pattern_stress(
        num_transitions=14,
        tdig_h_ns=T_DIG_H_MIN_NS,
    )
    reset_detected = await wait_for_reset_detection(dut, tb)
    assert reset_detected, "Pattern 'valid_14_transitions' should trigger reset"
    await clear_reset_state(dut, tb)

    dut._log.info("PASS: All mixed patterns behaved as expected")

    await tb.teardown()
