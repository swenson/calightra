// SPDX-License-Identifier: Apache-2.0
//
// FSM state transition tracker for recovery_receiver.
//
// Logs every state_q transition with a timestamp to recovery_receiver_fsm_transitions.log.
// Enable with +define+TRACK_FSM_TRANSITIONS at compile time.
// Usage: make ... TRACK_FSM=1
//
// Output format (one line per transition):
//   <timestamp> | <old_state_name> | <new_state_name>

`ifndef SYNTHESIS
`ifndef VERILATOR

module recovery_receiver_fsm_tracker (
    input logic       clk_i,
    input logic       rst_ni,
    input logic [7:0] state_q
);

`ifdef TRACK_FSM_TRANSITIONS
  logic [7:0] prev_state_trk;
  integer fsm_log_fd;

  function automatic string state_to_name(input logic [7:0] s);
    case (s)
      8'h00: return "Idle";
      8'h10: return "RxCmd";
      8'h11: return "RxLenL";
      8'h12: return "RxLenH";
      8'h20: return "RxData";
      8'h30: return "RxPec";
      8'h40: return "CmdDispatch";
      8'h41: return "ExecCsrWrite";
      8'h50: return "ExecFifoWrite";
      8'h60: return "TxDesc";
      8'h61: return "TxLenL";
      8'h62: return "TxLenH";
      8'h63: return "TxData";
      8'h64: return "TxPec";
      8'hD0: return "Done";
      8'hE1: return "Error";
      default: begin
        string name;
        $sformat(name, "UNKNOWN(0x%02h)", s);
        return name;
      end
    endcase
  endfunction

  initial begin
    fsm_log_fd = $fopen("recovery_receiver_fsm_transitions.log", "w");
    if (fsm_log_fd == 0) begin
      $display("ERROR [recovery_receiver_fsm_tracker] $fopen failed");
    end else begin
      $display("INFO [recovery_receiver_fsm_tracker] Opened recovery_receiver_fsm_transitions.log (fd=%0d)", fsm_log_fd);
    end
    $fwrite(fsm_log_fd, "# recovery_receiver state transition log\n");
    $fwrite(fsm_log_fd, "# timestamp | old_state | new_state\n");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_state_trk <= 8'h00;
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

endmodule : recovery_receiver_fsm_tracker

bind recovery_receiver recovery_receiver_fsm_tracker u_recovery_receiver_fsm_tracker (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .state_q (state_q)
);

`endif // VERILATOR
`endif // SYNTHESIS
