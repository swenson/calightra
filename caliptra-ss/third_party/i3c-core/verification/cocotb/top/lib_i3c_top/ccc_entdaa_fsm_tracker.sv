// SPDX-License-Identifier: Apache-2.0
//
// FSM state transition tracker for ccc_entdaa.
//
// Logs every state_q transition with a timestamp to ccc_entdaa_fsm_transitions.log.
// Enable with +define+TRACK_FSM_TRANSITIONS at compile time.
// Usage: make ... TRACK_FSM=1
//
// Output format (one line per transition):
//   <timestamp> | <old_state_name> | <new_state_name>

`ifndef SYNTHESIS
`ifndef VERILATOR

module ccc_entdaa_fsm_tracker (
    input logic       clk_i,
    input logic       rst_ni,
    input logic [7:0] state_q
);

`ifdef TRACK_FSM_TRANSITIONS
  logic [7:0] prev_state_trk;
  integer fsm_log_fd;

  function automatic string state_to_name(input logic [7:0] s);
    case (s)
      8'h0: return "Idle";
      8'h1: return "WaitStart";
      8'h2: return "ReceiveRsvdByte";
      8'h3: return "AckRsvdByte";
      8'h4: return "SendNack";
      8'h5: return "SendID";
      8'h6: return "PrepareIDBit";
      8'h7: return "SendIDBit";
      8'h8: return "LostArbitration";
      8'h9: return "ReceiveAddr";
      8'ha: return "AckAddr";
      8'hb: return "Done";
      8'hc: return "WaitStop";
      default: begin
        string name;
        $sformat(name, "UNKNOWN(0x%02h)", s);
        return name;
      end
    endcase
  endfunction

  initial begin
    fsm_log_fd = $fopen("ccc_entdaa_fsm_transitions.log", "w");
    if (fsm_log_fd == 0) begin
      $display("ERROR [ccc_entdaa_fsm_tracker] $fopen failed");
    end else begin
      $display("INFO [ccc_entdaa_fsm_tracker] Opened ccc_entdaa_fsm_transitions.log (fd=%0d)", fsm_log_fd);
    end
    $fwrite(fsm_log_fd, "# ccc_entdaa state transition log\n");
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

endmodule : ccc_entdaa_fsm_tracker

bind ccc_entdaa ccc_entdaa_fsm_tracker u_ccc_entdaa_fsm_tracker (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .state_q (state_q)
);

`endif // VERILATOR
`endif // SYNTHESIS
