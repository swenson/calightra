# SPDX-License-Identifier: Apache-2.0
"""
Fixed I3C Recovery Interface

This module provides a corrected version of I3cRecoveryInterface that fixes
a bug in the upstream cocotbext-i3c library where _i3c_recovery_read was
sending an extra Sr + 0x7E sequence before the read phase.

The OCP Recovery READ transaction format is:
    S + Addr+W + CMD + PEC + Sr + Addr+R + LEN_L + LEN_H + DATA + PEC + P

The bug was sending:
    S + 0x7E + Sr + Addr+W + CMD + PEC + Sr + 0x7E + Sr + Addr+R + ...
                                         ^^^^^^^^^^^
                                         Extra sequence (wrong)

The fix sends:
    S + 0x7E + Sr + Addr+W + CMD + PEC + Sr + Addr+R + ...
                                         ^^^^^^^^^^^^
                                         Correct - just Sr + Addr+R

Additional Features:
    - Extended command_write with stop= and start= parameters for chaining
    - Extended command_read with stop= and start= parameters for chaining
    - Added command_write_abort for testing abort scenarios
    - Added command_write_tbit_error for testing T-bit error injection
    - Added command_write_truncated for testing truncated transfers
    - Added command_write_wrong_length for testing length mismatch
    - Added command_write_invalid_command for testing invalid commands
    - Added command_read_abort for testing read abort scenarios
    - Added send_repeated_start_only for partial frame testing
    - Added send_address_only_nack for NACK testing

Usage:
    Instead of:
        from cocotbext_i3c.i3c_recovery_interface import I3cRecoveryInterface

    Use:
        from i3c_recovery_interface_fixed import I3cRecoveryInterfaceFixed as I3cRecoveryInterface
"""

from cocotb.triggers import Timer
from cocotbext_i3c.i3c_recovery_interface import I3cRecoveryInterface, I3cRecoveryException
from cocotbext_i3c.common import I3C_RSVD_BYTE


