// SPDX-License-Identifier: Apache-2.0
//
// FSM state transition tracker for descriptor_ibi.
//
// Logs every state_q transition with a timestamp to descriptor_ibi_fsm_transitions.log.
// Enable with +define+TRACK_FSM_TRANSITIONS at compile time.
// Usage: make ... TRACK_FSM=1
//
// Output format (one line per transition):
//   <timestamp> | <old_state_name> | <new_state_name>

`ifndef SYNTHESIS
`ifndef VERILATOR

module descriptor_ibi_fsm_tracker (
    input logic       clk_i,
    input logic       rst_ni,
    input logic [2:0] state_q
);

`ifdef TRACK_FSM_TRANSITIONS
  logic [2:0] prev_state_trk;
  integer fsm_log_fd;

  function automatic string state_to_name(input logic [2:0] s);
    case (s)
      3'd0: return "Idle";
      3'd1: return "DescLatch";
      3'd2: return "DescPop";
      3'd3: return "WriteMdb";
      3'd4: return "WriteData";
      3'd5: return "Flush";
      default: begin
        string name;
        $sformat(name, "UNKNOWN(%0d)", s);
        return name;
      end
    endcase
  endfunction

  initial begin
    fsm_log_fd = $fopen("descriptor_ibi_fsm_transitions.log", "w");
    if (fsm_log_fd == 0) begin
      $display("ERROR [descriptor_ibi_fsm_tracker] $fopen failed");
    end else begin
      $display("INFO [descriptor_ibi_fsm_tracker] Opened descriptor_ibi_fsm_transitions.log (fd=%0d)", fsm_log_fd);
    end
    $fwrite(fsm_log_fd, "# descriptor_ibi state transition log\n");
    $fwrite(fsm_log_fd, "# timestamp | old_state | new_state\n");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_state_trk <= 3'd0;
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

endmodule : descriptor_ibi_fsm_tracker

bind descriptor_ibi descriptor_ibi_fsm_tracker u_descriptor_ibi_fsm_tracker (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .state_q (state_q)
);

`endif // VERILATOR
`endif // SYNTHESIS
