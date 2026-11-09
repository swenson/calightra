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
// Description:
//   Open-source, cleanly synthesizable AXI4 Crossbar / Interconnect for
//   Caliptra Subsystem (caliptra-ss).
//
//   Connects 5 AXI4 Managers:
//     M0: MCU IFU       (64-bit DW)
//     M1: MCU LSU       (64-bit DW)
//     M2: Caliptra DMA  (32-bit DW)
//     M3: External SoC  (32-bit DW)
//     M4: MCU SB        (64-bit DW)
//
//   To 7 AXI4 Subordinates:
//     S0: MCU ROM       (64-bit DW) @ 0x8000_0000 .. 0x80FF_FFFF
//     S1: MCI           (32-bit DW) @ 0x2100_0000 .. 0x21FF_FFFF
//     S2: Caliptra Core (32-bit DW) @ 0xA000_0000 .. 0xA00F_FFFF (or 0x3000_0000)
//     S3: Fuse/OTP Ctrl (32-bit DW) @ 0x7000_0000 .. 0x7000_03FF, 0x7000_0800 .. 0x7000_FFFF
//     S4: LC Ctrl       (32-bit DW) @ 0x7000_0400 .. 0x7000_07FF
//     S5: I3C Core      (32-bit DW) @ 0x2000_0000 .. 0x2000_FFFF
//     S6: SoC SRAM      (32-bit DW) @ 0xB000_0000 .. 0xB0FF_FFFF (or 0x1000_0000)

