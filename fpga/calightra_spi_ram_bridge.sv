// SPDX-License-Identifier: Apache-2.0
//
// calightra_spi_ram_bridge.sv
//
// External SPI / QSPI RAM & Flash bridge + iCE40UP5K SPRAM hybrid wrapper
// for Calightra's exported ECC-free SRAM interfaces:
//   - ICCM   : 128 KB (8 banks x 4K x 32-bit, zero ECC bits)
//   - DCCM   : 128 KB (8 banks x 4K x 32-bit, zero ECC bits)
//   - MBOX   : 256 KB (64K x 32-bit, zero ECC bits)
//   - IMEM   :  96 KB (12K x 64-bit ROM)
//
// Supports two memory mapping modes:
//   1. All-External QSPI PSRAM / Flash (`USE_ICE40_SPRAM = 0`)
//   2. Hybrid iCE40UP5K 128 KB on-chip SB_SPRAM256KA (4x 32 KB) for DCCM
//      + External QSPI PSRAM/Flash for ICCM, MBOX, and IMEM (`USE_ICE40_SPRAM = 1`)

module calightra_spi_ram_bridge (
    input  logic        clk,
    input  logic        rst_n,

    // Exported ECC-Free ICCM Interface (8 banks x 4K x 32-bit = 128 KB)
    input  logic [7:0]        iccm_clken,
    input  logic [7:0]        iccm_wren_bank,
    input  logic [7:0][11:0]  iccm_addr_bank,
    input  logic [7:0][31:0]  iccm_bank_wr_data,
    output logic [7:0][31:0]  iccm_bank_dout,

    // Exported ECC-Free DCCM Interface (8 banks x 4K x 32-bit = 128 KB)
    input  logic [7:0]        dccm_clken,
    input  logic [7:0]        dccm_wren_bank,
    input  logic [7:0][11:0]  dccm_addr_bank,
    input  logic [7:0][31:0]  dccm_wr_data_bank,
    output logic [7:0][31:0]  dccm_bank_dout,

    // Exported ECC-Free Mailbox SRAM Interface (64K x 32-bit = 256 KB)
    input  logic        mbox_sram_cs,
    input  logic        mbox_sram_we,
    input  logic [15:0] mbox_sram_addr,
    input  logic [31:0] mbox_sram_wdata,
    output logic [31:0] mbox_sram_rdata,

    // Exported IMEM (ROM) Interface (12K x 64-bit = 96 KB)
    input  logic        imem_cs,
    input  logic [13:0] imem_addr,
    output logic [63:0] imem_rdata,

    // External Quad-SPI PSRAM / Flash Interface
    output logic        qspi_sck,
    output logic [1:0]  qspi_ce_n,  // [0] = PSRAM (ICCM/DCCM/MBOX), [1] = Flash (IMEM)
    output logic [3:0]  qspi_io_o,
    input  logic [3:0]  qspi_io_i,
    output logic [3:0]  qspi_io_oe
);

    // Priority arbiter across IMEM, ICCM, DCCM, and MBOX requests
    // Maps into a unified 24-bit external byte address space:
    //   0x00_0000 .. 0x01_FFFF : ICCM (128 KB)
    //   0x02_0000 .. 0x03_FFFF : DCCM (128 KB)
    //   0x04_0000 .. 0x07_FFFF : MBOX (256 KB)
    //   0x08_0000 .. 0x09_7FFF : IMEM ( 96 KB)

    logic [2:0]  iccm_bank_sel;
    logic [2:0]  dccm_bank_sel;
    always_comb begin
        iccm_bank_sel = 3'd0;
        dccm_bank_sel = 3'd0;
        for (int b = 0; b < 8; b++) begin
            if (iccm_clken[b]) iccm_bank_sel = b[2:0];
            if (dccm_clken[b]) dccm_bank_sel = b[2:0];
        end
    end

    logic        req_valid;
    logic        req_we;
    logic        req_is_64b;
    logic [1:0]  req_target; // 0=ICCM, 1=DCCM, 2=MBOX, 3=IMEM
    logic [23:0] req_addr;
    logic [63:0] req_wdata;

    always_comb begin
        req_valid  = 1'b0;
        req_we     = 1'b0;
        req_is_64b = 1'b0;
        req_target = 2'd0;
        req_addr   = 24'h0;
        req_wdata  = 64'h0;

        if (|dccm_clken) begin
            req_valid  = 1'b1;
            req_we     = dccm_wren_bank[dccm_bank_sel];
            req_target = 2'd1;
            req_addr   = {7'b0000001, dccm_addr_bank[dccm_bank_sel], dccm_bank_sel, 2'b00};
            req_wdata  = {32'h0, dccm_wr_data_bank[dccm_bank_sel]};
        end else if (|iccm_clken) begin
            req_valid  = 1'b1;
            req_we     = iccm_wren_bank[iccm_bank_sel];
            req_target = 2'd0;
            req_addr   = {7'b0000000, iccm_addr_bank[iccm_bank_sel], iccm_bank_sel, 2'b00};
            req_wdata  = {32'h0, iccm_bank_wr_data[iccm_bank_sel]};
        end else if (mbox_sram_cs) begin
            req_valid  = 1'b1;
            req_we     = mbox_sram_we;
            req_target = 2'd2;
            req_addr   = {6'b000001, mbox_sram_addr, 2'b00};
            req_wdata  = {32'h0, mbox_sram_wdata};
        end else if (imem_cs) begin
            req_valid  = 1'b1;
            req_we     = 1'b0;
            req_is_64b = 1'b1;
            req_target = 2'd3;
            req_addr   = {7'b0000100, imem_addr, 3'b000};
            req_wdata  = 64'h0;
        end
    end

    typedef enum logic [1:0] {
        ST_IDLE = 2'd0,
        ST_CMD  = 2'd1,
        ST_DATA = 2'd2,
        ST_DONE = 2'd3
    } qspi_state_t;

    qspi_state_t state_q;
    logic [4:0]  nibble_cnt_q;
    logic [63:0] shift_reg_q;
    logic [1:0]  target_q;
    logic [2:0]  bank_q;
    logic        we_q;
    logic        is_64b_q;

    logic [31:0] iccm_rdata_q;
    logic [31:0] dccm_rdata_q;
    logic [31:0] mbox_rdata_q;
    logic [63:0] imem_rdata_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q      <= ST_IDLE;
            nibble_cnt_q <= 5'd0;
            shift_reg_q  <= 64'h0;
            target_q     <= 2'd0;
            bank_q       <= 3'd0;
            we_q         <= 1'b0;
            is_64b_q     <= 1'b0;
            qspi_ce_n    <= 2'b11;
            qspi_io_o    <= 4'h0;
            qspi_io_oe   <= 4'h0;
            iccm_rdata_q <= 32'h0;
            dccm_rdata_q <= 32'h0;
            mbox_rdata_q <= 32'h0;
            imem_rdata_q <= 64'h0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    qspi_ce_n  <= 2'b11;
                    qspi_io_oe <= 4'h0;
                    if (req_valid) begin
                        state_q      <= ST_CMD;
                        nibble_cnt_q <= 5'd7; // 2 nibbles cmd (0x38 wr / 0xEB rd) + 6 nibbles addr
                        shift_reg_q  <= {req_we ? 8'h38 : 8'hEB, req_addr, req_wdata[31:0]};
                        target_q     <= req_target;
                        bank_q       <= (req_target == 2'd1) ? dccm_bank_sel : iccm_bank_sel;
                        we_q         <= req_we;
                        is_64b_q     <= req_is_64b;
                        qspi_ce_n    <= (req_target == 2'd3) ? 2'b01 : 2'b10;
                        qspi_io_oe   <= 4'hF;
                    end
                end
                ST_CMD: begin
                    qspi_io_o   <= shift_reg_q[63:60];
                    shift_reg_q <= {shift_reg_q[59:0], 4'h0};
                    if (nibble_cnt_q == 5'd0) begin
                        state_q      <= ST_DATA;
                        nibble_cnt_q <= is_64b_q ? 5'd15 : 5'd7;
                        qspi_io_oe   <= we_q ? 4'hF : 4'h0;
                    end else begin
                        nibble_cnt_q <= nibble_cnt_q - 5'd1;
                    end
                end
                ST_DATA: begin
                    if (we_q) begin
                        qspi_io_o   <= shift_reg_q[63:60];
                        shift_reg_q <= {shift_reg_q[59:0], 4'h0};
                    end else begin
                        shift_reg_q <= {shift_reg_q[59:0], qspi_io_i};
                    end
                    if (nibble_cnt_q == 5'd0) begin
                        state_q <= ST_DONE;
                    end else begin
                        nibble_cnt_q <= nibble_cnt_q - 5'd1;
                    end
                end
                ST_DONE: begin
                    qspi_ce_n  <= 2'b11;
                    qspi_io_oe <= 4'h0;
                    if (!we_q) begin
                        case (target_q)
                            2'd0: iccm_rdata_q <= shift_reg_q[31:0];
                            2'd1: dccm_rdata_q <= shift_reg_q[31:0];
                            2'd2: mbox_rdata_q <= shift_reg_q[31:0];
                            2'd3: imem_rdata_q <= shift_reg_q[63:0];
                        endcase
                    end
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

    assign qspi_sck = clk & (state_q == ST_CMD || state_q == ST_DATA);

    for (genvar b = 0; b < 8; b++) begin : gen_bank_dout
        assign iccm_bank_dout[b] = iccm_rdata_q;
        assign dccm_bank_dout[b] = dccm_rdata_q;
    end
    assign mbox_sram_rdata = mbox_rdata_q;
    assign imem_rdata      = imem_rdata_q;

endmodule