class I3cRecoveryInterfaceFixed(I3cRecoveryInterface):
    """
    Fixed version of I3cRecoveryInterface with corrected _i3c_recovery_read
    and additional methods for chained commands and error injection testing.
    """

    async def _i3c_recovery_read(self, address, send_stop=True, stop=None):
        """
        Issues a private read using low-level functions of the controller
        adapter. This is needed as the length of data to be received is
        contained in the first two bytes of the packet.

        This continues an existing transaction (after command_read sent
        S + 0x7E + Sr + Addr+W + CMD + PEC without STOP). We just need to
        send Sr + Addr+R to switch to read mode.

        FIXED: Removed the extra Sr + 0x7E sequence that was incorrectly
        being sent before the read address.

        Args:
            address: I3C target address
            send_stop: If True, send STOP at end; if False, leave bus active for chaining
            stop: Alias for send_stop (for API compatibility)
        """
        # Allow 'stop' as alias for 'send_stop'
        if stop is not None:
            send_stop = stop

        # Continue with repeated start for read phase
        # No need to send 0x7E again - we're continuing the same transaction
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address, read=True)
        if not ack:
            await self.controller.send_stop()
            self.controller.give_bus_control()
            return None, None

        # Begin reception
        try:
            # Read length
            len_bytes = []
            for i in range(2):
                byte, stop = await self.controller.recv_byte_t_bit(stop=False)
                len_bytes.append(byte)
                self.log.debug(f"Recovery Rx: byte[{i}]: 0x{byte:02X} (stop={int(stop)})")

                # Length is mandatory. If the transfer gets terminated raise an
                # exception.
                if stop:
                    self.log.error(f"Target requested stop at byte {i}")
                    raise I3cRecoveryException

            length = (len_bytes[1] << 8) | len_bytes[0]
            self.log.debug(f"Recovery Rx: Payload length is {length}B")

            # Read data. Raise an exception in case of an unexpected stop
            data = []
            for i in range(length):
                byte, stop = await self.controller.recv_byte_t_bit(stop=False)
                data.append(byte)
                self.log.debug(f"Recovery Rx: byte[{i + 2}]: 0x{byte:02X} (stop={int(stop)})")

                if stop:
                    self.log.error(f"Target requested stop at byte {i + 2}")
                    raise I3cRecoveryException

            # Read PEC. Expect stop at this byte
            pec_recv, stop = await self.controller.recv_byte_t_bit(stop=True)
            if not stop:
                self.log.error("Target wishes to transfer more data after PEC")
                raise I3cRecoveryException

        # In case of a protocol error wait some time and then re-throw
        except I3cRecoveryException:
            await Timer(1, "us")
            raise

        if send_stop:
            await self.controller.send_stop()
            self.controller.give_bus_control()

        # Compute reference PEC checksum
        pec_calc = int(self.pec_calc.checksum(bytes([(address << 1) | 1] + len_bytes + data)))

        # Return the data and received PEC validity
        return data, (pec_recv == pec_calc)

    async def command_write(self, address, command, data=None, force_pec_error=False,
                            stop=True, start=True, debug_pec=False):
        """
        Issues a write command to the target with optional chaining support.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            data: Data bytes to write (optional)
            force_pec_error: If True, send incorrect PEC
            stop: If True (default), send STOP at end; if False, leave bus active
            start: If True (default), send START + 0x7E header; if False, continue existing transaction
            debug_pec: If True, print debug messages showing PEC input/output for each byte
        """

        if not data:
            data = []

        # Header
        xfer = [
            command,
            len(data) & 0xFF,
            (len(data) >> 8) & 0xFF,
        ]

        # Data
        xfer.extend(data)

        # Compute PEC with optional debug logging
        pec_input_bytes = [address << 1] + xfer
        if debug_pec:
            import cocotb
            cocotb.log.info("=== PEC DEBUG (command_write) ===")
            cocotb.log.info(f"  Address byte: 0x{address << 1:02X} (addr={address:#x} << 1)")
            # Show cumulative PEC after each byte
            cumulative_pec = 0
            for i, byte in enumerate(pec_input_bytes):
                cumulative_pec = int(self.pec_calc.checksum(bytes(pec_input_bytes[:i+1])))
                if i == 0:
                    label = "ADDR"
                elif i == 1:
                    label = "CMD"
                elif i == 2:
                    label = "LEN_L"
                elif i == 3:
                    label = "LEN_H"
                else:
                    label = f"DATA[{i-4}]"
                cocotb.log.info(f"  Byte {i}: {label}=0x{byte:02X} -> PEC=0x{cumulative_pec:02X}")
            cocotb.log.info(f"  Final PEC: 0x{cumulative_pec:02X}")
            cocotb.log.info("=================================")
        pec = int(self.pec_calc.checksum(bytes(pec_input_bytes)))

        # Inject incorrect PEC
        if force_pec_error:
            pec = self._randomize_pec(pec)

        xfer.append(pec)

        # Do the I3C write transfer using the controller functionality
        if start:
            await self.controller.take_bus_control()
            await self.controller.send_start()
            await self.controller.write_addr_header(I3C_RSVD_BYTE)
            await self.controller.send_start()
            ack = await self.controller.write_addr_header(address)
        else:
            # Continuing an existing transaction with repeated start
            await self.controller.send_start()
            await self.controller.write_addr_header(I3C_RSVD_BYTE)
            await self.controller.send_start()
            ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)

        if stop:
            await self.controller.send_stop()
            self.controller.give_bus_control()

    async def command_read(self, address, command, force_pec_error=False, stop=True, start=True):
        """
        Issues a read command to the target with optional chaining support.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            force_pec_error: If True, send incorrect PEC in write phase
            stop: If True (default), send STOP at end; if False, leave bus active
            start: If True (default), send START + 0x7E header; if False, continue existing transaction

        Returns:
            Tuple of (data, pec_ok) where data is list of bytes and pec_ok is boolean
        """

        # Header
        xfer = [command]

        # Compute PEC
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))

        # Inject incorrect PEC
        if force_pec_error:
            pec = self._randomize_pec(pec)

        xfer.append(pec)

        # Do the I3C write transfer (command phase)
        if start:
            await self.controller.take_bus_control()
            await self.controller.send_start()
            await self.controller.write_addr_header(I3C_RSVD_BYTE)
            await self.controller.send_start()
            ack = await self.controller.write_addr_header(address)
        else:
            # Continuing an existing transaction with repeated start
            await self.controller.send_start()
            await self.controller.write_addr_header(I3C_RSVD_BYTE)
            await self.controller.send_start()
            ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)

        # Do not send stop here - continue with read phase
        # Do the I3C read transfer. Return the results.
        return await self._i3c_recovery_read(address, send_stop=stop)

    async def command_write_abort(self, address, command, data=None, abort_after_bytes=1):
        """
        Issues a write command but aborts (sends STOP) after a certain number of bytes.
        Used for testing target recovery from incomplete transfers.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            data: Data bytes (some or none will actually be sent)
            abort_after_bytes: Number of bytes to send before aborting
                              (0 = just address, 1 = command byte, 2 = command + len_l, etc.)
        """
        if not data:
            data = []

        # Build full transfer
        xfer = [
            command,
            len(data) & 0xFF,
            (len(data) >> 8) & 0xFF,
        ]
        xfer.extend(data)
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            # Send only abort_after_bytes bytes, then abort
            bytes_sent = 0
            for byte in xfer:
                if bytes_sent >= abort_after_bytes:
                    break
                await self.controller.send_byte_tbit(byte)
                bytes_sent += 1

        # Abort with STOP
        await self.controller.send_stop()
        self.controller.give_bus_control()

    async def command_write_tbit_error(self, address, command, data=None, error_byte_index=0):
        """
        Issues a write command with an intentional T-bit (parity) error on a specific byte.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            data: Data bytes to write
            error_byte_index: Which byte (0-indexed) to inject T-bit error on
                             (0 = command, 1 = len_l, 2 = len_h, 3+ = data bytes)
        """
        if not data:
            data = []

        # Build full transfer
        xfer = [
            command,
            len(data) & 0xFF,
            (len(data) >> 8) & 0xFF,
        ]
        xfer.extend(data)
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for i, byte in enumerate(xfer):
                inject_error = (i == error_byte_index)
                await self.controller.send_byte_tbit(byte, inject_tbit_err=inject_error)

        await self.controller.send_stop()
        self.controller.give_bus_control()

    async def command_read_tbit_error(self, address, command, error_byte_index=0):
        """
        Issues a read command with T-bit error on a specific byte in the write phase.

        Write phase xfer: [CMD(0), PEC(1)]. After error injection, attempts
        the read phase (Sr + Addr+R). Returns None if target NACKs.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            error_byte_index: Byte index in write phase to corrupt (0=CMD, 1=PEC)

        Returns:
            Tuple of (data, pec_ok) or (None, None) if target NACKed
        """
        xfer = [command]
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for i, byte in enumerate(xfer):
                inject_error = (i == error_byte_index)
                await self.controller.send_byte_tbit(byte, inject_tbit_err=inject_error)

        # Continue with read phase — target may NACK if error was detected
        try:
            return await self._i3c_recovery_read(address, send_stop=True)
        except I3cRecoveryException:
            return None, None

    async def command_write_truncated(self, address, command, data=None, truncate_before_pec=True):
        """
        Issues a write command but truncates it before sending PEC.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            data: Data bytes to write
            truncate_before_pec: If True, send all data but no PEC
        """
        if not data:
            data = []

        # Build transfer without PEC
        xfer = [
            command,
            len(data) & 0xFF,
            (len(data) >> 8) & 0xFF,
        ]
        xfer.extend(data)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)
            # Do NOT send PEC if truncate_before_pec is True

        # Abort with STOP
        await self.controller.send_stop()
        self.controller.give_bus_control()

    async def command_write_wrong_length(self, address, command, data=None, claimed_length=None):
        """
        Issues a write command with a mismatched length field.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            data: Actual data bytes to send
            claimed_length: Length to put in header (different from actual data length)
        """
        if not data:
            data = []

        if claimed_length is None:
            claimed_length = len(data)

        # Build transfer with wrong length in header
        xfer = [
            command,
            claimed_length & 0xFF,
            (claimed_length >> 8) & 0xFF,
        ]
        xfer.extend(data)
        # PEC is calculated over what we're actually sending
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)

        await self.controller.send_stop()
        self.controller.give_bus_control()

    async def command_write_invalid_command(self, address, invalid_command, data=None):
        """
        Issues a write with an invalid/undefined command code.

        Args:
            address: I3C target address
            invalid_command: Invalid command code to send
            data: Data bytes to include
        """
        if not data:
            data = []

        # Build transfer with invalid command
        xfer = [
            invalid_command,
            len(data) & 0xFF,
            (len(data) >> 8) & 0xFF,
        ]
        xfer.extend(data)
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)

        await self.controller.send_stop()
        self.controller.give_bus_control()

    async def command_read_abort(self, address, command, abort_after_bytes=3):
        """
        Issues a read command but aborts mid-read using the T-bit mechanism.

        The abort is performed by signaling request_end=True on the T-bit of
        the last byte to read. This causes the controller to pull SDA low
        while SCL is high (Sr), followed by a STOP (P). This Sr+P sequence
        is the proper I3C mid-read abort.

        Args:
            address: I3C target address
            command: OCP Recovery command code
            abort_after_bytes: Number of bytes to read before aborting
                              (0 = after address, 1 = after first byte, etc.)
        """
        # First, send the command (write phase)
        xfer = [command]
        pec = int(self.pec_calc.checksum(bytes([address << 1] + xfer)))
        xfer.append(pec)

        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        if ack:
            for byte in xfer:
                await self.controller.send_byte_tbit(byte)

        # Now start read phase
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address, read=True)

        if ack:
            # Read bytes; on the last byte use T-bit to signal abort (Sr)
            for i in range(abort_after_bytes):
                try:
                    is_abort_byte = (i == abort_after_bytes - 1)
                    byte, stop = await self.controller.recv_byte_t_bit(stop=is_abort_byte)
                    if stop:
                        break
                except Exception:
                    break

        # T-bit already generated Sr, now send P to complete the abort
        await self.controller.send_stop(pull_scl_low=False)
        self.controller.give_bus_control()

    async def send_repeated_start_only(self, address):
        """
        Sends just the I3C address header without any data (partial frame).
        Returns True if ACK received, False if NACK.

        Args:
            address: I3C target address

        Returns:
            True if target ACKed, False if NACKed
        """
        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        # Immediately send STOP without any data
        await self.controller.send_stop()
        self.controller.give_bus_control()

        return ack

    async def send_address_only_nack(self, address):
        """
        Sends an address that should be NACKed (wrong address test).
        Returns True if ACK received (unexpected), False if NACK (expected).

        Args:
            address: I3C address that should NOT be on the bus

        Returns:
            True if target ACKed (error), False if NACKed (expected)
        """
        await self.controller.take_bus_control()
        await self.controller.send_start()
        await self.controller.write_addr_header(I3C_RSVD_BYTE)
        await self.controller.send_start()
        ack = await self.controller.write_addr_header(address)

        # Send STOP
        await self.controller.send_stop()
        self.controller.give_bus_control()

        return ack
