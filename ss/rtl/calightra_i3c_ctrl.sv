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
//
// Calightra Open-Source I3C Controller (Master) IP
//
// Implements a synthesizable MIPI I3C Basic v1.1.1 SDR Controller with a
// Xilinx AXI I3C (XI3C) compatible MMIO register interface (matching the
// register layout in caliptra-sw hw-model/src/xi3c/controller.rs).
//
// Features:
//   - Full I3C SDR Private Write, Private Read, Broadcast CCC, and Direct CCC
//     wire framing over physical 2-wire SCL / SDA pins.
//   - Automatic odd-parity T-bit generation on I3C writes and Target T-bit
//     sampling / controller read-abort on I3C reads.
//   - Repeated Start (Sr) chaining across commands when TOC (no_repeated_start) = 0.
//   - Hardware SMBus CRC-8 (0x07) PEC calculation and automatic append/consume
//     for OCP Recovery block writes and reads when PEC bit (cmd[5]) = 1.

module calightra_i3c_ctrl #(
    parameter int CMD_FIFO_DEPTH   = 16,
    parameter int WR_FIFO_DEPTH    = 128,
    parameter int RD_FIFO_DEPTH    = 64,
    parameter int RESP_FIFO_DEPTH  = 16,
    parameter int DEFAULT_SCL_HIGH = 6,
    parameter int DEFAULT_SCL_LOW  = 6
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Simple 32-bit MMIO Register Interface
    input  logic [7:0]  reg_addr_i,
    input  logic [31:0] reg_wdata_i,
    input  logic        reg_we_i,
    input  logic        reg_re_i,
    output logic [31:0] reg_rdata_o,

    // Physical I3C Bus Signals
    input  logic        i3c_scl_i,
    output logic        i3c_scl_o,
    output logic        i3c_scl_oe_o,
    input  logic        i3c_sda_i,
    output logic        i3c_sda_o,
    output logic        i3c_sda_oe_o
);

    // -------------------------------------------------------------------------
    // Register Offsets (matches caliptra-sw xi3c::Controller)
    // -------------------------------------------------------------------------
    localparam logic [7:0] REG_VERSION           = 8'h00;
    localparam logic [7:0] REG_RESET             = 8'h04;
    localparam logic [7:0] REG_CR                = 8'h08;
    localparam logic [7:0] REG_ADDRESS           = 8'h0C;
    localparam logic [7:0] REG_SR                = 8'h10;
    localparam logic [7:0] REG_INTR_STATUS       = 8'h14;
    localparam logic [7:0] REG_INTR_RE           = 8'h18;
    localparam logic [7:0] REG_INTR_FE           = 8'h1C;
    localparam logic [7:0] REG_CMD_FIFO          = 8'h20;
    localparam logic [7:0] REG_WR_FIFO           = 8'h24;
    localparam logic [7:0] REG_RD_FIFO           = 8'h28;
    localparam logic [7:0] REG_RESP_STATUS_FIFO  = 8'h2C;
    localparam logic [7:0] REG_FIFO_LVL_STATUS   = 8'h30;
    localparam logic [7:0] REG_FIFO_LVL_STATUS_1 = 8'h34;
    localparam logic [7:0] REG_SCL_HIGH_TIME     = 8'h38;
    localparam logic [7:0] REG_SCL_LOW_TIME      = 8'h3C;
    localparam logic [7:0] REG_SDA_HOLD_TIME     = 8'h40;
    localparam logic [7:0] REG_TSU_START         = 8'h44;
    localparam logic [7:0] REG_THD_START         = 8'h48;
    localparam logic [7:0] REG_TSU_STOP          = 8'h4C;
    localparam logic [7:0] REG_OD_SCL_HIGH_TIME  = 8'h50;
    localparam logic [7:0] REG_OD_SCL_LOW_TIME   = 8'h54;

    localparam int CMD_PTR_W  = $clog2(CMD_FIFO_DEPTH);
    localparam int WR_PTR_W   = $clog2(WR_FIFO_DEPTH);
    localparam int RD_PTR_W   = $clog2(RD_FIFO_DEPTH);
    localparam int RESP_PTR_W = $clog2(RESP_FIFO_DEPTH);

    // -------------------------------------------------------------------------
    // SMBus CRC-8 (x^8 + x^2 + x + 1, poly = 0x07) for OCP Recovery PEC
    // -------------------------------------------------------------------------
    function automatic logic [7:0] next_crc8(input logic [7:0] crc, input logic [7:0] data);
        logic [7:0] c;
        c = crc ^ data;
        for (int i = 0; i < 8; i++) begin
            c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
        end
        return c;
    endfunction

    // -------------------------------------------------------------------------
    // FIFOs: CMD_FIFO, WR_FIFO, RD_FIFO, RESP_STATUS_FIFO
    // -------------------------------------------------------------------------
    logic [31:0]          cmd_fifo_mem [0:CMD_FIFO_DEPTH-1];
    logic [CMD_PTR_W-1:0] cmd_wr_ptr, cmd_rd_ptr;
    logic [CMD_PTR_W:0]   cmd_count;
    wire                  cmd_fifo_empty = (cmd_count == 0);
    wire                  cmd_fifo_full  = (cmd_count == CMD_FIFO_DEPTH[CMD_PTR_W:0]);

    logic [31:0]          wr_fifo_mem [0:WR_FIFO_DEPTH-1];
    logic [WR_PTR_W-1:0]  wr_wr_ptr, wr_rd_ptr;
    logic [WR_PTR_W:0]    wr_count;
    wire                  wr_fifo_empty = (wr_count == 0);
    wire                  wr_fifo_full  = (wr_count == WR_FIFO_DEPTH[WR_PTR_W:0]);

    logic [31:0]          rd_fifo_mem [0:RD_FIFO_DEPTH-1];
    logic [RD_PTR_W-1:0]  rd_wr_ptr, rd_rd_ptr;
    logic [RD_PTR_W:0]    rd_count;
    wire                  rd_fifo_empty = (rd_count == 0);
    wire                  rd_fifo_full  = (rd_count == RD_FIFO_DEPTH[RD_PTR_W:0]);

    logic [31:0]           resp_fifo_mem [0:RESP_FIFO_DEPTH-1];
    logic [RESP_PTR_W-1:0] resp_wr_ptr, resp_rd_ptr;
    logic [RESP_PTR_W:0]   resp_count;
    wire                   resp_fifo_empty = (resp_count == 0);
    wire                   resp_fifo_full  = (resp_count == RESP_FIFO_DEPTH[RESP_PTR_W:0]);

    // -------------------------------------------------------------------------
    // Configuration & Status Registers
    // -------------------------------------------------------------------------
    logic [31:0] reg_cr;
    logic [31:0] reg_address;
    logic [31:0] reg_intr_re;
    logic [31:0] reg_intr_fe;
    logic [15:0] reg_scl_high;
    logic [15:0] reg_scl_low;

    wire soft_rst = reg_we_i && (reg_addr_i == REG_RESET) && (|reg_wdata_i[4:0]);

    // -------------------------------------------------------------------------
    // I3C Bus Master State Machine
    // -------------------------------------------------------------------------
    typedef enum logic [4:0] {
        ST_IDLE          = 5'd0,
        ST_START         = 5'd1,
        ST_RSTART_PREP   = 5'd2,
        ST_RSTART        = 5'd3,
        ST_ADDR_BIT_LOW  = 5'd4,
        ST_ADDR_BIT_HIGH = 5'd5,
        ST_ADDR_ACK_LOW  = 5'd6,
        ST_ADDR_ACK_HIGH = 5'd7,
        ST_TX_BIT_LOW    = 5'd8,
        ST_TX_BIT_HIGH   = 5'd9,
        ST_TX_TBIT_LOW   = 5'd10,
        ST_TX_TBIT_HIGH  = 5'd11,
        ST_RX_BIT_LOW    = 5'd12,
        ST_RX_BIT_HIGH   = 5'd13,
        ST_RX_TBIT_LOW   = 5'd14,
        ST_RX_TBIT_HIGH  = 5'd15,
        ST_STOP_LOW      = 5'd16,
        ST_STOP_HIGH     = 5'd17,
        ST_HOLD_SR       = 5'd18
    } state_e;

    state_e      state_q;
    logic [15:0] clk_cnt;
    logic [2:0]  bit_idx;

    // Latched command fields
    logic [31:0] cmd_reg;
    wire  [3:0]  cmd_type         = cmd_reg[3:0];
    wire         cmd_no_rpt_start = cmd_reg[4];
    wire         cmd_pec          = cmd_reg[5];
    wire         cmd_rw           = cmd_reg[8];
    wire  [6:0]  cmd_target_addr  = cmd_reg[15:9];
    wire  [11:0] cmd_byte_count   = cmd_reg[27:16];
    wire  [3:0]  cmd_tid          = cmd_reg[31:28];

    // Transfer state
    logic [7:0]  tx_shift_reg;
    logic        tx_tbit;
    logic [11:0] tx_bytes_rem;
    logic [1:0]  tx_byte_idx;
    logic        sending_pec;

    logic [7:0]  rx_shift_reg;
    logic        rx_tbit_val;
    logic [11:0] rx_bytes_rem;
    logic [11:0] rx_bytes_rcvd;
    logic [1:0]  rx_byte_idx;
    logic [31:0] rx_word_acc;
    logic        receiving_pec;

    logic [7:0]  pec_crc;
    logic        nack_err;
    logic        resp_pushed_for_cmd;

    // FIFO internal push/pop signals from FSM
    logic        fsm_cmd_pop;
    logic        fsm_wr_pop;
    logic        fsm_rd_push;
    logic [31:0] fsm_rd_wdata;
    logic        fsm_resp_push;
    logic [31:0] fsm_resp_wdata;

    // Extract current byte from front of WR_FIFO (big-endian packing as in XI3C)
    wire [31:0] wr_front_word = wr_fifo_mem[wr_rd_ptr];
    logic [7:0] wr_front_byte;
    always_comb begin
        unique case (tx_byte_idx)
            2'd0: wr_front_byte = wr_front_word[31:24];
            2'd1: wr_front_byte = wr_front_word[23:16];
            2'd2: wr_front_byte = wr_front_word[15:8];
            2'd3: wr_front_byte = wr_front_word[7:0];
        endcase
    end

    assign i3c_scl_oe_o = 1'b1;

    // -------------------------------------------------------------------------
    // MMIO Read Mux
    // -------------------------------------------------------------------------
    wire [31:0] sr_val = {
        16'h0,
        ~rd_fifo_empty,       // [15] RD_FIFO_NOT_EMPTY (0x8000)
        7'h0,
        wr_fifo_full,         // [7]  WR_FIFO_FULL
        2'b0,
        ~resp_fifo_empty,     // [4]  RESP_NOT_EMPTY (0x0010)
        3'b0,
        (state_q != ST_IDLE)  // [0]  BUSY
    };

    wire [15:0] cmd_free_space = CMD_FIFO_DEPTH[15:0] - {11'h0, cmd_count};
    wire [15:0] wr_free_space  = WR_FIFO_DEPTH[15:0]  - {8'h0,  wr_count};

    always_comb begin
        reg_rdata_o = 32'h0;
        unique case (reg_addr_i)
            REG_VERSION:           reg_rdata_o = 32'h0001_0100;
            REG_RESET:             reg_rdata_o = 32'h0000_0000;
            REG_CR:                reg_rdata_o = reg_cr;
            REG_ADDRESS:           reg_rdata_o = reg_address;
            REG_SR:                reg_rdata_o = sr_val;
            REG_INTR_STATUS:       reg_rdata_o = sr_val;
            REG_INTR_RE:           reg_rdata_o = reg_intr_re;
            REG_INTR_FE:           reg_rdata_o = reg_intr_fe;
            REG_RD_FIFO:           reg_rdata_o = rd_fifo_empty   ? 32'h0 : rd_fifo_mem[rd_rd_ptr];
            REG_RESP_STATUS_FIFO:  reg_rdata_o = resp_fifo_empty ? 32'h0 : resp_fifo_mem[resp_rd_ptr];
            REG_FIFO_LVL_STATUS:   reg_rdata_o = {cmd_free_space, wr_free_space};
            REG_FIFO_LVL_STATUS_1: reg_rdata_o = {{11'h0, resp_count}, {9'h0, rd_count}};
            REG_SCL_HIGH_TIME:     reg_rdata_o = {16'h0, reg_scl_high};
            REG_SCL_LOW_TIME:      reg_rdata_o = {16'h0, reg_scl_low};
            default:               reg_rdata_o = 32'h0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential Logic: FIFOs, Registers, and I3C Bus FSM
    // -------------------------------------------------------------------------
    wire mmio_cmd_push = reg_we_i && (reg_addr_i == REG_CMD_FIFO)         && !cmd_fifo_full;
    wire mmio_wr_push  = reg_we_i && (reg_addr_i == REG_WR_FIFO)          && !wr_fifo_full;
    wire mmio_rd_pop   = reg_re_i && (reg_addr_i == REG_RD_FIFO)          && !rd_fifo_empty;
    wire mmio_resp_pop = reg_re_i && (reg_addr_i == REG_RESP_STATUS_FIFO) && !resp_fifo_empty;

    // Synchronous FIFO memory writes without async reset for LUTRAM/BRAM inference
    always_ff @(posedge clk_i) begin
        if (mmio_cmd_push)                  cmd_fifo_mem[cmd_wr_ptr]   <= reg_wdata_i;
        if (mmio_wr_push)                   wr_fifo_mem[wr_wr_ptr]     <= reg_wdata_i;
        if (fsm_rd_push && !rd_fifo_full)   rd_fifo_mem[rd_wr_ptr]     <= fsm_rd_wdata;
        if (fsm_resp_push && !resp_fifo_full) resp_fifo_mem[resp_wr_ptr] <= fsm_resp_wdata;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            reg_cr        <= 32'h0000_0001; // Enabled by default
            reg_address   <= 32'h0000_0001;
            reg_intr_re   <= 32'h0;
            reg_intr_fe   <= 32'h0;
            reg_scl_high  <= DEFAULT_SCL_HIGH[15:0];
            reg_scl_low   <= DEFAULT_SCL_LOW[15:0];

            cmd_wr_ptr    <= '0;
            cmd_rd_ptr    <= '0;
            cmd_count     <= '0;

            wr_wr_ptr     <= '0;
            wr_rd_ptr     <= '0;
            wr_count      <= '0;

            rd_wr_ptr     <= '0;
            rd_rd_ptr     <= '0;
            rd_count      <= '0;

            resp_wr_ptr   <= '0;
            resp_rd_ptr   <= '0;
            resp_count    <= '0;

            state_q             <= ST_IDLE;
            clk_cnt             <= 16'd0;
            bit_idx             <= 3'd7;
            cmd_reg             <= 32'h0;
            tx_shift_reg        <= 8'h0;
            tx_tbit             <= 1'b1;
            tx_bytes_rem        <= 12'd0;
            tx_byte_idx         <= 2'd0;
            sending_pec         <= 1'b0;
            rx_shift_reg        <= 8'h0;
            rx_tbit_val         <= 1'b0;
            rx_bytes_rem        <= 12'd0;
            rx_bytes_rcvd       <= 12'd0;
            rx_byte_idx         <= 2'd0;
            rx_word_acc         <= 32'h0;
            receiving_pec       <= 1'b0;
            pec_crc             <= 8'h0;
            nack_err            <= 1'b0;
            resp_pushed_for_cmd <= 1'b0;

            i3c_scl_o           <= 1'b1;
            i3c_sda_o           <= 1'b1;
            i3c_sda_oe_o        <= 1'b0;
        end else if (soft_rst) begin
            cmd_wr_ptr    <= '0;
            cmd_rd_ptr    <= '0;
            cmd_count     <= '0;
            wr_wr_ptr     <= '0;
            wr_rd_ptr     <= '0;
            wr_count      <= '0;
            rd_wr_ptr     <= '0;
            rd_rd_ptr     <= '0;
            rd_count      <= '0;
            resp_wr_ptr   <= '0;
            resp_rd_ptr   <= '0;
            resp_count    <= '0;
            state_q       <= ST_IDLE;
            clk_cnt       <= 16'd0;
            i3c_scl_o     <= 1'b1;
            i3c_sda_o     <= 1'b1;
            i3c_sda_oe_o  <= 1'b0;
        end else begin
            // -----------------------------------------------------------------
            // MMIO Register Writes
            // -----------------------------------------------------------------
            if (reg_we_i) begin
                case (reg_addr_i)
                    REG_CR:            reg_cr       <= reg_wdata_i;
                    REG_ADDRESS:       reg_address  <= reg_wdata_i;
                    REG_INTR_RE:       reg_intr_re  <= reg_wdata_i;
                    REG_INTR_FE:       reg_intr_fe  <= reg_wdata_i;
                    REG_SCL_HIGH_TIME: if (reg_wdata_i[15:0] >= 16'd4) reg_scl_high <= reg_wdata_i[15:0];
                    REG_SCL_LOW_TIME:  if (reg_wdata_i[15:0] >= 16'd4) reg_scl_low  <= reg_wdata_i[15:0];
                    default: ;
                endcase
            end

            // -----------------------------------------------------------------
            // FIFO Pointer & Count Updates
            // -----------------------------------------------------------------
            if (mmio_cmd_push) begin
                cmd_wr_ptr <= cmd_wr_ptr + 1'b1;
            end
            if (fsm_cmd_pop) begin
                cmd_rd_ptr <= cmd_rd_ptr + 1'b1;
            end
            case ({mmio_cmd_push, fsm_cmd_pop})
                2'b10: cmd_count <= cmd_count + 1'b1;
                2'b01: cmd_count <= cmd_count - 1'b1;
                default: ;
            endcase

            if (mmio_wr_push) begin
                wr_wr_ptr <= wr_wr_ptr + 1'b1;
            end
            if (fsm_wr_pop) begin
                wr_rd_ptr <= wr_rd_ptr + 1'b1;
            end
            case ({mmio_wr_push, fsm_wr_pop})
                2'b10: wr_count <= wr_count + 1'b1;
                2'b01: wr_count <= wr_count - 1'b1;
                default: ;
            endcase

            if (fsm_rd_push && !rd_fifo_full) begin
                rd_wr_ptr <= rd_wr_ptr + 1'b1;
            end
            if (mmio_rd_pop) begin
                rd_rd_ptr <= rd_rd_ptr + 1'b1;
            end
            case ({fsm_rd_push && !rd_fifo_full, mmio_rd_pop})
                2'b10: rd_count <= rd_count + 1'b1;
                2'b01: rd_count <= rd_count - 1'b1;
                default: ;
            endcase

            if (fsm_resp_push && !resp_fifo_full) begin
                resp_wr_ptr <= resp_wr_ptr + 1'b1;
            end
            if (mmio_resp_pop) begin
                resp_rd_ptr <= resp_rd_ptr + 1'b1;
            end
            case ({fsm_resp_push && !resp_fifo_full, mmio_resp_pop})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: ;
            endcase

            // -----------------------------------------------------------------
            // I3C Master Protocol FSM
            // -----------------------------------------------------------------
            unique case (state_q)
                ST_IDLE: begin
                    i3c_scl_o    <= 1'b1;
                    i3c_sda_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b0;
                    clk_cnt      <= 16'd0;

                    if (!cmd_fifo_empty) begin
                        logic [31:0] c;
                        c = cmd_fifo_mem[cmd_rd_ptr];
                        cmd_reg             <= c;
                        tx_bytes_rem        <= c[27:16];
                        rx_bytes_rem        <= c[27:16];
                        rx_bytes_rcvd       <= 12'd0;
                        tx_byte_idx         <= 2'd0;
                        rx_byte_idx         <= 2'd0;
                        rx_word_acc         <= 32'h0;
                        sending_pec         <= 1'b0;
                        receiving_pec       <= 1'b0;
                        pec_crc             <= next_crc8(8'h00, {c[15:9], c[8]});
                        nack_err            <= 1'b0;
                        resp_pushed_for_cmd <= 1'b0;
                        state_q             <= ST_START;
                    end
                end

                // START Condition (S):
                // Phase 0 (0 .. reg_scl_high-1): SCL=1, SDA=1
                // Phase 1 (reg_scl_high .. 2*reg_scl_high-1): SCL=1, SDA=0
                ST_START: begin
                    i3c_scl_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b1;
                    if (clk_cnt < reg_scl_high) begin
                        i3c_sda_o <= 1'b1;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else if (clk_cnt < (reg_scl_high << 1) - 16'd1) begin
                        i3c_sda_o <= 1'b0;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o    <= 1'b0;
                        i3c_sda_o    <= 1'b0;
                        clk_cnt      <= 16'd0;
                        tx_shift_reg <= {cmd_target_addr, cmd_rw};
                        bit_idx      <= 3'd7;
                        state_q      <= ST_ADDR_BIT_LOW;
                    end
                end

                // Prepare for Repeated START (Sr) while SCL=0: bring SDA=1
                ST_RSTART_PREP: begin
                    i3c_scl_o    <= 1'b0;
                    i3c_sda_oe_o <= 1'b1;
                    if (clk_cnt == 16'd1) begin
                        i3c_sda_o <= 1'b1;
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b1;
                        i3c_sda_o <= 1'b1;
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_RSTART;
                    end
                end

                // Repeated START (Sr): while SCL=1, pull SDA: 1 -> 0
                ST_RSTART: begin
                    i3c_scl_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b1;
                    if (clk_cnt < reg_scl_high) begin
                        i3c_sda_o <= 1'b1;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else if (clk_cnt < (reg_scl_high << 1) - 16'd1) begin
                        i3c_sda_o <= 1'b0;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o    <= 1'b0;
                        i3c_sda_o    <= 1'b0;
                        clk_cnt      <= 16'd0;
                        tx_shift_reg <= {cmd_target_addr, cmd_rw};
                        bit_idx      <= 3'd7;
                        state_q      <= ST_ADDR_BIT_LOW;
                    end
                end

                // Shift 8 bits of {target_addr[6:0], rw}
                ST_ADDR_BIT_LOW: begin
                    i3c_scl_o <= 1'b0;
                    if (clk_cnt == 16'd1) begin
                        i3c_sda_o    <= tx_shift_reg[bit_idx];
                        i3c_sda_oe_o <= 1'b1;
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b1;
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_ADDR_BIT_HIGH;
                    end
                end

                ST_ADDR_BIT_HIGH: begin
                    i3c_scl_o <= 1'b1;
                    if (clk_cnt < reg_scl_high - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b0;
                        clk_cnt   <= 16'd0;
                        if (bit_idx == 3'd0) begin
                            state_q <= ST_ADDR_ACK_LOW;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state_q <= ST_ADDR_BIT_LOW;
                        end
                    end
                end

                // 9th bit of Address byte: release SDA and sample Target ACK
                ST_ADDR_ACK_LOW: begin
                    i3c_scl_o <= 1'b0;
                    if (clk_cnt == 16'd1) begin
                        i3c_sda_o    <= 1'b1;
                        i3c_sda_oe_o <= 1'b0;
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        nack_err  <= i3c_sda_i; // 0 = ACK, 1 = NACK
                        i3c_scl_o <= 1'b1;
                        // MIPI I3C Spec 5.1.2.3.1 (AckHandoff): For Write-direction ACKs (and
                        // 0x7E broadcast ACKs), Target releases SDA on SCL rising edge and
                        // Controller takes over driving SDA low for the remainder of SCL high
                        // so that SDA does not glitch high (which would look like a STOP).
                        if (!i3c_sda_i && (!cmd_rw || cmd_target_addr == 7'h7E)) begin
                            i3c_sda_o    <= 1'b0;
                            i3c_sda_oe_o <= 1'b1;
                        end
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_ADDR_ACK_HIGH;
                    end
                end

                ST_ADDR_ACK_HIGH: begin
                    i3c_scl_o <= 1'b1;
                    if (clk_cnt < reg_scl_high - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b0;
                        clk_cnt   <= 16'd0;
                        if (nack_err) begin
                            state_q <= ST_STOP_LOW;
                        end else if (!cmd_rw) begin
                            // Write Transfer
                            if (tx_bytes_rem > 12'd0) begin
                                tx_shift_reg <= wr_front_byte;
                                tx_tbit      <= ~(^wr_front_byte);
                                pec_crc      <= next_crc8(pec_crc, wr_front_byte);
                                tx_bytes_rem <= tx_bytes_rem - 12'd1;
                                tx_byte_idx  <= tx_byte_idx + 2'd1;
                                bit_idx      <= 3'd7;
                                state_q      <= ST_TX_BIT_LOW;
                            end else if (cmd_pec) begin
                                sending_pec  <= 1'b1;
                                tx_shift_reg <= pec_crc;
                                tx_tbit      <= ~(^pec_crc);
                                bit_idx      <= 3'd7;
                                state_q      <= ST_TX_BIT_LOW;
                            end else begin
                                state_q <= cmd_no_rpt_start ? ST_STOP_LOW : ST_HOLD_SR;
                            end
                        end else begin
                            // Read Transfer
                            if (rx_bytes_rem > 12'd0) begin
                                bit_idx <= 3'd7;
                                state_q <= ST_RX_BIT_LOW;
                            end else if (cmd_pec) begin
                                receiving_pec <= 1'b1;
                                bit_idx       <= 3'd7;
                                state_q       <= ST_RX_BIT_LOW;
                            end else begin
                                state_q <= cmd_no_rpt_start ? ST_STOP_LOW : ST_HOLD_SR;
                            end
                        end
                    end
                end

                // Transmit 8 data bits MSB-first
                ST_TX_BIT_LOW: begin
                    i3c_scl_o <= 1'b0;
                    if (clk_cnt == 16'd1) begin
                        i3c_sda_o    <= tx_shift_reg[bit_idx];
                        i3c_sda_oe_o <= 1'b1;
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b1;
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_TX_BIT_HIGH;
                    end
                end

                ST_TX_BIT_HIGH: begin
                    i3c_scl_o <= 1'b1;
                    if (clk_cnt < reg_scl_high - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b0;
                        clk_cnt   <= 16'd0;
                        if (bit_idx == 3'd0) begin
                            state_q <= ST_TX_TBIT_LOW;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state_q <= ST_TX_BIT_LOW;
                        end
                    end
                end

                // 9th bit of Write byte: Odd-parity T-bit (or ACK in I2C mode)
                ST_TX_TBIT_LOW: begin
                    i3c_scl_o <= 1'b0;
                    if (clk_cnt == 16'd1) begin
                        if (cmd_type == 4'd0) begin
                            i3c_sda_o    <= 1'b1;
                            i3c_sda_oe_o <= 1'b0;
                        end else begin
                            i3c_sda_o    <= tx_tbit;
                            i3c_sda_oe_o <= 1'b1;
                        end
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b1;
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_TX_TBIT_HIGH;
                    end
                end

                ST_TX_TBIT_HIGH: begin
                    i3c_scl_o <= 1'b1;
                    if (clk_cnt < reg_scl_high - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b0;
                        clk_cnt   <= 16'd0;
                        if (tx_bytes_rem > 12'd0) begin
                            tx_shift_reg <= wr_front_byte;
                            tx_tbit      <= ~(^wr_front_byte);
                            pec_crc      <= next_crc8(pec_crc, wr_front_byte);
                            tx_bytes_rem <= tx_bytes_rem - 12'd1;
                            tx_byte_idx  <= tx_byte_idx + 2'd1;
                            bit_idx      <= 3'd7;
                            state_q      <= ST_TX_BIT_LOW;
                        end else if (cmd_pec && !sending_pec) begin
                            sending_pec  <= 1'b1;
                            tx_shift_reg <= pec_crc;
                            tx_tbit      <= ~(^pec_crc);
                            bit_idx      <= 3'd7;
                            state_q      <= ST_TX_BIT_LOW;
                        end else begin
                            state_q <= cmd_no_rpt_start ? ST_STOP_LOW : ST_HOLD_SR;
                        end
                    end
                end

                // Receive 8 data bits MSB-first from Target
                ST_RX_BIT_LOW: begin
                    i3c_scl_o    <= 1'b0;
                    i3c_sda_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b0;
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        rx_shift_reg[bit_idx] <= i3c_sda_i;
                        i3c_scl_o             <= 1'b1;
                        clk_cnt               <= 16'd0;
                        state_q               <= ST_RX_BIT_HIGH;
                    end
                end

                ST_RX_BIT_HIGH: begin
                    i3c_scl_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b0;
                    if (clk_cnt < reg_scl_high - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b0;
                        clk_cnt   <= 16'd0;
                        if (bit_idx == 3'd0) begin
                            if (!receiving_pec) begin
                                logic [31:0] new_acc;
                                new_acc = rx_word_acc;
                                unique case (rx_byte_idx)
                                    2'd0: new_acc = {rx_shift_reg, 24'h0};
                                    2'd1: new_acc[23:16] = rx_shift_reg;
                                    2'd2: new_acc[15:8]  = rx_shift_reg;
                                    2'd3: new_acc[7:0]   = rx_shift_reg;
                                endcase
                                rx_word_acc   <= new_acc;
                                rx_byte_idx   <= rx_byte_idx + 2'd1;
                                rx_bytes_rcvd <= rx_bytes_rcvd + 12'd1;
                                rx_bytes_rem  <= rx_bytes_rem - 12'd1;
                                pec_crc       <= next_crc8(pec_crc, rx_shift_reg);
                            end
                            state_q <= ST_RX_TBIT_LOW;
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                            state_q <= ST_RX_BIT_LOW;
                        end
                    end
                end

                // 9th bit of Read byte: sample Target T-bit
                ST_RX_TBIT_LOW: begin
                    i3c_scl_o    <= 1'b0;
                    i3c_sda_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b0;
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        rx_tbit_val <= i3c_sda_i;
                        i3c_scl_o   <= 1'b1;
                        // MIPI I3C Spec 5.1.2.3.4 (TReadEnd): When Target signals T=0 to end a
                        // read, Target releases SDA on SCL rising edge and Controller takes over
                        // driving SDA low for the remainder of SCL high.
                        if (i3c_sda_i == 1'b0) begin
                            i3c_sda_o    <= 1'b0;
                            i3c_sda_oe_o <= 1'b1;
                        end
                        clk_cnt     <= 16'd0;
                        state_q     <= ST_RX_TBIT_HIGH;
                    end
                end

                ST_RX_TBIT_HIGH: begin
                    i3c_scl_o <= 1'b1;
                    if (rx_tbit_val == 1'b0) begin
                        // Target signaled end of read (TReadEnd)
                        if (clk_cnt < reg_scl_high - 16'd1) begin
                            clk_cnt <= clk_cnt + 16'd1;
                        end else begin
                            i3c_scl_o <= 1'b0;
                            clk_cnt   <= 16'd0;
                            state_q   <= cmd_no_rpt_start ? ST_STOP_LOW : ST_HOLD_SR;
                        end
                    end else if (rx_bytes_rem == 12'd0 && (!cmd_pec || receiving_pec)) begin
                        // Target wants to continue (TReadCont = 1), but Controller has
                        // received all requested bytes -> pull SDA low while SCL=1 to abort!
                        if (clk_cnt == 16'd4) begin
                            i3c_sda_o    <= 1'b0;
                            i3c_sda_oe_o <= 1'b1;
                        end
                        if (clk_cnt < reg_scl_high + 16'd4) begin
                            clk_cnt <= clk_cnt + 16'd1;
                        end else begin
                            i3c_scl_o <= 1'b0;
                            clk_cnt   <= 16'd0;
                            state_q   <= cmd_no_rpt_start ? ST_STOP_LOW : ST_HOLD_SR;
                        end
                    end else begin
                        // Continue reading next byte (either payload or trailing PEC byte)
                        i3c_sda_oe_o <= 1'b0;
                        if (clk_cnt < reg_scl_high - 16'd1) begin
                            clk_cnt <= clk_cnt + 16'd1;
                        end else begin
                            i3c_scl_o <= 1'b0;
                            clk_cnt   <= 16'd0;
                            bit_idx   <= 3'd7;
                            if (rx_bytes_rem == 12'd0 && cmd_pec && !receiving_pec) begin
                                receiving_pec <= 1'b1;
                            end
                            state_q <= ST_RX_BIT_LOW;
                        end
                    end
                end

                // STOP Condition (P):
                // ST_STOP_LOW: while SCL=0, drive SDA=0
                // ST_STOP_HIGH: raise SCL=1, hold SDA=0 for reg_scl_high cycles, then raise SDA=1
                ST_STOP_LOW: begin
                    i3c_scl_o <= 1'b0;
                    if (clk_cnt == 16'd1) begin
                        i3c_sda_o    <= 1'b0;
                        i3c_sda_oe_o <= 1'b1;
                    end
                    if (clk_cnt < reg_scl_low - 16'd1) begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end else begin
                        i3c_scl_o <= 1'b1;
                        clk_cnt   <= 16'd0;
                        state_q   <= ST_STOP_HIGH;
                    end
                end

                ST_STOP_HIGH: begin
                    i3c_scl_o    <= 1'b1;
                    i3c_sda_oe_o <= 1'b1;
                    if (clk_cnt < reg_scl_high) begin
                        i3c_sda_o <= 1'b0;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else if (clk_cnt < (reg_scl_high << 1) - 16'd1) begin
                        i3c_sda_o <= 1'b1;
                        clk_cnt   <= clk_cnt + 16'd1;
                    end else begin
                        i3c_sda_o    <= 1'b1;
                        i3c_sda_oe_o <= 1'b0;
                        clk_cnt      <= 16'd0;
                        state_q      <= ST_IDLE;
                    end
                end

                // Hold SCL=0 between chained commands (when cmd_no_rpt_start == 0)
                ST_HOLD_SR: begin
                    i3c_scl_o           <= 1'b0;
                    resp_pushed_for_cmd <= 1'b1;
                    clk_cnt             <= 16'd0;
                    if (!cmd_fifo_empty) begin
                        logic [31:0] c;
                        c = cmd_fifo_mem[cmd_rd_ptr];
                        cmd_reg             <= c;
                        tx_bytes_rem        <= c[27:16];
                        rx_bytes_rem        <= c[27:16];
                        rx_bytes_rcvd       <= 12'd0;
                        tx_byte_idx         <= 2'd0;
                        rx_byte_idx         <= 2'd0;
                        rx_word_acc         <= 32'h0;
                        sending_pec         <= 1'b0;
                        receiving_pec       <= 1'b0;
                        pec_crc             <= next_crc8(8'h00, {c[15:9], c[8]});
                        nack_err            <= 1'b0;
                        resp_pushed_for_cmd <= 1'b0;
                        state_q             <= ST_RSTART_PREP;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational FIFO Push/Pop Triggers from FSM
    // -------------------------------------------------------------------------
    always_comb begin
        fsm_cmd_pop    = 1'b0;
        fsm_wr_pop     = 1'b0;
        fsm_rd_push    = 1'b0;
        fsm_rd_wdata   = 32'h0;
        fsm_resp_push  = 1'b0;
        fsm_resp_wdata = {4'b0, (cmd_rw ? rx_bytes_rcvd : cmd_byte_count), 7'b0, nack_err, 4'b0, cmd_tid};

        if (state_q == ST_IDLE && !cmd_fifo_empty) begin
            fsm_cmd_pop = 1'b1;
        end else if (state_q == ST_HOLD_SR && !cmd_fifo_empty) begin
            fsm_cmd_pop = 1'b1;
        end

        // Pop 32-bit word from WR_FIFO when 4th byte of word is consumed or at end of write
        if (state_q == ST_ADDR_ACK_HIGH && (clk_cnt == reg_scl_high - 16'd1) && !nack_err && !cmd_rw && (tx_bytes_rem > 12'd0)) begin
            if (tx_byte_idx == 2'd3 || tx_bytes_rem == 12'd1) begin
                fsm_wr_pop = 1'b1;
            end
        end else if (state_q == ST_TX_TBIT_HIGH && (clk_cnt == reg_scl_high - 16'd1) && (tx_bytes_rem > 12'd0)) begin
            if (tx_byte_idx == 2'd3 || tx_bytes_rem == 12'd1) begin
                fsm_wr_pop = 1'b1;
            end
        end

        // Push 32-bit word to RD_FIFO when 4th byte of word is received or last requested byte is received
        if (state_q == ST_RX_BIT_HIGH && (clk_cnt == reg_scl_high - 16'd1) && (bit_idx == 3'd0) && !receiving_pec) begin
            logic [31:0] new_acc;
            new_acc = rx_word_acc;
            unique case (rx_byte_idx)
                2'd0: new_acc = {rx_shift_reg, 24'h0};
                2'd1: new_acc[23:16] = rx_shift_reg;
                2'd2: new_acc[15:8]  = rx_shift_reg;
                2'd3: new_acc[7:0]   = rx_shift_reg;
            endcase
            if (rx_byte_idx == 2'd3 || rx_bytes_rem == 12'd1) begin
                fsm_rd_push  = 1'b1;
                fsm_rd_wdata = new_acc;
            end
        end else if (state_q == ST_RX_TBIT_HIGH && (rx_tbit_val == 1'b0) && (clk_cnt == 16'd0) && (rx_byte_idx != 2'd0) && (rx_bytes_rem > 12'd0) && !receiving_pec) begin
            // Target ended read early with partial word in rx_word_acc
            fsm_rd_push  = 1'b1;
            fsm_rd_wdata = rx_word_acc;
        end

        // Push completion response to RESP_STATUS_FIFO
        if (state_q == ST_STOP_HIGH && (clk_cnt == (reg_scl_high << 1) - 16'd1) && !resp_pushed_for_cmd) begin
            fsm_resp_push = 1'b1;
        end else if (state_q == ST_HOLD_SR && !resp_pushed_for_cmd) begin
            fsm_resp_push = 1'b1;
        end
    end

endmodule