module calightra_ss_axi_xbar
    import axi_pkg::*;
    import axi_struct_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    // M0: MCU IFU (64-bit)
    axi_if.r_sub m0_ifu_r_sub,
    axi_if.w_sub m0_ifu_w_sub,

    // M1: MCU LSU (64-bit)
    axi_if.r_sub m1_lsu_r_sub,
    axi_if.w_sub m1_lsu_w_sub,

    // M2: Caliptra Core AXI DMA (32-bit)
    axi_if.r_sub m2_dma_r_sub,
    axi_if.w_sub m2_dma_w_sub,

    // M3: External SoC / Host BFM (32-bit)
    axi_if.r_sub m3_soc_r_sub,
    axi_if.w_sub m3_soc_w_sub,

    // M4: MCU System Bus (64-bit)
    axi_if.r_sub m4_sb_r_sub,
    axi_if.w_sub m4_sb_w_sub,

    // S0: MCU ROM (64-bit)
    axi_if.r_mgr s0_rom_r_mgr,
    axi_if.w_mgr s0_rom_w_mgr,

    // S1: MCI (32-bit)
    axi_if.r_mgr s1_mci_r_mgr,
    axi_if.w_mgr s1_mci_w_mgr,

    // S2: Caliptra Core SoC IFC (32-bit)
    axi_if.r_mgr s2_cptra_r_mgr,
    axi_if.w_mgr s2_cptra_w_mgr,

    // S3: OTP / Fuse Controller (32-bit struct)
    output axi_wr_req_t s3_otp_wr_req,
    input  axi_wr_rsp_t s3_otp_wr_rsp,
    output axi_rd_req_t s3_otp_rd_req,
    input  axi_rd_rsp_t s3_otp_rd_rsp,

    // S4: Lifecycle Controller (32-bit struct)
    output axi_wr_req_t s4_lc_wr_req,
    input  axi_wr_rsp_t s4_lc_wr_rsp,
    output axi_rd_req_t s4_lc_rd_req,
    input  axi_rd_rsp_t s4_lc_rd_rsp,

    // S5: I3C Core (32-bit)
    axi_if.r_mgr s5_i3c_r_mgr,
    axi_if.w_mgr s5_i3c_w_mgr,

    // S6: External Staging / SoC SRAM (32-bit)
    axi_if.r_mgr s6_sram_r_mgr,
    axi_if.w_mgr s6_sram_w_mgr
);

    // Subordinate IDs
    localparam logic [2:0] SUB_ROM   = 3'd0;
    localparam logic [2:0] SUB_MCI   = 3'd1;
    localparam logic [2:0] SUB_CPTRA = 3'd2;
    localparam logic [2:0] SUB_OTP   = 3'd3;
    localparam logic [2:0] SUB_LC    = 3'd4;
    localparam logic [2:0] SUB_I3C   = 3'd5;
    localparam logic [2:0] SUB_SRAM  = 3'd6;
    localparam logic [2:0] SUB_ERR   = 3'd7;

    function automatic logic [2:0] decode_addr(input logic [31:0] addr);
        if (addr[31:24] == 8'h80) begin
            return SUB_ROM;
        end else if (addr[31:24] == 8'h21) begin
            return SUB_MCI;
        end else if (addr[31:20] == 12'hA00 || addr[31:20] == 12'h300) begin
            return SUB_CPTRA;
        end else if (addr[31:16] == 16'h7000 && addr[15:10] == 6'b000001) begin
            return SUB_LC;
        end else if (addr[31:16] == 16'h7000) begin
            return SUB_OTP;
        end else if (addr[31:16] == 16'h2000) begin
            return SUB_I3C;
        end else if (addr[31:24] == 8'hB0 || addr[31:24] == 8'h10) begin
            return SUB_SRAM;
        end else begin
            return SUB_ERR;
        end
    endfunction

    // =========================================================================
    // READ CHANNEL CROSSBAR & 64-to-32 DOWNSIZER
    // =========================================================================
    typedef enum logic [1:0] {
        RD_IDLE    = 2'd0,
        RD_AR_SEND = 2'd1,
        RD_R_WAIT  = 2'd2,
        RD_ERR     = 2'd3
    } rd_state_e;

    rd_state_e   rd_state;
    logic [2:0]  rd_mgr_sel;
    logic [2:0]  rd_sub_sel;
    logic        rd_is_64b_mgr;
    logic        rd_is_64b_sub;
    logic        rd_split_64_to_32;
    logic        rd_split_phase;
    logic [31:0] rd_low_word;
    logic [1:0]  rd_low_resp;

    logic [31:0] rd_addr;
    logic [1:0]  rd_burst;
    logic [2:0]  rd_size;
    logic [7:0]  rd_len;
    logic [31:0] rd_user;
    logic [7:0]  rd_id;
    logic        rd_lock;

    // Manager AR request vector
    logic [4:0]  m_arvalid;
    logic [31:0] m_araddr  [5];
    logic [1:0]  m_arburst [5];
    logic [2:0]  m_arsize  [5];
    logic [7:0]  m_arlen   [5];
    logic [31:0] m_aruser  [5];
    logic [7:0]  m_arid    [5];
    logic        m_arlock  [5];
    logic [4:0]  m_rready;

    assign m_arvalid[0] = m0_ifu_r_sub.arvalid;
    assign m_araddr [0] = m0_ifu_r_sub.araddr;
    assign m_arburst[0] = m0_ifu_r_sub.arburst;
    assign m_arsize [0] = m0_ifu_r_sub.arsize;
    assign m_arlen  [0] = m0_ifu_r_sub.arlen;
    assign m_aruser [0] = m0_ifu_r_sub.aruser;
    assign m_arid   [0] = m0_ifu_r_sub.arid;
    assign m_arlock [0] = m0_ifu_r_sub.arlock;
    assign m_rready [0] = m0_ifu_r_sub.rready;

    assign m_arvalid[1] = m1_lsu_r_sub.arvalid;
    assign m_araddr [1] = m1_lsu_r_sub.araddr;
    assign m_arburst[1] = m1_lsu_r_sub.arburst;
    assign m_arsize [1] = m1_lsu_r_sub.arsize;
    assign m_arlen  [1] = m1_lsu_r_sub.arlen;
    assign m_aruser [1] = m1_lsu_r_sub.aruser;
    assign m_arid   [1] = m1_lsu_r_sub.arid;
    assign m_arlock [1] = m1_lsu_r_sub.arlock;
    assign m_rready [1] = m1_lsu_r_sub.rready;

    assign m_arvalid[2] = m2_dma_r_sub.arvalid;
    assign m_araddr [2] = m2_dma_r_sub.araddr;
    assign m_arburst[2] = m2_dma_r_sub.arburst;
    assign m_arsize [2] = m2_dma_r_sub.arsize;
    assign m_arlen  [2] = m2_dma_r_sub.arlen;
    assign m_aruser [2] = m2_dma_r_sub.aruser;
    assign m_arid   [2] = m2_dma_r_sub.arid;
    assign m_arlock [2] = m2_dma_r_sub.arlock;
    assign m_rready [2] = m2_dma_r_sub.rready;

    assign m_arvalid[3] = m3_soc_r_sub.arvalid;
    assign m_araddr [3] = m3_soc_r_sub.araddr;
    assign m_arburst[3] = m3_soc_r_sub.arburst;
    assign m_arsize [3] = m3_soc_r_sub.arsize;
    assign m_arlen  [3] = m3_soc_r_sub.arlen;
    assign m_aruser [3] = m3_soc_r_sub.aruser;
    assign m_arid   [3] = m3_soc_r_sub.arid;
    assign m_arlock [3] = m3_soc_r_sub.arlock;
    assign m_rready [3] = m3_soc_r_sub.rready;

    assign m_arvalid[4] = m4_sb_r_sub.arvalid;
    assign m_araddr [4] = m4_sb_r_sub.araddr;
    assign m_arburst[4] = m4_sb_r_sub.arburst;
    assign m_arsize [4] = m4_sb_r_sub.arsize;
    assign m_arlen  [4] = m4_sb_r_sub.arlen;
    assign m_aruser [4] = m4_sb_r_sub.aruser;
    assign m_arid   [4] = m4_sb_r_sub.arid;
    assign m_arlock [4] = m4_sb_r_sub.arlock;
    assign m_rready [4] = m4_sb_r_sub.rready;

    // Priority arbitration for Read Channel: M1 (LSU) > M0 (IFU) > M2 (DMA) > M3 (SoC) > M4 (SB)
    logic        rd_grant_valid;
    logic [2:0]  rd_grant_idx;
    always_comb begin
        rd_grant_valid = 1'b0;
        rd_grant_idx   = 3'd0;
        if (m_arvalid[1]) begin
            rd_grant_valid = 1'b1;
            rd_grant_idx   = 3'd1;
        end else if (m_arvalid[0]) begin
            rd_grant_valid = 1'b1;
            rd_grant_idx   = 3'd0;
        end else if (m_arvalid[2]) begin
            rd_grant_valid = 1'b1;
            rd_grant_idx   = 3'd2;
        end else if (m_arvalid[3]) begin
            rd_grant_valid = 1'b1;
            rd_grant_idx   = 3'd3;
        end else if (m_arvalid[4]) begin
            rd_grant_valid = 1'b1;
            rd_grant_idx   = 3'd4;
        end
    end

    // Subordinate ARready / R signals
    logic        s_arready [7];
    logic        s_rvalid  [7];
    logic [63:0] s_rdata   [7];
    logic [1:0]  s_rresp   [7];
    logic [7:0]  s_rid     [7];
    logic [31:0] s_ruser   [7];
    logic        s_rlast   [7];

    assign s_arready[0] = s0_rom_r_mgr.arready;
    assign s_rvalid [0] = s0_rom_r_mgr.rvalid;
    assign s_rdata  [0] = s0_rom_r_mgr.rdata;
    assign s_rresp  [0] = s0_rom_r_mgr.rresp;
    assign s_rid    [0] = s0_rom_r_mgr.rid;
    assign s_ruser  [0] = s0_rom_r_mgr.ruser;
    assign s_rlast  [0] = s0_rom_r_mgr.rlast;

    assign s_arready[1] = s1_mci_r_mgr.arready;
    assign s_rvalid [1] = s1_mci_r_mgr.rvalid;
    assign s_rdata  [1] = {s1_mci_r_mgr.rdata, s1_mci_r_mgr.rdata};
    assign s_rresp  [1] = s1_mci_r_mgr.rresp;
    assign s_rid    [1] = s1_mci_r_mgr.rid;
    assign s_ruser  [1] = s1_mci_r_mgr.ruser;
    assign s_rlast  [1] = s1_mci_r_mgr.rlast;

    assign s_arready[2] = s2_cptra_r_mgr.arready;
    assign s_rvalid [2] = s2_cptra_r_mgr.rvalid;
    assign s_rdata  [2] = {s2_cptra_r_mgr.rdata, s2_cptra_r_mgr.rdata};
    assign s_rresp  [2] = s2_cptra_r_mgr.rresp;
    assign s_rid    [2] = s2_cptra_r_mgr.rid;
    assign s_ruser  [2] = s2_cptra_r_mgr.ruser;
    assign s_rlast  [2] = s2_cptra_r_mgr.rlast;

    assign s_arready[3] = s3_otp_rd_rsp.arready;
    assign s_rvalid [3] = s3_otp_rd_rsp.rvalid;
    assign s_rdata  [3] = {s3_otp_rd_rsp.rdata, s3_otp_rd_rsp.rdata};
    assign s_rresp  [3] = s3_otp_rd_rsp.rresp;
    assign s_rid    [3] = s3_otp_rd_rsp.rid;
    assign s_ruser  [3] = 32'd0;
    assign s_rlast  [3] = s3_otp_rd_rsp.rlast;

    assign s_arready[4] = s4_lc_rd_rsp.arready;
    assign s_rvalid [4] = s4_lc_rd_rsp.rvalid;
    assign s_rdata  [4] = {s4_lc_rd_rsp.rdata, s4_lc_rd_rsp.rdata};
    assign s_rresp  [4] = s4_lc_rd_rsp.rresp;
    assign s_rid    [4] = s4_lc_rd_rsp.rid;
    assign s_ruser  [4] = 32'd0;
    assign s_rlast  [4] = s4_lc_rd_rsp.rlast;

    assign s_arready[5] = s5_i3c_r_mgr.arready;
    assign s_rvalid [5] = s5_i3c_r_mgr.rvalid;
    assign s_rdata  [5] = {s5_i3c_r_mgr.rdata, s5_i3c_r_mgr.rdata};
    assign s_rresp  [5] = s5_i3c_r_mgr.rresp;
    assign s_rid    [5] = s5_i3c_r_mgr.rid;
    assign s_ruser  [5] = s5_i3c_r_mgr.ruser;
    assign s_rlast  [5] = s5_i3c_r_mgr.rlast;

    assign s_arready[6] = s6_sram_r_mgr.arready;
    assign s_rvalid [6] = s6_sram_r_mgr.rvalid;
    assign s_rdata  [6] = {s6_sram_r_mgr.rdata, s6_sram_r_mgr.rdata};
    assign s_rresp  [6] = s6_sram_r_mgr.rresp;
    assign s_rid    [6] = s6_sram_r_mgr.rid;
    assign s_ruser  [6] = s6_sram_r_mgr.ruser;
    assign s_rlast  [6] = s6_sram_r_mgr.rlast;

    // Read FSM sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state          <= RD_IDLE;
            rd_mgr_sel        <= 3'd0;
            rd_sub_sel        <= 3'd0;
            rd_is_64b_mgr     <= 1'b0;
            rd_is_64b_sub     <= 1'b0;
            rd_split_64_to_32 <= 1'b0;
            rd_split_phase    <= 1'b0;
            rd_low_word       <= 32'd0;
            rd_low_resp       <= 2'd0;
            rd_addr           <= 32'd0;
            rd_burst          <= 2'd0;
            rd_size           <= 3'd0;
            rd_len            <= 8'd0;
            rd_user           <= 32'd0;
            rd_id             <= 8'd0;
            rd_lock           <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (rd_grant_valid) begin
                        automatic logic [2:0] sub = decode_addr(m_araddr[rd_grant_idx]);
                        automatic logic       mgr64 = (rd_grant_idx == 3'd0 || rd_grant_idx == 3'd1 || rd_grant_idx == 3'd4);
                        automatic logic       sub64 = (sub == SUB_ROM);
                        rd_mgr_sel        <= rd_grant_idx;
                        rd_sub_sel        <= sub;
                        rd_is_64b_mgr     <= mgr64;
                        rd_is_64b_sub     <= sub64;
                        rd_split_64_to_32 <= mgr64 && !sub64 && (m_arsize[rd_grant_idx] == 3'd3);
                        rd_split_phase    <= 1'b0;
                        rd_addr           <= m_araddr [rd_grant_idx];
                        rd_burst          <= m_arburst[rd_grant_idx];
                        rd_size           <= m_arsize [rd_grant_idx];
                        rd_len            <= m_arlen  [rd_grant_idx];
                        rd_user           <= m_aruser [rd_grant_idx];
                        rd_id             <= m_arid   [rd_grant_idx];
                        rd_lock           <= m_arlock [rd_grant_idx];
                        if (sub == SUB_ERR) begin
                            rd_state <= RD_ERR;
                        end else begin
                            rd_state <= RD_AR_SEND;
                        end
                    end
                end

                RD_AR_SEND: begin
                    if (s_arready[rd_sub_sel]) begin
                        rd_state <= RD_R_WAIT;
                    end
                end

                RD_R_WAIT: begin
                    if (rd_split_64_to_32 && !rd_split_phase) begin
                        if (s_rvalid[rd_sub_sel]) begin
                            rd_low_word    <= s_rdata[rd_sub_sel][31:0];
                            rd_low_resp    <= s_rresp[rd_sub_sel];
                            rd_split_phase <= 1'b1;
                            rd_state       <= RD_AR_SEND;
                        end
                    end else begin
                        if (s_rvalid[rd_sub_sel] && m_rready[rd_mgr_sel]) begin
                            if (rd_split_64_to_32) begin
                                if (rd_len == 8'd0) begin
                                    rd_state <= RD_IDLE;
                                end else begin
                                    rd_len         <= rd_len - 8'd1;
                                    rd_addr        <= {rd_addr[31:3] + 29'd1, 3'b000};
                                    rd_split_phase <= 1'b0;
                                    rd_state       <= RD_AR_SEND;
                                end
                            end else begin
                                if (s_rlast[rd_sub_sel]) begin
                                    rd_state <= RD_IDLE;
                                end
                            end
                        end
                    end
                end

                RD_ERR: begin
                    if (m_rready[rd_mgr_sel]) begin
                        if (rd_len == 8'd0) begin
                            rd_state <= RD_IDLE;
                        end else begin
                            rd_len <= rd_len - 8'd1;
                        end
                    end
                end
            endcase
        end
    end

    // Read Channel Combinational Outputs
    logic [31:0] s_araddr_comb;
    logic [2:0]  s_arsize_comb;
    logic [7:0]  s_arlen_comb;
    logic [31:0] s_aruser_comb;

    always_comb begin
        if (rd_split_64_to_32) begin
            s_araddr_comb = {rd_addr[31:3], rd_split_phase, 2'b00};
            s_arsize_comb = 3'd2;
            s_arlen_comb  = 8'd0;
        end else if (rd_is_64b_mgr && !rd_is_64b_sub) begin
            s_araddr_comb = rd_addr;
            s_arsize_comb = (rd_size > 3'd2) ? 3'd2 : rd_size;
            s_arlen_comb  = rd_len;
        end else begin
            s_araddr_comb = rd_addr;
            s_arsize_comb = rd_size;
            s_arlen_comb  = rd_len;
        end

        // sub2tlul requires aruser[21:18] == 4'b1111 for TL-UL Get mask
        if (rd_sub_sel == SUB_OTP || rd_sub_sel == SUB_LC) begin
            s_aruser_comb = rd_user | 32'h003C_0000;
        end else begin
            s_aruser_comb = rd_user;
        end
    end

    // Subordinate AR outputs
    assign s0_rom_r_mgr.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_ROM);
    assign s0_rom_r_mgr.araddr  = s_araddr_comb;
    assign s0_rom_r_mgr.arburst = rd_burst;
    assign s0_rom_r_mgr.arsize  = s_arsize_comb;
    assign s0_rom_r_mgr.arlen   = s_arlen_comb;
    assign s0_rom_r_mgr.aruser  = s_aruser_comb;
    assign s0_rom_r_mgr.arid    = rd_id;
    assign s0_rom_r_mgr.arlock  = rd_lock;
    assign s0_rom_r_mgr.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_ROM) && m_rready[rd_mgr_sel];

    assign s1_mci_r_mgr.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_MCI);
    assign s1_mci_r_mgr.araddr  = s_araddr_comb;
    assign s1_mci_r_mgr.arburst = rd_burst;
    assign s1_mci_r_mgr.arsize  = s_arsize_comb;
    assign s1_mci_r_mgr.arlen   = s_arlen_comb;
    assign s1_mci_r_mgr.aruser  = s_aruser_comb;
    assign s1_mci_r_mgr.arid    = rd_id;
    assign s1_mci_r_mgr.arlock  = rd_lock;
    assign s1_mci_r_mgr.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_MCI) &&
                                  ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    assign s2_cptra_r_mgr.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_CPTRA);
    assign s2_cptra_r_mgr.araddr  = s_araddr_comb;
    assign s2_cptra_r_mgr.arburst = rd_burst;
    assign s2_cptra_r_mgr.arsize  = s_arsize_comb;
    assign s2_cptra_r_mgr.arlen   = s_arlen_comb;
    assign s2_cptra_r_mgr.aruser  = s_aruser_comb;
    assign s2_cptra_r_mgr.arid    = rd_id;
    assign s2_cptra_r_mgr.arlock  = rd_lock;
    assign s2_cptra_r_mgr.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_CPTRA) &&
                                    ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    assign s3_otp_rd_req.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_OTP);
    assign s3_otp_rd_req.araddr  = s_araddr_comb;
    assign s3_otp_rd_req.arburst = rd_burst;
    assign s3_otp_rd_req.arsize  = s_arsize_comb;
    assign s3_otp_rd_req.arlen   = s_arlen_comb;
    assign s3_otp_rd_req.aruser  = s_aruser_comb;
    assign s3_otp_rd_req.arid    = rd_id;
    assign s3_otp_rd_req.arlock  = rd_lock;
    assign s3_otp_rd_req.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_OTP) &&
                                   ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    assign s4_lc_rd_req.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_LC);
    assign s4_lc_rd_req.araddr  = s_araddr_comb;
    assign s4_lc_rd_req.arburst = rd_burst;
    assign s4_lc_rd_req.arsize  = s_arsize_comb;
    assign s4_lc_rd_req.arlen   = s_arlen_comb;
    assign s4_lc_rd_req.aruser  = s_aruser_comb;
    assign s4_lc_rd_req.arid    = rd_id;
    assign s4_lc_rd_req.arlock  = rd_lock;
    assign s4_lc_rd_req.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_LC) &&
                                  ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    assign s5_i3c_r_mgr.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_I3C);
    assign s5_i3c_r_mgr.araddr  = s_araddr_comb;
    assign s5_i3c_r_mgr.arburst = rd_burst;
    assign s5_i3c_r_mgr.arsize  = s_arsize_comb;
    assign s5_i3c_r_mgr.arlen   = s_arlen_comb;
    assign s5_i3c_r_mgr.aruser  = s_aruser_comb;
    assign s5_i3c_r_mgr.arid    = rd_id;
    assign s5_i3c_r_mgr.arlock  = rd_lock;
    assign s5_i3c_r_mgr.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_I3C) &&
                                  ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    assign s6_sram_r_mgr.arvalid = (rd_state == RD_AR_SEND) && (rd_sub_sel == SUB_SRAM);
    assign s6_sram_r_mgr.araddr  = s_araddr_comb;
    assign s6_sram_r_mgr.arburst = rd_burst;
    assign s6_sram_r_mgr.arsize  = s_arsize_comb;
    assign s6_sram_r_mgr.arlen   = s_arlen_comb;
    assign s6_sram_r_mgr.aruser  = s_aruser_comb;
    assign s6_sram_r_mgr.arid    = rd_id;
    assign s6_sram_r_mgr.arlock  = rd_lock;
    assign s6_sram_r_mgr.rready  = (rd_state == RD_R_WAIT) && (rd_sub_sel == SUB_SRAM) &&
                                   ((rd_split_64_to_32 && !rd_split_phase) ? 1'b1 : m_rready[rd_mgr_sel]);

    // Manager Read Data / Response muxing
    logic        m_rvalid_comb;
    logic [63:0] m_rdata64_comb;
    logic [31:0] m_rdata32_comb;
    logic [1:0]  m_rresp_comb;
    logic [7:0]  m_rid_comb;
    logic [31:0] m_ruser_comb;
    logic        m_rlast_comb;

    always_comb begin
        if (rd_state == RD_ERR) begin
            m_rvalid_comb  = 1'b1;
            m_rdata64_comb = 64'd0;
            m_rdata32_comb = 32'd0;
            m_rresp_comb   = 2'b00;
            m_rid_comb     = rd_id;
            m_ruser_comb   = 32'd0;
            m_rlast_comb   = (rd_len == 8'd0);
        end else if (rd_state == RD_R_WAIT) begin
            if (rd_split_64_to_32) begin
                if (!rd_split_phase) begin
                    m_rvalid_comb  = 1'b0;
                    m_rdata64_comb = 64'd0;
                    m_rdata32_comb = 32'd0;
                    m_rresp_comb   = 2'b00;
                    m_rid_comb     = rd_id;
                    m_ruser_comb   = 32'd0;
                    m_rlast_comb   = 1'b0;
                end else begin
                    m_rvalid_comb  = s_rvalid[rd_sub_sel];
                    m_rdata64_comb = {s_rdata[rd_sub_sel][31:0], rd_low_word};
                    m_rdata32_comb = s_rdata[rd_sub_sel][31:0];
                    m_rresp_comb   = (rd_low_resp != 2'b00) ? rd_low_resp : s_rresp[rd_sub_sel];
                    m_rid_comb     = rd_id;
                    m_ruser_comb   = s_ruser[rd_sub_sel];
                    m_rlast_comb   = (rd_len == 8'd0);
                end
            end else begin
                m_rvalid_comb  = s_rvalid[rd_sub_sel];
                m_rdata64_comb = s_rdata[rd_sub_sel];
                m_rdata32_comb = (rd_is_64b_sub && rd_addr[2]) ? s_rdata[rd_sub_sel][63:32] : s_rdata[rd_sub_sel][31:0];
                m_rresp_comb   = s_rresp[rd_sub_sel];
                m_rid_comb     = s_rid[rd_sub_sel];
                m_ruser_comb   = s_ruser[rd_sub_sel];
                m_rlast_comb   = s_rlast[rd_sub_sel];
            end
        end else begin
            m_rvalid_comb  = 1'b0;
            m_rdata64_comb = 64'd0;
            m_rdata32_comb = 32'd0;
            m_rresp_comb   = 2'b00;
            m_rid_comb     = 8'd0;
            m_ruser_comb   = 32'd0;
            m_rlast_comb   = 1'b0;
        end
    end

    assign m0_ifu_r_sub.arready = rst_n && (rd_state == RD_IDLE) && rd_grant_valid && (rd_grant_idx == 3'd0);
    assign m0_ifu_r_sub.rvalid  = (rd_mgr_sel == 3'd0) && m_rvalid_comb;
    assign m0_ifu_r_sub.rdata   = m_rdata64_comb;
    assign m0_ifu_r_sub.rresp   = m_rresp_comb;
    assign m0_ifu_r_sub.rid     = m_rid_comb;
    assign m0_ifu_r_sub.ruser   = m_ruser_comb;
    assign m0_ifu_r_sub.rlast   = m_rlast_comb;

    assign m1_lsu_r_sub.arready = rst_n && (rd_state == RD_IDLE) && rd_grant_valid && (rd_grant_idx == 3'd1);
    assign m1_lsu_r_sub.rvalid  = (rd_mgr_sel == 3'd1) && m_rvalid_comb;
    assign m1_lsu_r_sub.rdata   = m_rdata64_comb;
    assign m1_lsu_r_sub.rresp   = m_rresp_comb;
    assign m1_lsu_r_sub.rid     = m_rid_comb;
    assign m1_lsu_r_sub.ruser   = m_ruser_comb;
    assign m1_lsu_r_sub.rlast   = m_rlast_comb;

    assign m2_dma_r_sub.arready = rst_n && (rd_state == RD_IDLE) && rd_grant_valid && (rd_grant_idx == 3'd2);
    assign m2_dma_r_sub.rvalid  = (rd_mgr_sel == 3'd2) && m_rvalid_comb;
    assign m2_dma_r_sub.rdata   = m_rdata32_comb;
    assign m2_dma_r_sub.rresp   = m_rresp_comb;
    assign m2_dma_r_sub.rid     = m_rid_comb;
    assign m2_dma_r_sub.ruser   = m_ruser_comb;
    assign m2_dma_r_sub.rlast   = m_rlast_comb;

    assign m3_soc_r_sub.arready = rst_n && (rd_state == RD_IDLE) && rd_grant_valid && (rd_grant_idx == 3'd3);
    assign m3_soc_r_sub.rvalid  = (rd_mgr_sel == 3'd3) && m_rvalid_comb;
    assign m3_soc_r_sub.rdata   = m_rdata32_comb;
    assign m3_soc_r_sub.rresp   = m_rresp_comb;
    assign m3_soc_r_sub.rid     = m_rid_comb;
    assign m3_soc_r_sub.ruser   = m_ruser_comb;
    assign m3_soc_r_sub.rlast   = m_rlast_comb;

    assign m4_sb_r_sub.arready  = rst_n && (rd_state == RD_IDLE) && rd_grant_valid && (rd_grant_idx == 3'd4);
    assign m4_sb_r_sub.rvalid   = (rd_mgr_sel == 3'd4) && m_rvalid_comb;
    assign m4_sb_r_sub.rdata    = m_rdata64_comb;
    assign m4_sb_r_sub.rresp    = m_rresp_comb;
    assign m4_sb_r_sub.rid      = m_rid_comb;
    assign m4_sb_r_sub.ruser    = m_ruser_comb;
    assign m4_sb_r_sub.rlast    = m_rlast_comb;

    // =========================================================================
    // WRITE CHANNEL CROSSBAR & 64-to-32 DOWNSIZER
    // =========================================================================
    typedef enum logic [2:0] {
        WR_IDLE       = 3'd0,
        WR_64B_W_CAP  = 3'd1,
        WR_SUB_ISSUE  = 3'd2,
        WR_SUB_B_WAIT = 3'd3,
        WR_32B_STREAM = 3'd4,
        WR_ERR_W      = 3'd5,
        WR_ERR_B      = 3'd6
    } wr_state_e;

    wr_state_e   wr_state;
    logic [2:0]  wr_mgr_sel;
    logic [2:0]  wr_sub_sel;
    logic        wr_is_64b_mgr;
    logic        wr_is_64b_sub;

    logic [31:0] wr_addr;
    logic [1:0]  wr_burst;
    logic [2:0]  wr_size;
    logic [7:0]  wr_len;
    logic [31:0] wr_user;
    logic [7:0]  wr_id;
    logic        wr_lock;

    // For 64-bit manager writes (single-beat from MCU LSU / SB)
    logic [63:0] wr_wdata64;
    logic [7:0]  wr_wstrb64;
    logic        wr_split_two_beats;
    logic        wr_split_hi_word;
    logic        wr_aw_sent;
    logic        wr_w_sent;
    logic [1:0]  wr_saved_bresp;

    // Manager AW / W / B signals
    logic [4:0]  m_awvalid;
    logic [31:0] m_awaddr  [5];
    logic [1:0]  m_awburst [5];
    logic [2:0]  m_awsize  [5];
    logic [7:0]  m_awlen   [5];
    logic [31:0] m_awuser  [5];
    logic [7:0]  m_awid    [5];
    logic        m_awlock  [5];

    logic [4:0]  m_wvalid;
    logic [63:0] m_wdata64 [5];
    logic [7:0]  m_wstrb64 [5];
    logic [4:0]  m_wlast;
    logic [4:0]  m_bready;

    assign m_awvalid[0] = m0_ifu_w_sub.awvalid;
    assign m_awaddr [0] = m0_ifu_w_sub.awaddr;
    assign m_awburst[0] = m0_ifu_w_sub.awburst;
    assign m_awsize [0] = m0_ifu_w_sub.awsize;
    assign m_awlen  [0] = m0_ifu_w_sub.awlen;
    assign m_awuser [0] = m0_ifu_w_sub.awuser;
    assign m_awid   [0] = m0_ifu_w_sub.awid;
    assign m_awlock [0] = m0_ifu_w_sub.awlock;
    assign m_wvalid [0] = m0_ifu_w_sub.wvalid;
    assign m_wdata64[0] = m0_ifu_w_sub.wdata;
    assign m_wstrb64[0] = m0_ifu_w_sub.wstrb;
    assign m_wlast  [0] = m0_ifu_w_sub.wlast;
    assign m_bready [0] = m0_ifu_w_sub.bready;

    assign m_awvalid[1] = m1_lsu_w_sub.awvalid;
    assign m_awaddr [1] = m1_lsu_w_sub.awaddr;
    assign m_awburst[1] = m1_lsu_w_sub.awburst;
    assign m_awsize [1] = m1_lsu_w_sub.awsize;
    assign m_awlen  [1] = m1_lsu_w_sub.awlen;
    assign m_awuser [1] = m1_lsu_w_sub.awuser;
    assign m_awid   [1] = m1_lsu_w_sub.awid;
    assign m_awlock [1] = m1_lsu_w_sub.awlock;
    assign m_wvalid [1] = m1_lsu_w_sub.wvalid;
    assign m_wdata64[1] = m1_lsu_w_sub.wdata;
    assign m_wstrb64[1] = m1_lsu_w_sub.wstrb;
    assign m_wlast  [1] = m1_lsu_w_sub.wlast;
    assign m_bready [1] = m1_lsu_w_sub.bready;

    assign m_awvalid[2] = m2_dma_w_sub.awvalid;
    assign m_awaddr [2] = m2_dma_w_sub.awaddr;
    assign m_awburst[2] = m2_dma_w_sub.awburst;
    assign m_awsize [2] = m2_dma_w_sub.awsize;
    assign m_awlen  [2] = m2_dma_w_sub.awlen;
    assign m_awuser [2] = m2_dma_w_sub.awuser;
    assign m_awid   [2] = m2_dma_w_sub.awid;
    assign m_awlock [2] = m2_dma_w_sub.awlock;
    assign m_wvalid [2] = m2_dma_w_sub.wvalid;
    assign m_wdata64[2] = {m2_dma_w_sub.wdata, m2_dma_w_sub.wdata};
    assign m_wstrb64[2] = {m2_dma_w_sub.wstrb, m2_dma_w_sub.wstrb};
    assign m_wlast  [2] = m2_dma_w_sub.wlast;
    assign m_bready [2] = m2_dma_w_sub.bready;

    assign m_awvalid[3] = m3_soc_w_sub.awvalid;
    assign m_awaddr [3] = m3_soc_w_sub.awaddr;
    assign m_awburst[3] = m3_soc_w_sub.awburst;
    assign m_awsize [3] = m3_soc_w_sub.awsize;
    assign m_awlen  [3] = m3_soc_w_sub.awlen;
    assign m_awuser [3] = m3_soc_w_sub.awuser;
    assign m_awid   [3] = m3_soc_w_sub.awid;
    assign m_awlock [3] = m3_soc_w_sub.awlock;
    assign m_wvalid [3] = m3_soc_w_sub.wvalid;
    assign m_wdata64[3] = {m3_soc_w_sub.wdata, m3_soc_w_sub.wdata};
    assign m_wstrb64[3] = {m3_soc_w_sub.wstrb, m3_soc_w_sub.wstrb};
    assign m_wlast  [3] = m3_soc_w_sub.wlast;
    assign m_bready [3] = m3_soc_w_sub.bready;

    assign m_awvalid[4] = m4_sb_w_sub.awvalid;
    assign m_awaddr [4] = m4_sb_w_sub.awaddr;
    assign m_awburst[4] = m4_sb_w_sub.awburst;
    assign m_awsize [4] = m4_sb_w_sub.awsize;
    assign m_awlen  [4] = m4_sb_w_sub.awlen;
    assign m_awuser [4] = m4_sb_w_sub.awuser;
    assign m_awid   [4] = m4_sb_w_sub.awid;
    assign m_awlock [4] = m4_sb_w_sub.awlock;
    assign m_wvalid [4] = m4_sb_w_sub.wvalid;
    assign m_wdata64[4] = m4_sb_w_sub.wdata;
    assign m_wstrb64[4] = m4_sb_w_sub.wstrb;
    assign m_wlast  [4] = m4_sb_w_sub.wlast;
    assign m_bready [4] = m4_sb_w_sub.bready;

    // Priority arbitration for Write Channel: M1 (LSU) > M2 (DMA) > M3 (SoC) > M4 (SB) > M0 (IFU)
    logic       wr_grant_valid;
    logic [2:0] wr_grant_idx;
    always_comb begin
        wr_grant_valid = 1'b0;
        wr_grant_idx   = 3'd0;
        if (m_awvalid[1]) begin
            wr_grant_valid = 1'b1;
            wr_grant_idx   = 3'd1;
        end else if (m_awvalid[2]) begin
            wr_grant_valid = 1'b1;
            wr_grant_idx   = 3'd2;
        end else if (m_awvalid[3]) begin
            wr_grant_valid = 1'b1;
            wr_grant_idx   = 3'd3;
        end else if (m_awvalid[4]) begin
            wr_grant_valid = 1'b1;
            wr_grant_idx   = 3'd4;
        end else if (m_awvalid[0]) begin
            wr_grant_valid = 1'b1;
            wr_grant_idx   = 3'd0;
        end
    end

    // Subordinate AWready / Wready / B signals
    logic        s_awready [7];
    logic        s_wready  [7];
    logic        s_bvalid  [7];
    logic [1:0]  s_bresp   [7];
    logic [7:0]  s_bid     [7];
    logic [31:0] s_buser   [7];

    assign s_awready[0] = s0_rom_w_mgr.awready;
    assign s_wready [0] = s0_rom_w_mgr.wready;
    assign s_bvalid [0] = s0_rom_w_mgr.bvalid;
    assign s_bresp  [0] = s0_rom_w_mgr.bresp;
    assign s_bid    [0] = s0_rom_w_mgr.bid;
    assign s_buser  [0] = s0_rom_w_mgr.buser;

    assign s_awready[1] = s1_mci_w_mgr.awready;
    assign s_wready [1] = s1_mci_w_mgr.wready;
    assign s_bvalid [1] = s1_mci_w_mgr.bvalid;
    assign s_bresp  [1] = s1_mci_w_mgr.bresp;
    assign s_bid    [1] = s1_mci_w_mgr.bid;
    assign s_buser  [1] = s1_mci_w_mgr.buser;

    assign s_awready[2] = s2_cptra_w_mgr.awready;
    assign s_wready [2] = s2_cptra_w_mgr.wready;
    assign s_bvalid [2] = s2_cptra_w_mgr.bvalid;
    assign s_bresp  [2] = s2_cptra_w_mgr.bresp;
    assign s_bid    [2] = s2_cptra_w_mgr.bid;
    assign s_buser  [2] = s2_cptra_w_mgr.buser;

    assign s_awready[3] = s3_otp_wr_rsp.awready;
    assign s_wready [3] = s3_otp_wr_rsp.wready;
    assign s_bvalid [3] = s3_otp_wr_rsp.bvalid;
    assign s_bresp  [3] = s3_otp_wr_rsp.bresp;
    assign s_bid    [3] = s3_otp_wr_rsp.bid;
    assign s_buser  [3] = 32'd0;

    assign s_awready[4] = s4_lc_wr_rsp.awready;
    assign s_wready [4] = s4_lc_wr_rsp.wready;
    assign s_bvalid [4] = s4_lc_wr_rsp.bvalid;
    assign s_bresp  [4] = s4_lc_wr_rsp.bresp;
    assign s_bid    [4] = s4_lc_wr_rsp.bid;
    assign s_buser  [4] = 32'd0;

    assign s_awready[5] = s5_i3c_w_mgr.awready;
    assign s_wready [5] = s5_i3c_w_mgr.wready;
    assign s_bvalid [5] = s5_i3c_w_mgr.bvalid;
    assign s_bresp  [5] = s5_i3c_w_mgr.bresp;
    assign s_bid    [5] = s5_i3c_w_mgr.bid;
    assign s_buser  [5] = s5_i3c_w_mgr.buser;

    assign s_awready[6] = s6_sram_w_mgr.awready;
    assign s_wready [6] = s6_sram_w_mgr.wready;
    assign s_bvalid [6] = s6_sram_w_mgr.bvalid;
    assign s_bresp  [6] = s6_sram_w_mgr.bresp;
    assign s_bid    [6] = s6_sram_w_mgr.bid;
    assign s_buser  [6] = s6_sram_w_mgr.buser;

    // Write FSM sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state           <= WR_IDLE;
            wr_mgr_sel         <= 3'd0;
            wr_sub_sel         <= 3'd0;
            wr_is_64b_mgr      <= 1'b0;
            wr_is_64b_sub      <= 1'b0;
            wr_addr            <= 32'd0;
            wr_burst           <= 2'd0;
            wr_size            <= 3'd0;
            wr_len             <= 8'd0;
            wr_user            <= 32'd0;
            wr_id              <= 8'd0;
            wr_lock            <= 1'b0;
            wr_wdata64         <= 64'd0;
            wr_wstrb64         <= 8'd0;
            wr_split_two_beats <= 1'b0;
            wr_split_hi_word   <= 1'b0;
            wr_aw_sent         <= 1'b0;
            wr_w_sent          <= 1'b0;
            wr_saved_bresp     <= 2'd0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    if (wr_grant_valid) begin
                        automatic logic [2:0] sub = decode_addr(m_awaddr[wr_grant_idx]);
                        automatic logic       mgr64 = (wr_grant_idx == 3'd0 || wr_grant_idx == 3'd1 || wr_grant_idx == 3'd4);
                        automatic logic       sub64 = (sub == SUB_ROM);
                        wr_mgr_sel     <= wr_grant_idx;
                        wr_sub_sel     <= sub;
                        wr_is_64b_mgr  <= mgr64;
                        wr_is_64b_sub  <= sub64;
                        wr_addr        <= m_awaddr [wr_grant_idx];
                        wr_burst       <= m_awburst[wr_grant_idx];
                        wr_size        <= m_awsize [wr_grant_idx];
                        wr_len         <= m_awlen  [wr_grant_idx];
                        wr_user        <= m_awuser [wr_grant_idx];
                        wr_id          <= m_awid   [wr_grant_idx];
                        wr_lock        <= m_awlock [wr_grant_idx];
                        wr_aw_sent     <= 1'b0;
                        wr_w_sent      <= 1'b0;
                        wr_saved_bresp <= 2'd0;
                        if (sub == SUB_ERR) begin
                            wr_state <= WR_ERR_W;
                        end else if (mgr64) begin
                            wr_state <= WR_64B_W_CAP;
                        end else begin
                            // 32-bit manager (M2 DMA or M3 SoC): stream AW, W, B
                            wr_state <= WR_32B_STREAM;
                        end
                    end
                end

                WR_64B_W_CAP: begin
                    if (m_wvalid[wr_mgr_sel]) begin
                        automatic logic has_lo = |m_wstrb64[wr_mgr_sel][3:0];
                        automatic logic has_hi = |m_wstrb64[wr_mgr_sel][7:4];
                        wr_wdata64 <= m_wdata64[wr_mgr_sel];
                        wr_wstrb64 <= m_wstrb64[wr_mgr_sel];
                        wr_aw_sent <= 1'b0;
                        wr_w_sent  <= 1'b0;
                        if (wr_is_64b_sub) begin
                            wr_split_two_beats <= 1'b0;
                            wr_split_hi_word   <= 1'b0;
                        end else if (has_lo && has_hi) begin
                            wr_split_two_beats <= 1'b1;
                            wr_split_hi_word   <= 1'b0;
                        end else if (has_hi) begin
                            wr_split_two_beats <= 1'b0;
                            wr_split_hi_word   <= 1'b1;
                        end else if (has_lo) begin
                            wr_split_two_beats <= 1'b0;
                            wr_split_hi_word   <= 1'b0;
                        end else begin
                            wr_split_two_beats <= 1'b0;
                            wr_split_hi_word   <= wr_addr[2];
                        end
                        wr_state <= WR_SUB_ISSUE;
                    end
                end

                WR_SUB_ISSUE: begin
                    automatic logic aw_done = wr_aw_sent || s_awready[wr_sub_sel];
                    automatic logic w_done  = wr_w_sent  || s_wready [wr_sub_sel];
                    wr_aw_sent <= aw_done;
                    wr_w_sent  <= w_done;
                    if (aw_done && w_done) begin
                        wr_state <= WR_SUB_B_WAIT;
                    end
                end

                WR_SUB_B_WAIT: begin
                    if (wr_split_two_beats) begin
                        if (s_bvalid[wr_sub_sel]) begin
                            wr_saved_bresp     <= s_bresp[wr_sub_sel];
                            wr_split_two_beats <= 1'b0;
                            wr_split_hi_word   <= 1'b1;
                            wr_aw_sent         <= 1'b0;
                            wr_w_sent          <= 1'b0;
                            wr_state           <= WR_SUB_ISSUE;
                        end
                    end else begin
                        if (s_bvalid[wr_sub_sel] && m_bready[wr_mgr_sel]) begin
                            wr_state <= WR_IDLE;
                        end
                    end
                end

                WR_32B_STREAM: begin
                    if ( (!wr_aw_sent && s_awready[wr_sub_sel]) ) begin
                        wr_aw_sent <= 1'b1;
                    end
                    if ( (!wr_w_sent && m_wvalid[wr_mgr_sel] && s_wready[wr_sub_sel] && m_wlast[wr_mgr_sel]) ) begin
                        wr_w_sent <= 1'b1;
                    end
                    if ( (wr_aw_sent || s_awready[wr_sub_sel]) &&
                         (wr_w_sent  || (m_wvalid[wr_mgr_sel] && s_wready[wr_sub_sel] && m_wlast[wr_mgr_sel])) ) begin
                        wr_state <= WR_SUB_B_WAIT;
                    end
                end

                WR_ERR_W: begin
                    if (m_wvalid[wr_mgr_sel] && m_wlast[wr_mgr_sel]) begin
                        wr_state <= WR_ERR_B;
                    end
                end

                WR_ERR_B: begin
                    if (m_bready[wr_mgr_sel]) begin
                        wr_state <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // Write Channel Combinational Outputs
    logic        s_awvalid_comb;
    logic [31:0] s_awaddr_comb;
    logic [2:0]  s_awsize_comb;
    logic [7:0]  s_awlen_comb;
    logic        s_wvalid_comb;
    logic [63:0] s_wdata64_comb;
    logic [7:0]  s_wstrb64_comb;
    logic [31:0] s_wdata32_comb;
    logic [3:0]  s_wstrb32_comb;
    logic        s_wlast_comb;
    logic        s_bready_comb;

    always_comb begin
        s_awvalid_comb = 1'b0;
        s_awaddr_comb  = wr_addr;
        s_awsize_comb  = wr_size;
        s_awlen_comb   = wr_len;
        s_wvalid_comb  = 1'b0;
        s_wdata64_comb = wr_wdata64;
        s_wstrb64_comb = wr_wstrb64;
        s_wdata32_comb = wr_wdata64[31:0];
        s_wstrb32_comb = wr_wstrb64[3:0];
        s_wlast_comb   = 1'b1;
        s_bready_comb  = 1'b0;

        if (wr_state == WR_SUB_ISSUE) begin
            s_awvalid_comb = !wr_aw_sent;
            s_wvalid_comb  = !wr_w_sent;
            s_wlast_comb   = 1'b1;
            if (wr_is_64b_sub) begin
                s_awaddr_comb  = wr_addr;
                s_awsize_comb  = wr_size;
                s_awlen_comb   = 8'd0;
                s_wdata64_comb = wr_wdata64;
                s_wstrb64_comb = wr_wstrb64;
            end else begin
                // Downsized 32-bit write from 64-bit manager: force 32-bit aligned word address & size=2
                s_awaddr_comb  = {wr_addr[31:3], wr_split_hi_word, 2'b00};
                s_awsize_comb  = 3'd2;
                s_awlen_comb   = 8'd0;
                s_wdata32_comb = wr_split_hi_word ? wr_wdata64[63:32] : wr_wdata64[31:0];
                s_wstrb32_comb = wr_split_hi_word ? wr_wstrb64[7:4]   : wr_wstrb64[3:0];
            end
        end else if (wr_state == WR_32B_STREAM) begin
            s_awvalid_comb = !wr_aw_sent;
            s_awaddr_comb  = wr_addr;
            s_awsize_comb  = wr_size;
            s_awlen_comb   = wr_len;
            s_wvalid_comb  = !wr_w_sent && m_wvalid[wr_mgr_sel];
            s_wdata32_comb = m_wdata64[wr_mgr_sel][31:0];
            s_wstrb32_comb = m_wstrb64[wr_mgr_sel][3:0];
            s_wdata64_comb = m_wdata64[wr_mgr_sel];
            s_wstrb64_comb = wr_addr[2] ? {m_wstrb64[wr_mgr_sel][3:0], 4'h0} : {4'h0, m_wstrb64[wr_mgr_sel][3:0]};
            s_wlast_comb   = m_wlast[wr_mgr_sel];
        end else if (wr_state == WR_SUB_B_WAIT) begin
            s_bready_comb  = wr_split_two_beats ? 1'b1 : m_bready[wr_mgr_sel];
        end
    end

    // Subordinate Write Channel outputs
    assign s0_rom_w_mgr.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_ROM);
    assign s0_rom_w_mgr.awaddr  = s_awaddr_comb;
    assign s0_rom_w_mgr.awburst = wr_burst;
    assign s0_rom_w_mgr.awsize  = s_awsize_comb;
    assign s0_rom_w_mgr.awlen   = s_awlen_comb;
    assign s0_rom_w_mgr.awuser  = wr_user;
    assign s0_rom_w_mgr.awid    = wr_id;
    assign s0_rom_w_mgr.awlock  = wr_lock;
    assign s0_rom_w_mgr.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_ROM);
    assign s0_rom_w_mgr.wdata   = s_wdata64_comb;
    assign s0_rom_w_mgr.wstrb   = s_wstrb64_comb;
    assign s0_rom_w_mgr.wuser   = 32'd0;
    assign s0_rom_w_mgr.wlast   = s_wlast_comb;
    assign s0_rom_w_mgr.bready  = s_bready_comb && (wr_sub_sel == SUB_ROM);

    assign s1_mci_w_mgr.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_MCI);
    assign s1_mci_w_mgr.awaddr  = s_awaddr_comb;
    assign s1_mci_w_mgr.awburst = wr_burst;
    assign s1_mci_w_mgr.awsize  = s_awsize_comb;
    assign s1_mci_w_mgr.awlen   = s_awlen_comb;
    assign s1_mci_w_mgr.awuser  = wr_user;
    assign s1_mci_w_mgr.awid    = wr_id;
    assign s1_mci_w_mgr.awlock  = wr_lock;
    assign s1_mci_w_mgr.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_MCI);
    assign s1_mci_w_mgr.wdata   = s_wdata32_comb;
    assign s1_mci_w_mgr.wstrb   = s_wstrb32_comb;
    assign s1_mci_w_mgr.wuser   = 32'd0;
    assign s1_mci_w_mgr.wlast   = s_wlast_comb;
    assign s1_mci_w_mgr.bready  = s_bready_comb && (wr_sub_sel == SUB_MCI);

    assign s2_cptra_w_mgr.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_CPTRA);
    assign s2_cptra_w_mgr.awaddr  = s_awaddr_comb;
    assign s2_cptra_w_mgr.awburst = wr_burst;
    assign s2_cptra_w_mgr.awsize  = s_awsize_comb;
    assign s2_cptra_w_mgr.awlen   = s_awlen_comb;
    assign s2_cptra_w_mgr.awuser  = wr_user;
    assign s2_cptra_w_mgr.awid    = wr_id;
    assign s2_cptra_w_mgr.awlock  = wr_lock;
    assign s2_cptra_w_mgr.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_CPTRA);
    assign s2_cptra_w_mgr.wdata   = s_wdata32_comb;
    assign s2_cptra_w_mgr.wstrb   = s_wstrb32_comb;
    assign s2_cptra_w_mgr.wuser   = 32'd0;
    assign s2_cptra_w_mgr.wlast   = s_wlast_comb;
    assign s2_cptra_w_mgr.bready  = s_bready_comb && (wr_sub_sel == SUB_CPTRA);

    assign s3_otp_wr_req.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_OTP);
    assign s3_otp_wr_req.awaddr  = s_awaddr_comb;
    assign s3_otp_wr_req.awburst = wr_burst;
    assign s3_otp_wr_req.awsize  = s_awsize_comb;
    assign s3_otp_wr_req.awlen   = s_awlen_comb;
    assign s3_otp_wr_req.awuser  = wr_user;
    assign s3_otp_wr_req.awid    = wr_id;
    assign s3_otp_wr_req.awlock  = wr_lock;
    assign s3_otp_wr_req.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_OTP);
    assign s3_otp_wr_req.wdata   = s_wdata32_comb;
    assign s3_otp_wr_req.wstrb   = s_wstrb32_comb;
    assign s3_otp_wr_req.wlast   = s_wlast_comb;
    assign s3_otp_wr_req.bready  = s_bready_comb && (wr_sub_sel == SUB_OTP);

    assign s4_lc_wr_req.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_LC);
    assign s4_lc_wr_req.awaddr  = s_awaddr_comb;
    assign s4_lc_wr_req.awburst = wr_burst;
    assign s4_lc_wr_req.awsize  = s_awsize_comb;
    assign s4_lc_wr_req.awlen   = s_awlen_comb;
    assign s4_lc_wr_req.awuser  = wr_user;
    assign s4_lc_wr_req.awid    = wr_id;
    assign s4_lc_wr_req.awlock  = wr_lock;
    assign s4_lc_wr_req.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_LC);
    assign s4_lc_wr_req.wdata   = s_wdata32_comb;
    assign s4_lc_wr_req.wstrb   = s_wstrb32_comb;
    assign s4_lc_wr_req.wlast   = s_wlast_comb;
    assign s4_lc_wr_req.bready  = s_bready_comb && (wr_sub_sel == SUB_LC);

    assign s5_i3c_w_mgr.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_I3C);
    assign s5_i3c_w_mgr.awaddr  = s_awaddr_comb;
    assign s5_i3c_w_mgr.awburst = wr_burst;
    assign s5_i3c_w_mgr.awsize  = s_awsize_comb;
    assign s5_i3c_w_mgr.awlen   = s_awlen_comb;
    assign s5_i3c_w_mgr.awuser  = wr_user;
    assign s5_i3c_w_mgr.awid    = wr_id;
    assign s5_i3c_w_mgr.awlock  = wr_lock;
    assign s5_i3c_w_mgr.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_I3C);
    assign s5_i3c_w_mgr.wdata   = s_wdata32_comb;
    assign s5_i3c_w_mgr.wstrb   = s_wstrb32_comb;
    assign s5_i3c_w_mgr.wuser   = 32'd0;
    assign s5_i3c_w_mgr.wlast   = s_wlast_comb;
    assign s5_i3c_w_mgr.bready  = s_bready_comb && (wr_sub_sel == SUB_I3C);

    assign s6_sram_w_mgr.awvalid = s_awvalid_comb && (wr_sub_sel == SUB_SRAM);
    assign s6_sram_w_mgr.awaddr  = s_awaddr_comb;
    assign s6_sram_w_mgr.awburst = wr_burst;
    assign s6_sram_w_mgr.awsize  = s_awsize_comb;
    assign s6_sram_w_mgr.awlen   = s_awlen_comb;
    assign s6_sram_w_mgr.awuser  = wr_user;
    assign s6_sram_w_mgr.awid    = wr_id;
    assign s6_sram_w_mgr.awlock  = wr_lock;
    assign s6_sram_w_mgr.wvalid  = s_wvalid_comb && (wr_sub_sel == SUB_SRAM);
    assign s6_sram_w_mgr.wdata   = s_wdata32_comb;
    assign s6_sram_w_mgr.wstrb   = s_wstrb32_comb;
    assign s6_sram_w_mgr.wuser   = 32'd0;
    assign s6_sram_w_mgr.wlast   = s_wlast_comb;
    assign s6_sram_w_mgr.bready  = s_bready_comb && (wr_sub_sel == SUB_SRAM);

    // Manager Write Handshake & Response muxing
    logic        m_wready_comb;
    logic        m_bvalid_comb;
    logic [1:0]  m_bresp_comb;
    logic [7:0]  m_bid_comb;
    logic [31:0] m_buser_comb;

    always_comb begin
        m_wready_comb = 1'b0;
        m_bvalid_comb = 1'b0;
        m_bresp_comb  = 2'b00;
        m_bid_comb    = wr_id;
        m_buser_comb  = 32'd0;

        case (wr_state)
            WR_64B_W_CAP: begin
                m_wready_comb = 1'b1;
            end
            WR_32B_STREAM: begin
                m_wready_comb = !wr_w_sent && s_wready[wr_sub_sel];
            end
            WR_SUB_B_WAIT: begin
                if (!wr_split_two_beats) begin
                    m_bvalid_comb = s_bvalid[wr_sub_sel];
                    m_bresp_comb  = (wr_saved_bresp != 2'b00) ? wr_saved_bresp : s_bresp[wr_sub_sel];
                    m_bid_comb    = wr_is_64b_mgr ? wr_id : s_bid[wr_sub_sel];
                    m_buser_comb  = s_buser[wr_sub_sel];
                end
            end
            WR_ERR_W: begin
                m_wready_comb = 1'b1;
            end
            WR_ERR_B: begin
                m_bvalid_comb = 1'b1;
                m_bresp_comb  = 2'b00;
                m_bid_comb    = wr_id;
                m_buser_comb  = 32'd0;
            end
            default: ;
        endcase
    end

    assign m0_ifu_w_sub.awready = rst_n && (wr_state == WR_IDLE) && wr_grant_valid && (wr_grant_idx == 3'd0);
    assign m0_ifu_w_sub.wready  = (wr_mgr_sel == 3'd0) && m_wready_comb;
    assign m0_ifu_w_sub.bvalid  = (wr_mgr_sel == 3'd0) && m_bvalid_comb;
    assign m0_ifu_w_sub.bresp   = m_bresp_comb;
    assign m0_ifu_w_sub.bid     = m_bid_comb;
    assign m0_ifu_w_sub.buser   = m_buser_comb;

    assign m1_lsu_w_sub.awready = rst_n && (wr_state == WR_IDLE) && wr_grant_valid && (wr_grant_idx == 3'd1);
    assign m1_lsu_w_sub.wready  = (wr_mgr_sel == 3'd1) && m_wready_comb;
    assign m1_lsu_w_sub.bvalid  = (wr_mgr_sel == 3'd1) && m_bvalid_comb;
    assign m1_lsu_w_sub.bresp   = m_bresp_comb;
    assign m1_lsu_w_sub.bid     = m_bid_comb;
    assign m1_lsu_w_sub.buser   = m_buser_comb;

    assign m2_dma_w_sub.awready = rst_n && (wr_state == WR_IDLE) && wr_grant_valid && (wr_grant_idx == 3'd2);
    assign m2_dma_w_sub.wready  = (wr_mgr_sel == 3'd2) && m_wready_comb;
    assign m2_dma_w_sub.bvalid  = (wr_mgr_sel == 3'd2) && m_bvalid_comb;
    assign m2_dma_w_sub.bresp   = m_bresp_comb;
    assign m2_dma_w_sub.bid     = m_bid_comb;
    assign m2_dma_w_sub.buser   = m_buser_comb;

    assign m3_soc_w_sub.awready = rst_n && (wr_state == WR_IDLE) && wr_grant_valid && (wr_grant_idx == 3'd3);
    assign m3_soc_w_sub.wready  = (wr_mgr_sel == 3'd3) && m_wready_comb;
    assign m3_soc_w_sub.bvalid  = (wr_mgr_sel == 3'd3) && m_bvalid_comb;
    assign m3_soc_w_sub.bresp   = m_bresp_comb;
    assign m3_soc_w_sub.bid     = m_bid_comb;
    assign m3_soc_w_sub.buser   = m_buser_comb;

    assign m4_sb_w_sub.awready  = rst_n && (wr_state == WR_IDLE) && wr_grant_valid && (wr_grant_idx == 3'd4);
    assign m4_sb_w_sub.wready   = (wr_mgr_sel == 3'd4) && m_wready_comb;
    assign m4_sb_w_sub.bvalid   = (wr_mgr_sel == 3'd4) && m_bvalid_comb;
    assign m4_sb_w_sub.bresp    = m_bresp_comb;
    assign m4_sb_w_sub.bid      = m_bid_comb;
    assign m4_sb_w_sub.buser    = m_buser_comb;

endmodule
