// SPDX-License-Identifier: Apache-2.0
//
// FSM state transition tracker for i3c_target_fsm.
//
// Logs every state_q transition with a timestamp to fsm_transitions.log.
// Enable with +define+TRACK_FSM_TRANSITIONS at compile time.
// Usage: make ... TRACK_FSM=1
//
// Output format (one line per transition):
//   <timestamp> | <old_state_name> | <new_state_name>

`ifndef SYNTHESIS
`ifndef VERILATOR

module fsm_state_tracker (
    input logic       clk_i,
    input logic       rst_ni,
    input logic [7:0] state_q
);

`ifdef TRACK_FSM_TRANSITIONS
  logic [7:0] prev_state_trk;
  integer fsm_log_fd;

  function automatic string state_to_name(input logic [7:0] s);
    case (s)
      8'd0:  return "Idle";
      8'd1:  return "RxFByteArb";
      8'd2:  return "RxFByte";
      8'd3:  return "CheckFByte";
      8'd4:  return "TxAckFByte";
      8'd5:  return "RxSByte";
      8'd6:  return "RxSByteRepeated";
      8'd7:  return "CheckSByte";
      8'd8:  return "TxAckSByte";
      8'd9:  return "RxPWriteData";
      8'd10: return "RxPWriteTbit";
      8'd11: return "TxPReadData";
      8'd12: return "TxPReadTbitCont";
      8'd13: return "TxPReadTbitEnd";
      8'd14: return "WaitRestart";
      8'd15: return "DoCCC";
      8'd16: return "DoneCCC";
      8'd17: return "DoHotJoin";
      8'd18: return "DoRstAction";
      8'd19: return "InHDRMode";
      8'd20: return "IbiDriveAddr";
      8'd21: return "IbiReadAck";
      8'd22: return "IbiSendData";
      8'd23: return "IbiTbitCont";
      8'd24: return "IbiTbitEnd";
      default: begin
        string name;
        $sformat(name, "UNKNOWN(%0d)", s);
        return name;
      end
    endcase
  endfunction

  initial begin
    fsm_log_fd = $fopen("fsm_transitions.log", "w");
    if (fsm_log_fd == 0) begin
      $display("ERROR [fsm_state_tracker] $fopen failed for fsm_transitions.log");
    end else begin
      $display("INFO [fsm_state_tracker] Opened fsm_transitions.log (fd=%0d)", fsm_log_fd);
    end
    $fwrite(fsm_log_fd, "# i3c_target_fsm state transition log\n");
    $fwrite(fsm_log_fd, "# timestamp | old_state | new_state\n");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_state_trk <= 8'd0;
    end else if (state_q !== prev_state_trk) begin
      $fwrite(fsm_log_fd, "%0t | %s | %s\n",
              $time, state_to_name(prev_state_trk), state_to_name(state_q));
      prev_state_trk <= state_q;
    end
  end

  final begin
    $fclose(fsm_log_fd);
  end
`endif

endmodule : fsm_state_tracker

bind i3c_target_fsm fsm_state_tracker u_fsm_state_tracker (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .state_q (state_q)
);

`endif // VERILATOR
`endif // SYNTHESIS
