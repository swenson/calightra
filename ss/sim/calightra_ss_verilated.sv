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
// Calightra-SS Top-Level Verilator Wrapper
// Connects caliptra_ss_top (MCU VeeR EL2 + MCI + OTP + LC + Caliptra Core)
// to the open-source calightra_ss_axi_xbar and backing SRAM arrays.

`include "common_defines.sv"
`include "config_defines.svh"
`include "caliptra_reg_defines.svh"
`include "caliptra_macros.svh"
`include "i3c_defines.svh"
`include "soc_address_map_defines.svh"
`include "caliptra_ss_includes.svh"

module calightra_ss_verilated
    import axi_pkg::*;
    import soc_ifc_pkg::*;
#(
    `include "css_mcu0_el2_param.vh"
    ,parameter int MCU_SRAM_SIZE_KB  = 512
    ,parameter int MCU_MBOX0_SIZE_KB = 4
    ,parameter int MCU_MBOX1_SIZE_KB = 0
) (
    input  logic        core_clk,
    input  logic        cptra_ss_pwrgood_i,
    input  logic        cptra_ss_rst_b_i,

    // External SoC AXI Manager Port (M3 on AXI Crossbar)
    input  logic        soc_awvalid,
    output logic        soc_awready,
    input  logic [31:0] soc_awaddr,
    input  logic [31:0] soc_awuser,
    input  logic        soc_wvalid,
    output logic        soc_wready,
    input  logic [31:0] soc_wdata,
    input  logic [3:0]  soc_wstrb,
    output logic        soc_bvalid,
    input  logic        soc_bready,
    output logic [1:0]  soc_bresp,

    input  logic        soc_arvalid,
    output logic        soc_arready,
    input  logic [31:0] soc_araddr,
    input  logic [31:0] soc_aruser,
    output logic        soc_rvalid,
    input  logic        soc_rready,
    output logic [31:0] soc_rdata,
    output logic [1:0]  soc_rresp,

    // External Host I3C Controller (Master) MMIO Register Interface
    input  logic [7:0]  i3c_ctrl_addr_i,
    input  logic [31:0] i3c_ctrl_wdata_i,
    input  logic        i3c_ctrl_we_i,
    input  logic        i3c_ctrl_re_i,
    output logic [31:0] i3c_ctrl_rdata_o,

    // Physical I3C Bus Monitor Outputs
    output logic        i3c_bus_scl_o,
    output logic        i3c_bus_sda_o,

    // Status & Console Outputs
    output logic        cptra_ss_mci_cptra_rst_b_o,
    output logic        cptra_ss_mcu_rst_b_o,
    output logic        cptra_ss_ready_for_fuses_o,
    output logic        cptra_ss_ready_for_mb_processing_o,
    output logic        cptra_ss_ready_for_runtime_o,
    output logic        cptra_ss_etrng_req_o,
    output logic        cptra_ss_fw_exec_ctrl_2_mcu_o,
    output logic [63:0] cptra_ss_mci_generic_output_wires_o,
    output logic [63:0] cptra_ss_cptra_core_generic_output_wires_o,
    output logic        mci_debug_char_valid_o,
    output logic [7:0]  mci_debug_char_o,
    output logic        cptra_ss_all_error_fatal_o,
    output logic        cptra_ss_all_error_non_fatal_o
);

    localparam int ID_W   = `CALIPTRA_AXI_ID_WIDTH;
    localparam int USER_W = `CALIPTRA_AXI_USER_WIDTH;

    localparam int MCU_SRAM_DEPTH      = (MCU_SRAM_SIZE_KB * 1024) / 4;
    localparam int MCU_SRAM_ADDR_WIDTH = $clog2(MCU_SRAM_DEPTH);
    localparam int MCU_MBOX0_DEPTH     = (MCU_MBOX0_SIZE_KB * 1024) / 4;
    localparam int MCU_MBOX0_ADDR_W    = $clog2(MCU_MBOX0_DEPTH);

    localparam [4:0]        SET_MCU_MBOX0_AXI_USER_INTEG = 5'b00000;
    localparam [4:0][31:0]  MCU_MBOX0_VALID_AXI_USER     = {
        32'h0000_0003, 32'h0000_0002, 32'h0000_0001, 32'h1111_1111, 32'h0000_0000
    };
    localparam [4:0]        SET_MCU_MBOX1_AXI_USER_INTEG = 5'b00000;
    localparam [4:0][31:0]  MCU_MBOX1_VALID_AXI_USER     = {
        32'h0000_0003, 32'h0000_0002, 32'h0000_0001, 32'h1111_1111, 32'h0000_0000
    };

    logic cptra_ss_rst_b_o;
    logic cptra_ss_rdc_clk_cg_o;
    logic cptra_ss_mcu_clk_cg_o;

    // -------------------------------------------------------------------------
    // AXI4 Interfaces for Crossbar
    // -------------------------------------------------------------------------
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_ifu_m_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_lsu_m_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_sb_m_axi_if  (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_cptra_core_m_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) soc_m_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));

    axi_if #(.AW(CPTRA_SS_ROM_AXI_ADDR_W), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_rom_s_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_mci_s_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_cptra_core_s_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_i3c_s_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_soc_sram_s_axi_if (.clk(core_clk), .rst_n(cptra_ss_rst_b_i));

    axi_struct_pkg::axi_wr_req_t cptra_ss_otp_core_axi_wr_req_i;
    axi_struct_pkg::axi_wr_rsp_t cptra_ss_otp_core_axi_wr_rsp_o;
    axi_struct_pkg::axi_rd_req_t cptra_ss_otp_core_axi_rd_req_i;
    axi_struct_pkg::axi_rd_rsp_t cptra_ss_otp_core_axi_rd_rsp_o;

    axi_struct_pkg::axi_wr_req_t cptra_ss_lc_axi_wr_req_i;
    axi_struct_pkg::axi_wr_rsp_t cptra_ss_lc_axi_wr_rsp_o;
    axi_struct_pkg::axi_rd_req_t cptra_ss_lc_axi_rd_req_i;
    axi_struct_pkg::axi_rd_rsp_t cptra_ss_lc_axi_rd_rsp_o;

    // Bind External SoC Manager to soc_m_axi_if
    assign soc_m_axi_if.awvalid = soc_awvalid;
    assign soc_awready          = soc_m_axi_if.awready;
    assign soc_m_axi_if.awaddr  = soc_awaddr;
    assign soc_m_axi_if.awid    = '0;
    assign soc_m_axi_if.awlen   = 8'd0;
    assign soc_m_axi_if.awsize  = 3'd2;
    assign soc_m_axi_if.awburst = 2'b01;
    assign soc_m_axi_if.awlock  = 1'b0;
    assign soc_m_axi_if.awuser  = soc_awuser;

    assign soc_m_axi_if.wvalid  = soc_wvalid;
    assign soc_wready           = soc_m_axi_if.wready;
    assign soc_m_axi_if.wdata   = soc_wdata;
    assign soc_m_axi_if.wstrb   = soc_wstrb;
    assign soc_m_axi_if.wlast   = 1'b1;
    assign soc_m_axi_if.wuser   = '0;

    assign soc_bvalid           = soc_m_axi_if.bvalid;
    assign soc_m_axi_if.bready  = soc_bready;
    assign soc_bresp            = soc_m_axi_if.bresp;

    assign soc_m_axi_if.arvalid = soc_arvalid;
    assign soc_arready          = soc_m_axi_if.arready;
    assign soc_m_axi_if.araddr  = soc_araddr;
    assign soc_m_axi_if.arid    = '0;
    assign soc_m_axi_if.arlen   = 8'd0;
    assign soc_m_axi_if.arsize  = 3'd2;
    assign soc_m_axi_if.arburst = 2'b01;
    assign soc_m_axi_if.arlock  = 1'b0;
    assign soc_m_axi_if.aruser  = soc_aruser;

    assign soc_rvalid           = soc_m_axi_if.rvalid;
    assign soc_m_axi_if.rready  = soc_rready;
    assign soc_rdata            = soc_m_axi_if.rdata;
    assign soc_rresp            = soc_m_axi_if.rresp;

    // -------------------------------------------------------------------------
    // Open-Source AXI4 Crossbar (calightra_ss_axi_xbar)
    // -------------------------------------------------------------------------
    calightra_ss_axi_xbar u_axi_xbar (
        .clk             (core_clk),
        .rst_n           (cptra_ss_rst_b_i),

        .m0_ifu_w_sub    (cptra_ss_mcu_ifu_m_axi_if.w_sub),
        .m0_ifu_r_sub    (cptra_ss_mcu_ifu_m_axi_if.r_sub),
        .m1_lsu_w_sub    (cptra_ss_mcu_lsu_m_axi_if.w_sub),
        .m1_lsu_r_sub    (cptra_ss_mcu_lsu_m_axi_if.r_sub),
        .m2_dma_w_sub    (cptra_ss_cptra_core_m_axi_if.w_sub),
        .m2_dma_r_sub    (cptra_ss_cptra_core_m_axi_if.r_sub),
        .m3_soc_w_sub    (soc_m_axi_if.w_sub),
        .m3_soc_r_sub    (soc_m_axi_if.r_sub),
        .m4_sb_w_sub     (cptra_ss_mcu_sb_m_axi_if.w_sub),
        .m4_sb_r_sub     (cptra_ss_mcu_sb_m_axi_if.r_sub),

        .s0_rom_w_mgr    (cptra_ss_mcu_rom_s_axi_if.w_mgr),
        .s0_rom_r_mgr    (cptra_ss_mcu_rom_s_axi_if.r_mgr),
        .s1_mci_w_mgr    (cptra_ss_mci_s_axi_if.w_mgr),
        .s1_mci_r_mgr    (cptra_ss_mci_s_axi_if.r_mgr),
        .s2_cptra_w_mgr  (cptra_ss_cptra_core_s_axi_if.w_mgr),
        .s2_cptra_r_mgr  (cptra_ss_cptra_core_s_axi_if.r_mgr),
        .s3_otp_wr_req   (cptra_ss_otp_core_axi_wr_req_i),
        .s3_otp_wr_rsp   (cptra_ss_otp_core_axi_wr_rsp_o),
        .s3_otp_rd_req   (cptra_ss_otp_core_axi_rd_req_i),
        .s3_otp_rd_rsp   (cptra_ss_otp_core_axi_rd_rsp_o),
        .s4_lc_wr_req    (cptra_ss_lc_axi_wr_req_i),
        .s4_lc_wr_rsp    (cptra_ss_lc_axi_wr_rsp_o),
        .s4_lc_rd_req    (cptra_ss_lc_axi_rd_req_i),
        .s4_lc_rd_rsp    (cptra_ss_lc_axi_rd_rsp_o),
        .s5_i3c_w_mgr    (cptra_ss_i3c_s_axi_if.w_mgr),
        .s5_i3c_r_mgr    (cptra_ss_i3c_s_axi_if.r_mgr),
        .s6_sram_w_mgr   (cptra_ss_soc_sram_s_axi_if.w_mgr),
        .s6_sram_r_mgr   (cptra_ss_soc_sram_s_axi_if.r_mgr)
    );

    // -------------------------------------------------------------------------
    // Monitor MCI DEBUG_OUT (0x2100_0414) Writes on S1_MCI AXI Interface
    // -------------------------------------------------------------------------
    logic mci_aw_is_debug_out;
    always_ff @(posedge core_clk or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            mci_aw_is_debug_out    <= 1'b0;
            mci_debug_char_valid_o <= 1'b0;
            mci_debug_char_o       <= 8'h00;
        end else begin
            mci_debug_char_valid_o <= 1'b0;
            if (cptra_ss_mci_s_axi_if.awvalid && cptra_ss_mci_s_axi_if.awready) begin
                if (cptra_ss_mci_s_axi_if.wvalid && cptra_ss_mci_s_axi_if.wready) begin
                    if (cptra_ss_mci_s_axi_if.awaddr[15:0] == 16'h0414) begin
                        mci_debug_char_valid_o <= 1'b1;
                        mci_debug_char_o       <= cptra_ss_mci_s_axi_if.wdata[7:0];
                    end
                    mci_aw_is_debug_out <= 1'b0;
                end else begin
                    mci_aw_is_debug_out <= (cptra_ss_mci_s_axi_if.awaddr[15:0] == 16'h0414);
                end
            end else if (cptra_ss_mci_s_axi_if.wvalid && cptra_ss_mci_s_axi_if.wready && mci_aw_is_debug_out) begin
                mci_debug_char_valid_o <= 1'b1;
                mci_debug_char_o       <= cptra_ss_mci_s_axi_if.wdata[7:0];
                mci_aw_is_debug_out    <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Memory Export Interfaces & Backing SRAMs
    // -------------------------------------------------------------------------
    mci_mcu_sram_if #(
        .ADDR_WIDTH(MCU_SRAM_ADDR_WIDTH)
    ) cptra_ss_mci_mcu_sram_req_if (
        .clk(core_clk),
        .rst_b(cptra_ss_rst_b_i)
    );

    mci_mcu_sram_if #(
        .ADDR_WIDTH(MCU_MBOX0_ADDR_W),
        .DATA_WIDTH(32),
        .ECC_WIDTH(7)
    ) cptra_ss_mcu_mbox0_sram_req_if (
        .clk(core_clk),
        .rst_b(cptra_ss_rst_b_i)
    );

    mci_mcu_sram_if #(
        .ADDR_WIDTH(10),
        .DATA_WIDTH(32),
        .ECC_WIDTH(7)
    ) cptra_ss_mcu_mbox1_sram_req_if (
        .clk(core_clk),
        .rst_b(cptra_ss_rst_b_i)
    );
    assign cptra_ss_mcu_mbox1_sram_req_if.resp = '0;

    axi_mem_if #(
        .ADDR_WIDTH(CPTRA_SS_ROM_MEM_ADDR_W),
        .DATA_WIDTH(CPTRA_SS_ROM_DATA_W)
    ) mcu_rom_mem_export_if (
        .clk(core_clk),
        .rst_b(cptra_ss_rst_b_i)
    );

    css_mcu0_el2_mem_if cptra_ss_mcu0_el2_mem_export ();
    el2_mem_if          cptra_ss_cptra_core_el2_mem_export ();
    abr_mem_if          abr_memory_export ();

    abr_mem_top u_abr_mem_top (
        .clk_i            (core_clk),
        .abr_memory_export(abr_memory_export.resp)
    );

    // 1. Caliptra Core VeeR EL2 ICCM + DCCM SRAM Export
    caliptra_veer_sram_export u_cptra_veer_sram (
        .el2_mem_export(cptra_ss_cptra_core_el2_mem_export)
    );

    // 2. MCU VeeR EL2 DCCM (16 KB = 4 banks x 1024 x 32-bit; ECC bypassed in CALIGHTRA_PHASE1)
    assign cptra_ss_mcu0_el2_mem_export.iccm_bank_dout            = '0;
    assign cptra_ss_mcu0_el2_mem_export.iccm_bank_ecc             = '0;
    assign cptra_ss_mcu0_el2_mem_export.dccm_bank_ecc             = '0;
    assign cptra_ss_mcu0_el2_mem_export.wb_packeddout_pre         = '0;
    assign cptra_ss_mcu0_el2_mem_export.wb_dout_pre_up            = '0;
    assign cptra_ss_mcu0_el2_mem_export.ic_tag_data_raw_packed_pre = '0;
    assign cptra_ss_mcu0_el2_mem_export.ic_tag_data_raw_pre       = '0;

    for (genvar b = 0; b < pt.DCCM_NUM_BANKS; b++) begin : g_mcu_dccm_bank
        logic [31:0] mcu_dccm_ram [0:1023];
        always_ff @(posedge core_clk) begin
            if (cptra_ss_mcu0_el2_mem_export.dccm_clken[b]) begin
                if (cptra_ss_mcu0_el2_mem_export.dccm_wren_bank[b]) begin
                    mcu_dccm_ram[cptra_ss_mcu0_el2_mem_export.dccm_addr_bank[b]] <= cptra_ss_mcu0_el2_mem_export.dccm_wr_data_bank[b];
                end else begin
                    cptra_ss_mcu0_el2_mem_export.dccm_bank_dout[b] <= mcu_dccm_ram[cptra_ss_mcu0_el2_mem_export.dccm_addr_bank[b]];
                end
            end
        end
    end

    // 3. MCU ROM (64 KB = 8192 x 64-bit, loaded by C++ testbench)
    logic [63:0] mcu_rom [0:8191] /* verilator public_flat_rd */;
    always_ff @(posedge core_clk) begin
        if (mcu_rom_mem_export_if.req.cs) begin
            if (mcu_rom_mem_export_if.req.we) begin
                mcu_rom[mcu_rom_mem_export_if.req.addr[12:0]] <= mcu_rom_mem_export_if.req.wdata.data;
            end
            mcu_rom_mem_export_if.resp.rdata.data <= mcu_rom[mcu_rom_mem_export_if.req.addr[12:0]];
        end
    end

    // 4. MCI MCU SRAM (512 KB = 131072 x 32-bit; ECC bypassed in CALIGHTRA_PHASE1)
    logic [31:0] mcu_sram [0:MCU_SRAM_DEPTH-1] /* verilator public_flat_rd */;
    logic [31:0] mcu_sram_rdata_q;
    assign cptra_ss_mci_mcu_sram_req_if.resp.rdata.ecc  = 7'h00;
    assign cptra_ss_mci_mcu_sram_req_if.resp.rdata.data = mcu_sram_rdata_q;
    always_ff @(posedge core_clk) begin
        if (cptra_ss_mci_mcu_sram_req_if.req.cs) begin
            if (cptra_ss_mci_mcu_sram_req_if.req.we) begin
                mcu_sram[cptra_ss_mci_mcu_sram_req_if.req.addr] <= cptra_ss_mci_mcu_sram_req_if.req.wdata.data;
            end else begin
                mcu_sram_rdata_q <= mcu_sram[cptra_ss_mci_mcu_sram_req_if.req.addr];
            end
        end
    end

    // 5. MCI MCU MBOX0 SRAM (4 KB = 1024 x 32-bit; ECC bypassed in CALIGHTRA_PHASE1)
    logic [31:0] mcu_mbox0_sram [0:MCU_MBOX0_DEPTH-1] /* verilator public_flat_rd */;
    logic [31:0] mcu_mbox0_sram_rdata_q;
    assign cptra_ss_mcu_mbox0_sram_req_if.resp.rdata.ecc  = 7'h00;
    assign cptra_ss_mcu_mbox0_sram_req_if.resp.rdata.data = mcu_mbox0_sram_rdata_q;
    always_ff @(posedge core_clk) begin
        if (cptra_ss_mcu_mbox0_sram_req_if.req.cs) begin
            if (cptra_ss_mcu_mbox0_sram_req_if.req.we) begin
                mcu_mbox0_sram[cptra_ss_mcu_mbox0_sram_req_if.req.addr] <= cptra_ss_mcu_mbox0_sram_req_if.req.wdata.data;
            end else begin
                mcu_mbox0_sram_rdata_q <= mcu_mbox0_sram[cptra_ss_mcu_mbox0_sram_req_if.req.addr];
            end
        end
    end

    // 6. SoC SRAM on S6_SRAM AXI Subordinate (256 KB = 65536 x 32-bit)
    logic [31:0] soc_sram [0:65535] /* verilator public_flat_rd */;
    assign cptra_ss_soc_sram_s_axi_if.awready = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.wready  = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.bresp   = 2'b00;
    assign cptra_ss_soc_sram_s_axi_if.buser   = '0;
    assign cptra_ss_soc_sram_s_axi_if.arready = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.rresp   = 2'b00;
    assign cptra_ss_soc_sram_s_axi_if.rlast   = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.ruser   = '0;
    logic [15:0] soc_sram_awaddr_lat;
    always_ff @(posedge core_clk or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b0;
            cptra_ss_soc_sram_s_axi_if.bid    <= '0;
            cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b0;
            cptra_ss_soc_sram_s_axi_if.rid    <= '0;
            cptra_ss_soc_sram_s_axi_if.rdata  <= 32'h0;
            soc_sram_awaddr_lat               <= 16'h0;
        end else begin
            if (cptra_ss_soc_sram_s_axi_if.awvalid) begin
                soc_sram_awaddr_lat            <= cptra_ss_soc_sram_s_axi_if.awaddr[17:2];
                cptra_ss_soc_sram_s_axi_if.bid <= cptra_ss_soc_sram_s_axi_if.awid;
            end
            if (cptra_ss_soc_sram_s_axi_if.wvalid) begin
                logic [15:0] wr_idx;
                wr_idx = cptra_ss_soc_sram_s_axi_if.awvalid ? cptra_ss_soc_sram_s_axi_if.awaddr[17:2] : soc_sram_awaddr_lat;
                if (cptra_ss_soc_sram_s_axi_if.wstrb[0]) soc_sram[wr_idx][7:0]   <= cptra_ss_soc_sram_s_axi_if.wdata[7:0];
                if (cptra_ss_soc_sram_s_axi_if.wstrb[1]) soc_sram[wr_idx][15:8]  <= cptra_ss_soc_sram_s_axi_if.wdata[15:8];
                if (cptra_ss_soc_sram_s_axi_if.wstrb[2]) soc_sram[wr_idx][23:16] <= cptra_ss_soc_sram_s_axi_if.wdata[23:16];
                if (cptra_ss_soc_sram_s_axi_if.wstrb[3]) soc_sram[wr_idx][31:24] <= cptra_ss_soc_sram_s_axi_if.wdata[31:24];
                cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b1;
            end else if (cptra_ss_soc_sram_s_axi_if.bready) begin
                cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b0;
            end

            if (cptra_ss_soc_sram_s_axi_if.arvalid) begin
                cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b1;
                cptra_ss_soc_sram_s_axi_if.rid    <= cptra_ss_soc_sram_s_axi_if.arid;
                cptra_ss_soc_sram_s_axi_if.rdata  <= soc_sram[cptra_ss_soc_sram_s_axi_if.araddr[17:2]];
            end else if (cptra_ss_soc_sram_s_axi_if.rready) begin
                cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b0;
            end
        end
    end

    // 7. Caliptra Core IMEM ROM (96 KB = 12288 x 64-bit, loaded by C++ testbench)
    localparam int CPTRA_IMEM_DEPTH = (96 * 1024) / 8;
    logic [63:0] imem_rom [0:CPTRA_IMEM_DEPTH-1] /* verilator public_flat_rd */;
    logic        cptra_ss_cptra_core_imem_cs_o;
    logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] cptra_ss_cptra_core_imem_addr_o;
    logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] cptra_ss_cptra_core_imem_rdata_i;
    always_ff @(posedge core_clk) begin
        if (cptra_ss_cptra_core_imem_cs_o) begin
            cptra_ss_cptra_core_imem_rdata_i <= imem_rom[cptra_ss_cptra_core_imem_addr_o];
        end
    end

    // 8. Caliptra Core Mailbox SRAM (256 KB = 65536 x 39-bit)
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_ram [0:CPTRA_MBOX_DEPTH-1] /* verilator public_flat_rd */;
    logic                                 cptra_ss_cptra_core_mbox_sram_cs_o;
    logic                                 cptra_ss_cptra_core_mbox_sram_we_o;
    logic [CPTRA_MBOX_ADDR_W-1:0]         cptra_ss_cptra_core_mbox_sram_addr_o;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] cptra_ss_cptra_core_mbox_sram_wdata_o;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] cptra_ss_cptra_core_mbox_sram_rdata_i;
    always_ff @(posedge core_clk) begin
        if (cptra_ss_cptra_core_mbox_sram_cs_o) begin
            if (cptra_ss_cptra_core_mbox_sram_we_o) begin
                mbox_ram[cptra_ss_cptra_core_mbox_sram_addr_o] <= cptra_ss_cptra_core_mbox_sram_wdata_o;
            end else begin
                cptra_ss_cptra_core_mbox_sram_rdata_i <= mbox_ram[cptra_ss_cptra_core_mbox_sram_addr_o];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Caliptra Subsystem Top Instance (caliptra_ss_top)
    // -------------------------------------------------------------------------
    logic        cptra_ss_mcu_halt_status_o;
    logic        cptra_ss_mcu_halt_req_o;
    logic        cptra_ss_mcu_halt_ack_o;
    logic [124:0] cptra_ss_cptra_generic_fw_exec_ctrl_o;
    logic        cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_o;
    logic        cptra_ss_dbg_manuf_enable_o;
    logic [63:0] cptra_ss_cptra_core_soc_prod_dbg_unlock_level_o;
    lc_ctrl_pkg::lc_tx_t cptra_ss_lc_clk_byp_req_o;
    otp_ctrl_pkg::prim_generic_otp_inputs_t cptra_ss_fuse_macro_inputs_o;
    logic        cptra_ss_i3c_recovery_payload_available_o;
    logic        cptra_ss_i3c_recovery_image_activated_o;

    logic target_i3c_scl_o, target_i3c_sda_o, target_i3c_scl_oe, target_i3c_sda_oe;
    logic ctrl_i3c_scl_o,   ctrl_i3c_sda_o,   ctrl_i3c_scl_oe,   ctrl_i3c_sda_oe;

    wire target_scl_line = target_i3c_scl_oe ? target_i3c_scl_o : 1'b1;
    wire ctrl_scl_line   = ctrl_i3c_scl_oe   ? ctrl_i3c_scl_o   : 1'b1;
    wire i3c_bus_scl     = target_scl_line & ctrl_scl_line;

    wire target_sda_line = target_i3c_sda_oe ? target_i3c_sda_o : 1'b1;
    wire ctrl_sda_line   = ctrl_i3c_sda_oe   ? ctrl_i3c_sda_o   : 1'b1;
    wire i3c_bus_sda     = target_sda_line & ctrl_sda_line;

    assign i3c_bus_scl_o = i3c_bus_scl;
    assign i3c_bus_sda_o = i3c_bus_sda;

    caliptra_ss_top #(
        .MCU_SRAM_SIZE_KB            (MCU_SRAM_SIZE_KB),
        .MCU_MBOX0_SIZE_KB           (MCU_MBOX0_SIZE_KB),
        .SET_MCU_MBOX0_AXI_USER_INTEG(SET_MCU_MBOX0_AXI_USER_INTEG),
        .MCU_MBOX0_VALID_AXI_USER    (MCU_MBOX0_VALID_AXI_USER),
        .MCU_MBOX1_SIZE_KB           (MCU_MBOX1_SIZE_KB),
        .SET_MCU_MBOX1_AXI_USER_INTEG(SET_MCU_MBOX1_AXI_USER_INTEG),
        .MCU_MBOX1_VALID_AXI_USER    (MCU_MBOX1_VALID_AXI_USER)
    ) caliptra_ss_dut (
        .cptra_ss_clk_i                       (core_clk),
        .cptra_ss_rdc_clk_cg_o                (cptra_ss_rdc_clk_cg_o),
        .cptra_ss_mcu_clk_cg_o                (cptra_ss_mcu_clk_cg_o),
        .cptra_ss_pwrgood_i                   (cptra_ss_pwrgood_i),
        .cptra_ss_rst_b_i                     (cptra_ss_rst_b_i),
        .cptra_ss_mci_cptra_rst_b_i           (cptra_ss_mci_cptra_rst_b_o),
        .cptra_ss_mci_cptra_rst_b_o           (cptra_ss_mci_cptra_rst_b_o),
        .cptra_ss_rst_b_o                     (cptra_ss_rst_b_o),
        .cptra_ss_mcu_rst_b_o                 (cptra_ss_mcu_rst_b_o),
        .cptra_ss_mcu_rst_b_i                 (cptra_ss_mcu_rst_b_o),

        .cptra_ss_warm_reset_rdc_clk_dis_o    (),
        .cptra_ss_early_warm_reset_warn_o     (),
        .cptra_ss_mcu_fw_update_rdc_clk_dis_o (),

        .cptra_ss_cptra_core_s_axi_if_w_sub   (cptra_ss_cptra_core_s_axi_if.w_sub),
        .cptra_ss_cptra_core_s_axi_if_r_sub   (cptra_ss_cptra_core_s_axi_if.r_sub),
        .cptra_ss_cptra_core_m_axi_if_w_mgr   (cptra_ss_cptra_core_m_axi_if.w_mgr),
        .cptra_ss_cptra_core_m_axi_if_r_mgr   (cptra_ss_cptra_core_m_axi_if.r_mgr),

        .cptra_ss_mci_s_axi_if_w_sub          (cptra_ss_mci_s_axi_if.w_sub),
        .cptra_ss_mci_s_axi_if_r_sub          (cptra_ss_mci_s_axi_if.r_sub),

        .cptra_ss_mcu_rom_s_axi_if_w_sub      (cptra_ss_mcu_rom_s_axi_if.w_sub),
        .cptra_ss_mcu_rom_s_axi_if_r_sub      (cptra_ss_mcu_rom_s_axi_if.r_sub),
        .mcu_rom_mem_export_if                (mcu_rom_mem_export_if),

        .cptra_ss_mcu_lsu_m_axi_if_w_mgr      (cptra_ss_mcu_lsu_m_axi_if.w_mgr),
        .cptra_ss_mcu_lsu_m_axi_if_r_mgr      (cptra_ss_mcu_lsu_m_axi_if.r_mgr),
        .cptra_ss_mcu_lsu_m_axi_if_awcache    (),
        .cptra_ss_mcu_lsu_m_axi_if_arcache    (),
        .cptra_ss_mcu_lsu_m_axi_if_awprot     (),
        .cptra_ss_mcu_lsu_m_axi_if_arprot     (),
        .cptra_ss_mcu_lsu_m_axi_if_awregion   (),
        .cptra_ss_mcu_lsu_m_axi_if_arregion   (),
        .cptra_ss_mcu_lsu_m_axi_if_awqos      (),
        .cptra_ss_mcu_lsu_m_axi_if_arqos      (),

        .cptra_ss_mcu_ifu_m_axi_if_w_mgr      (cptra_ss_mcu_ifu_m_axi_if.w_mgr),
        .cptra_ss_mcu_ifu_m_axi_if_r_mgr      (cptra_ss_mcu_ifu_m_axi_if.r_mgr),
        .cptra_ss_mcu_ifu_m_axi_if_awcache    (),
        .cptra_ss_mcu_ifu_m_axi_if_arcache    (),
        .cptra_ss_mcu_ifu_m_axi_if_awprot     (),
        .cptra_ss_mcu_ifu_m_axi_if_arprot     (),
        .cptra_ss_mcu_ifu_m_axi_if_awregion   (),
        .cptra_ss_mcu_ifu_m_axi_if_arregion   (),
        .cptra_ss_mcu_ifu_m_axi_if_awqos      (),
        .cptra_ss_mcu_ifu_m_axi_if_arqos      (),

        .cptra_ss_mcu_sb_m_axi_if_w_mgr       (cptra_ss_mcu_sb_m_axi_if.w_mgr),
        .cptra_ss_mcu_sb_m_axi_if_r_mgr       (cptra_ss_mcu_sb_m_axi_if.r_mgr),
        .cptra_ss_mcu_sb_m_axi_if_awcache     (),
        .cptra_ss_mcu_sb_m_axi_if_arcache     (),
        .cptra_ss_mcu_sb_m_axi_if_awprot      (),
        .cptra_ss_mcu_sb_m_axi_if_arprot      (),
        .cptra_ss_mcu_sb_m_axi_if_awregion    (),
        .cptra_ss_mcu_sb_m_axi_if_arregion    (),
        .cptra_ss_mcu_sb_m_axi_if_awqos       (),
        .cptra_ss_mcu_sb_m_axi_if_arqos       (),

        .cptra_ss_i3c_s_axi_if_w_sub          (cptra_ss_i3c_s_axi_if.w_sub),
        .cptra_ss_i3c_s_axi_if_r_sub          (cptra_ss_i3c_s_axi_if.r_sub),

        .cptra_ss_lc_axi_wr_req_i             (cptra_ss_lc_axi_wr_req_i),
        .cptra_ss_lc_axi_wr_rsp_o             (cptra_ss_lc_axi_wr_rsp_o),
        .cptra_ss_lc_axi_rd_req_i             (cptra_ss_lc_axi_rd_req_i),
        .cptra_ss_lc_axi_rd_rsp_o             (cptra_ss_lc_axi_rd_rsp_o),
        .cptra_ss_raw_unlock_token_hashed_i   (caliptra_ss_top_pkg::RndCnstRawUnlockTokenHashed),

        .cptra_ss_otp_core_axi_wr_req_i       (cptra_ss_otp_core_axi_wr_req_i),
        .cptra_ss_otp_core_axi_wr_rsp_o       (cptra_ss_otp_core_axi_wr_rsp_o),
        .cptra_ss_otp_core_axi_rd_req_i       (cptra_ss_otp_core_axi_rd_req_i),
        .cptra_ss_otp_core_axi_rd_rsp_o       (cptra_ss_otp_core_axi_rd_rsp_o),

        .cptra_ss_cptra_obf_key_i             (256'h0),
        .cptra_ss_cptra_csr_hmac_key_i        ('0),

        .cptra_ss_cptra_core_jtag_tck_i       (1'b0),
        .cptra_ss_cptra_core_jtag_tms_i       (1'b0),
        .cptra_ss_cptra_core_jtag_tdi_i       (1'b0),
        .cptra_ss_cptra_core_jtag_trst_n_i    (1'b0),
        .cptra_ss_cptra_core_jtag_tdo_o       (),
        .cptra_ss_cptra_core_jtag_tdoEn_o     (),
        .cptra_ss_cptra_generic_fw_exec_ctrl_o(cptra_ss_cptra_generic_fw_exec_ctrl_o),
        .cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_o(cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_o),
        .cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_i(cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_o),

        .cptra_ss_lc_ctrl_jtag_i              ('0),
        .cptra_ss_lc_ctrl_jtag_o              (),

        .cptra_ss_cptra_core_el2_mem_export   (cptra_ss_cptra_core_el2_mem_export),
        .abr_memory_export_req                (abr_memory_export.req),

        .cptra_ss_cptra_core_mbox_sram_cs_o   (cptra_ss_cptra_core_mbox_sram_cs_o),
        .cptra_ss_cptra_core_mbox_sram_we_o   (cptra_ss_cptra_core_mbox_sram_we_o),
        .cptra_ss_cptra_core_mbox_sram_addr_o (cptra_ss_cptra_core_mbox_sram_addr_o),
        .cptra_ss_cptra_core_mbox_sram_wdata_o(cptra_ss_cptra_core_mbox_sram_wdata_o),
        .cptra_ss_cptra_core_mbox_sram_rdata_i(cptra_ss_cptra_core_mbox_sram_rdata_i),

        .cptra_ss_cptra_core_imem_cs_o        (cptra_ss_cptra_core_imem_cs_o),
        .cptra_ss_cptra_core_imem_addr_o      (cptra_ss_cptra_core_imem_addr_o),
        .cptra_ss_cptra_core_imem_rdata_i     (cptra_ss_cptra_core_imem_rdata_i),

        .cptra_ss_cptra_core_bootfsm_bp_i     (1'b0),

`ifdef CALIPTRA_INTERNAL_TRNG
        .cptra_ss_cptra_core_etrng_req_o      (cptra_ss_etrng_req_o),
        .cptra_ss_cptra_core_itrng_data_i     (4'h5),
        .cptra_ss_cptra_core_itrng_valid_i    (1'b1),
`endif

        .cptra_ss_strap_mcu_lsu_axi_user_i    (32'h0000_0001),
        .cptra_ss_strap_mcu_ifu_axi_user_i    (32'h0000_0002),
        .cptra_ss_strap_mcu_sram_config_axi_user_i(32'h0000_0001),
        .cptra_ss_strap_mci_soc_config_axi_user_i (32'h0000_0001),
        .cptra_ss_mcu_halt_status_o           (cptra_ss_mcu_halt_status_o),
        .cptra_ss_mcu_halt_status_i           (cptra_ss_mcu_halt_status_o),
        .cptra_ss_mcu_halt_req_o              (cptra_ss_mcu_halt_req_o),
        .cptra_ss_mcu_halt_ack_i              (cptra_ss_mcu_halt_ack_o),
        .cptra_ss_mcu_halt_ack_o              (cptra_ss_mcu_halt_ack_o),

        .cptra_ss_mci_mcu_sram_req_if         (cptra_ss_mci_mcu_sram_req_if),
        .cptra_ss_mcu_mbox0_sram_req_if       (cptra_ss_mcu_mbox0_sram_req_if),
        .cptra_ss_mcu_mbox1_sram_req_if       (cptra_ss_mcu_mbox1_sram_req_if),
        .cptra_ss_mcu0_el2_mem_export         (cptra_ss_mcu0_el2_mem_export),

        .cptra_ss_soc_mcu_mbox0_data_avail    (),
        .cptra_ss_soc_mcu_mbox1_data_avail    (),
        .cptra_ss_mci_generic_input_wires_i   (64'h0),
        .cptra_ss_strap_mcu_reset_vector_i    (32'h8000_0000),
        .cptra_ss_mcu_no_rom_config_i         (1'b0),
        .cptra_ss_mci_boot_seq_brkpoint_i     (1'b0),
        .cptra_ss_lc_Allow_RMA_or_SCRAP_on_PPD_i(1'b0),
        .cptra_ss_FIPS_ZEROIZATION_PPD_i      (1'b0),
        .cptra_ss_mci_generic_output_wires_o  (cptra_ss_mci_generic_output_wires_o),
        .cptra_ss_all_error_fatal_o           (cptra_ss_all_error_fatal_o),
        .cptra_ss_all_error_non_fatal_o       (cptra_ss_all_error_non_fatal_o),

        .cptra_ss_mcu_ext_int                 ('0),
        .cptra_ss_mcu_jtag_tck_i              (1'b0),
        .cptra_ss_mcu_jtag_tms_i              (1'b0),
        .cptra_ss_mcu_jtag_tdi_i              (1'b0),
        .cptra_ss_mcu_jtag_trst_n_i           (1'b0),
        .cptra_ss_mcu_jtag_tdo_o              (),
        .cptra_ss_mcu_jtag_tdoEn_o            (),

        .cptra_ss_strap_caliptra_base_addr_i  (64'h0000_0000_3000_0000),
        .cptra_ss_strap_mci_base_addr_i       (64'h0000_0000_2100_0000),
        .cptra_ss_strap_recovery_ifc_base_addr_i(64'h0000_0000_2000_4100),
        .cptra_ss_strap_external_staging_area_base_addr_i(64'h0000_0000_B000_0000),
        .cptra_ss_strap_otp_fc_base_addr_i    (64'h0000_0000_7000_0000),
        .cptra_ss_strap_uds_seed_base_addr_i  (64'h0000_0000_0000_0048),
        .cptra_ss_strap_prod_debug_unlock_auth_pk_hash_reg_bank_offset_i(32'h0),
        .cptra_ss_strap_num_of_prod_debug_unlock_auth_pk_hashes_i(32'h0),
        .cptra_ss_strap_caliptra_dma_axi_user_i(32'h0000_0001),
        .cptra_ss_strap_key_release_key_size_i(16'h0040),
        .cptra_ss_strap_key_release_base_addr_i(64'h0000_0000_B000_0000),
        .cptra_ss_strap_ocp_lock_en_i         (1'b0),
        .cptra_ss_strap_generic_0_i           (32'h001E_0010),
        .cptra_ss_strap_generic_1_i           (32'h0000_0080),
        .cptra_ss_strap_generic_2_i           (32'h0),
        .cptra_ss_strap_generic_3_i           (32'h0),
        .cptra_ss_debug_intent_i              (1'b0),

        .cptra_ss_dbg_manuf_enable_o          (cptra_ss_dbg_manuf_enable_o),
        .cptra_ss_cptra_core_soc_prod_dbg_unlock_level_o(cptra_ss_cptra_core_soc_prod_dbg_unlock_level_o),

        .cptra_ss_lc_clk_byp_ack_i            (lc_ctrl_pkg::Off),
        .cptra_ss_lc_clk_byp_req_o            (cptra_ss_lc_clk_byp_req_o),
        .cptra_ss_lc_ctrl_scan_rst_ni_i       (1'b1),
        .cptra_ss_lc_sec_volatile_raw_unlock_en_i(1'b0),
        .cptra_ss_lc_esclate_scrap_state0_i   (1'b0),
        .cptra_ss_lc_esclate_scrap_state1_i   (1'b0),

        .cptra_ss_soc_dft_en_o                (),
        .cptra_ss_soc_hw_debug_en_o           (),
        .caliptra_ss_life_cycle_steady_state_o(),
        .caliptra_ss_otp_state_valid_o        (),
        .caliptra_ss_volatile_raw_unlock_success_o(),

        .cptra_ss_fuse_macro_outputs_i        ('0),
        .cptra_ss_fuse_macro_inputs_o         (cptra_ss_fuse_macro_inputs_o),

        .cptra_ss_i3c_scl_i                   (i3c_bus_scl),
        .cptra_ss_i3c_sda_i                   (i3c_bus_sda),
        .cptra_ss_i3c_scl_o                   (target_i3c_scl_o),
        .cptra_ss_i3c_sda_o                   (target_i3c_sda_o),
        .cptra_ss_i3c_scl_oe                  (target_i3c_scl_oe),
        .cptra_ss_i3c_sda_oe                  (target_i3c_sda_oe),
        .cptra_ss_sel_od_pp_o                 (),
        .cptra_ss_i3c_recovery_payload_available_o(cptra_ss_i3c_recovery_payload_available_o),
        .cptra_ss_i3c_recovery_payload_available_i(cptra_ss_i3c_recovery_payload_available_o),
        .cptra_ss_i3c_recovery_image_activated_o  (cptra_ss_i3c_recovery_image_activated_o),
        .cptra_ss_i3c_recovery_image_activated_i  (cptra_ss_i3c_recovery_image_activated_o),
        .cptra_i3c_axi_user_id_filtering_enable_i (1'b0),

        .cptra_ss_cptra_core_generic_input_wires_i (64'h0),
        .cptra_ss_cptra_core_generic_output_wires_o(cptra_ss_cptra_core_generic_output_wires_o),
        .cptra_ss_cptra_core_scan_mode_i      (1'b0),
        .cptra_ss_cptra_core_ready_for_fuses_o        (cptra_ss_ready_for_fuses_o),
        .cptra_ss_cptra_core_ready_for_mb_processing_o(cptra_ss_ready_for_mb_processing_o),
        .cptra_ss_cptra_core_ready_for_runtime_o      (cptra_ss_ready_for_runtime_o),
        .cptra_error_fatal                    (),
        .cptra_error_non_fatal                ()
    );

    // -------------------------------------------------------------------------
    // Physical 2-Wire I3C Bus & External Open-Source I3C Controller (Master)
    // -------------------------------------------------------------------------
    calightra_i3c_ctrl u_i3c_ctrl (
        .clk_i        (core_clk),
        .rst_ni       (cptra_ss_rst_b_i),
        .reg_addr_i   (i3c_ctrl_addr_i),
        .reg_wdata_i  (i3c_ctrl_wdata_i),
        .reg_we_i     (i3c_ctrl_we_i),
        .reg_re_i     (i3c_ctrl_re_i),
        .reg_rdata_o  (i3c_ctrl_rdata_o),
        .i3c_scl_i    (i3c_bus_scl),
        .i3c_scl_o    (ctrl_i3c_scl_o),
        .i3c_scl_oe_o (ctrl_i3c_scl_oe),
        .i3c_sda_i    (i3c_bus_sda),
        .i3c_sda_o    (ctrl_i3c_sda_o),
        .i3c_sda_oe_o (ctrl_i3c_sda_oe)
    );

    assign cptra_ss_fw_exec_ctrl_2_mcu_o = cptra_ss_cptra_generic_fw_exec_ctrl_2_mcu_o;
`ifndef CALIPTRA_INTERNAL_TRNG
    assign cptra_ss_etrng_req_o = caliptra_ss_dut.caliptra_top_dut.etrng_req;
`endif

endmodule
