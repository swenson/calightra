// SPDX-License-Identifier: Apache-2.0
// Copyright 2019 Western Digital Corporation or its affiliates.
// Copyright 2026 Calightra Contributors.
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

`default_nettype none

`include "config_defines.svh"
`include "caliptra_macros.svh"

module calightra_verilated_wasm
    import axi_pkg::*;
    import soc_ifc_pkg::*;
(
    input bit core_clk,

    input bit cptra_pwrgood,
    input bit cptra_rst_b,

    // AXI Write Address Channel
    input bit [`CALIPTRA_AXI_ID_WIDTH-1:0] s_axi_awid,
    input bit [`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)-1:0] s_axi_awaddr,
    input bit [1:0] s_axi_awburst,
    input bit [2:0] s_axi_awsize,
    input bit [7:0] s_axi_awlen,
    input bit [`CALIPTRA_AXI_USER_WIDTH-1:0] s_axi_awuser,
    input bit s_axi_awvalid,
    output bit s_axi_awready,
    input bit s_axi_awlock,

    // AXI Write Data Channel
    input bit [`CALIPTRA_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input bit [`CALIPTRA_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input bit s_axi_wvalid,
    output bit s_axi_wready,
    input bit s_axi_wlast,

    // AXI Write Response Channel
    output bit [`CALIPTRA_AXI_ID_WIDTH-1:0] s_axi_bid,
    output bit [1:0] s_axi_bresp,
    output bit s_axi_bvalid,
    input bit s_axi_bready,

    // AXI Read Address Channel
    input bit [`CALIPTRA_AXI_ID_WIDTH-1:0] s_axi_arid,
    input bit [`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)-1:0] s_axi_araddr,
    input bit [1:0] s_axi_arburst,
    input bit [2:0] s_axi_arsize,
    input bit [7:0] s_axi_arlen,
    input bit [`CALIPTRA_AXI_USER_WIDTH-1:0] s_axi_aruser,
    input bit s_axi_arvalid,
    output bit s_axi_arready,
    input bit s_axi_arlock,

    // AXI Read Data Channel
    output bit [`CALIPTRA_AXI_ID_WIDTH-1:0] s_axi_rid,
    output bit [`CALIPTRA_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output bit [1:0] s_axi_rresp,
    output bit s_axi_rlast,
    output bit s_axi_rvalid,
    input bit s_axi_rready,

    // ROM backdoor write
    input bit ext_imem_we,
    input bit [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] ext_imem_addr,
    input bit [`CALIPTRA_IMEM_DATA_WIDTH-1:0] ext_imem_wdata,

    // SRAM backdoor writes
    input bit ext_iccm_we,
    input bit ext_dccm_we,
    input bit ext_mbox_we,
    input bit [14:0] ext_xccm_addr,
    input bit [155:0] ext_xccm_wdata,

    // Configuration inputs
    input bit [7:0][31:0] cptra_obf_key,
    input bit [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] cptra_csr_hmac_key,

    // Security state & debug straps
    input security_state_t security_state,
    input bit ss_debug_intent,

    // Physical Source for Internal TRNG
    input bit [3:0] itrng_data,
    input bit       itrng_valid,

    input bit [3:0] sram_error_injection_mode,

    // Status outputs
    output bit ready_for_fuses,
    output bit ready_for_mb_processing,
    output bit ready_for_runtime,
    output bit mailbox_data_avail,
    output bit mailbox_flow_done,

    output bit [63:0] generic_output_wires,

    output bit etrng_req,

    output bit cptra_error_fatal,
    output bit cptra_error_non_fatal
);

    import caliptra_top_tb_pkg::*;

    logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] imem_addr;
    logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] imem_rdata;
    logic imem_cs;

    logic mbox_sram_cs;
    logic mbox_sram_we;
    logic [CPTRA_MBOX_ADDR_W-1:0] mbox_sram_addr;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_sram_wdata;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_sram_rdata;

    // AXI subordinate interface
    axi_if #(
        .AW(`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)),
        .DW(`CALIPTRA_AXI_DATA_WIDTH),
        .IW(`CALIPTRA_AXI_ID_WIDTH),
        .UW(`CALIPTRA_AXI_USER_WIDTH)
    ) s_axi_if (.clk(core_clk), .rst_n(cptra_rst_b));

    assign s_axi_if.awid    = s_axi_awid;
    assign s_axi_if.awaddr  = s_axi_awaddr;
    assign s_axi_if.awburst = s_axi_awburst;
    assign s_axi_if.awsize  = s_axi_awsize;
    assign s_axi_if.awlen   = s_axi_awlen;
    assign s_axi_if.awuser  = s_axi_awuser;
    assign s_axi_if.awvalid = s_axi_awvalid;
    assign s_axi_awready    = s_axi_if.awready;
    assign s_axi_if.awlock  = s_axi_awlock;

    assign s_axi_if.wdata   = s_axi_wdata;
    assign s_axi_if.wstrb   = s_axi_wstrb;
    assign s_axi_if.wvalid  = s_axi_wvalid;
    assign s_axi_wready     = s_axi_if.wready;
    assign s_axi_if.wlast   = s_axi_wlast;

    assign s_axi_bid        = s_axi_if.bid;
    assign s_axi_bresp      = s_axi_if.bresp;
    assign s_axi_bvalid     = s_axi_if.bvalid;
    assign s_axi_if.bready  = s_axi_bready;

    assign s_axi_if.arid    = s_axi_arid;
    assign s_axi_if.araddr  = s_axi_araddr;
    assign s_axi_if.arburst = s_axi_arburst;
    assign s_axi_if.arsize  = s_axi_arsize;
    assign s_axi_if.arlen   = s_axi_arlen;
    assign s_axi_if.aruser  = s_axi_aruser;
    assign s_axi_if.arvalid = s_axi_arvalid;
    assign s_axi_arready    = s_axi_if.arready;
    assign s_axi_if.arlock  = s_axi_arlock;

    assign s_axi_rid        = s_axi_if.rid;
    assign s_axi_rdata      = s_axi_if.rdata;
    assign s_axi_rresp      = s_axi_if.rresp;
    assign s_axi_rlast      = s_axi_if.rlast;
    assign s_axi_rvalid     = s_axi_if.rvalid;
    assign s_axi_if.rready  = s_axi_rready;

    // AXI manager interface for DMA (tie off in standalone core mode)
    axi_if #(
        .AW(`CALIPTRA_AXI_DMA_ADDR_WIDTH),
        .DW(CPTRA_AXI_DMA_DATA_WIDTH),
        .IW(CPTRA_AXI_DMA_ID_WIDTH),
        .UW(CPTRA_AXI_DMA_USER_WIDTH)
    ) m_axi_if (.clk(core_clk), .rst_n(cptra_rst_b));

    assign m_axi_if.arready = 1'b1;
    assign m_axi_if.rdata   = '0;
    assign m_axi_if.rresp   = AXI_RESP_DECERR;
    assign m_axi_if.rid     = '0;
    assign m_axi_if.ruser   = '0;
    assign m_axi_if.rlast   = 1'b1;
    assign m_axi_if.rvalid  = 1'b0;

    assign m_axi_if.awready = 1'b1;
    assign m_axi_if.wready  = 1'b1;
    assign m_axi_if.bresp   = AXI_RESP_DECERR;
    assign m_axi_if.bid     = '0;
    assign m_axi_if.buser   = '0;
    assign m_axi_if.bvalid  = 1'b0;

    el2_mem_if cpu_mem ();
    abr_mem_if abr_memory_export();

    caliptra_top caliptra_top_dut (
        .cptra_pwrgood              (cptra_pwrgood),
        .cptra_rst_b                (cptra_rst_b),
        .clk                        (core_clk),

        .cptra_obf_key              (cptra_obf_key),
        .cptra_csr_hmac_key         (cptra_csr_hmac_key),

        .cptra_obf_uds_seed_vld     (1'b0),
        .cptra_obf_uds_seed         ('0),
        .cptra_obf_field_entropy_vld(1'b0),
        .cptra_obf_field_entropy    ('0),

        .jtag_tck(1'b0),
        .jtag_tdi(1'b0),
        .jtag_tms(1'b0),
        .jtag_trst_n(1'b0),
        .jtag_tdo(),
        .jtag_tdoEn(),

        .s_axi_w_if(s_axi_if.w_sub),
        .s_axi_r_if(s_axi_if.r_sub),

        .m_axi_w_if(m_axi_if.w_mgr),
        .m_axi_r_if(m_axi_if.r_mgr),

        .el2_mem_export(cpu_mem.veer_sram_src),
        .abr_memory_export(abr_memory_export.req),

        .ready_for_fuses(ready_for_fuses),
        .ready_for_mb_processing(ready_for_mb_processing),
        .ready_for_runtime(ready_for_runtime),

        .mbox_sram_cs(mbox_sram_cs),
        .mbox_sram_we(mbox_sram_we),
        .mbox_sram_addr(mbox_sram_addr),
        .mbox_sram_wdata(mbox_sram_wdata),
        .mbox_sram_rdata(mbox_sram_rdata),

        .imem_cs(imem_cs),
        .imem_addr(imem_addr),
        .imem_rdata(imem_rdata),

        .mailbox_data_avail(mailbox_data_avail),
        .mailbox_flow_done(mailbox_flow_done),
        .BootFSM_BrkPoint(1'b0),

        .recovery_data_avail(1'b0),
        .recovery_image_activated(1'b0),

        .generic_input_wires(64'h0),
        .generic_output_wires(generic_output_wires),

        .cptra_error_fatal(cptra_error_fatal),
        .cptra_error_non_fatal(cptra_error_non_fatal),
        .etrng_req(etrng_req),
        .itrng_data(itrng_data),
        .itrng_valid(itrng_valid),

        .strap_ss_caliptra_base_addr                            (64'h0),
        .strap_ss_mci_base_addr                                 (64'h0),
        .strap_ss_recovery_ifc_base_addr                        (64'h0),
        .strap_ss_external_staging_area_base_addr               (64'h0),
        .strap_ss_otp_fc_base_addr                              (64'h0),
        .strap_ss_uds_seed_base_addr                            (64'h0),
        .strap_ss_key_release_base_addr                         (64'h0),
        .strap_ss_key_release_key_size                          (16'h0),
        .strap_ss_prod_debug_unlock_auth_pk_hash_reg_bank_offset(32'h0),
        .strap_ss_num_of_prod_debug_unlock_auth_pk_hashes       (32'h0),
        .strap_ss_caliptra_dma_axi_user                         (32'h0),
        .strap_ss_strap_generic_0                               (32'h0),
        .strap_ss_strap_generic_1                               (32'h0),
        .strap_ss_strap_generic_2                               (32'h0),
        .strap_ss_strap_generic_3                               (32'h0),
        .ss_debug_intent                                        (ss_debug_intent),

        .ss_ocp_lock_en                                         (1'b0),

        .ss_dbg_manuf_enable    (),
        .ss_soc_dbg_unlock_level(),
        .ss_generic_fw_exec_ctrl(),

        .trace_rv_i_insn_ip     (),
        .trace_rv_i_address_ip  (),
        .trace_rv_i_valid_ip    (),
        .trace_rv_i_exception_ip(),
        .trace_rv_i_ecause_ip   (),
        .trace_rv_i_interrupt_ip(),
        .trace_rv_i_tval_ip     (),

        .security_state(security_state),
        .scan_mode(1'b0)
    );

    el2_mem_if real_mem();

    caliptra_veer_sram_export veer_sram_export_inst (
        .sram_error_injection_mode(sram_error_injection_mode),
        .el2_mem_export(real_mem.veer_sram_sink)
    );

    assign real_mem.clk = core_clk;
    assign real_mem.iccm_clken = cpu_mem.iccm_clken | ext_iccm_we;
    assign real_mem.iccm_wren_bank = cpu_mem.iccm_wren_bank | ext_iccm_we;
    assign real_mem.iccm_addr_bank = ext_iccm_we ? {ext_xccm_addr[12:0], ext_xccm_addr[12:0], ext_xccm_addr[12:0], ext_xccm_addr[12:0]} : cpu_mem.iccm_addr_bank;
    assign real_mem.iccm_bank_wr_data = ext_iccm_we ? ext_xccm_wdata[31:0] : cpu_mem.iccm_bank_wr_data;
    assign real_mem.iccm_bank_wr_ecc = ext_iccm_we ? ext_xccm_wdata[38:32] : cpu_mem.iccm_bank_wr_ecc;
    assign cpu_mem.iccm_bank_dout = real_mem.iccm_bank_dout;
    assign cpu_mem.iccm_bank_ecc = real_mem.iccm_bank_ecc;

    assign real_mem.dccm_clken = cpu_mem.dccm_clken | ext_dccm_we;
    assign real_mem.dccm_wren_bank = cpu_mem.dccm_wren_bank | ext_dccm_we;
    assign real_mem.dccm_addr_bank = ext_dccm_we ? {ext_xccm_addr[12:0], ext_xccm_addr[12:0], ext_xccm_addr[12:0], ext_xccm_addr[12:0]} : cpu_mem.dccm_addr_bank;
    assign real_mem.dccm_wr_data_bank = ext_dccm_we ? ext_xccm_wdata[31:0] : cpu_mem.dccm_wr_data_bank;
    assign real_mem.dccm_wr_ecc_bank = ext_dccm_we ? ext_xccm_wdata[38:32] : cpu_mem.dccm_wr_ecc_bank;
    assign cpu_mem.dccm_bank_dout = real_mem.dccm_bank_dout;
    assign cpu_mem.dccm_bank_ecc = real_mem.dccm_bank_ecc;

`ifdef CALIGHTRA_PHASE1
    assign mbox_sram_rdata[CPTRA_MBOX_DATA_AND_ECC_W-1:CPTRA_MBOX_DATA_W] = '0;
    caliptra_sram #(
        .DATA_WIDTH(CPTRA_MBOX_DATA_W),
        .DEPTH     (CPTRA_MBOX_DEPTH )
    ) mbox_ram1 (
        .clk_i(core_clk),
        .cs_i(mbox_sram_cs | ext_mbox_we),
        .we_i(mbox_sram_we | ext_mbox_we),
        .addr_i(ext_mbox_we ? ext_xccm_addr : mbox_sram_addr),
        .wdata_i(ext_mbox_we ? ext_xccm_wdata[CPTRA_MBOX_DATA_W-1:0] : mbox_sram_wdata[CPTRA_MBOX_DATA_W-1:0]),
        .rdata_o(mbox_sram_rdata[CPTRA_MBOX_DATA_W-1:0])
    );
`else
    caliptra_sram #(
        .DATA_WIDTH(CPTRA_MBOX_DATA_AND_ECC_W),
        .DEPTH     (CPTRA_MBOX_DEPTH         )
    ) mbox_ram1 (
        .clk_i(core_clk),
        .cs_i(mbox_sram_cs | ext_mbox_we),
        .we_i(mbox_sram_we | ext_mbox_we),
        .addr_i(ext_mbox_we ? ext_xccm_addr : mbox_sram_addr),
        .wdata_i(ext_mbox_we ? ext_xccm_wdata[CPTRA_MBOX_DATA_AND_ECC_W-1:0] : mbox_sram_wdata),
        .rdata_o(mbox_sram_rdata)
    );
`endif

    // ROM IMEM
    caliptra_sram #(
        .DEPTH     (`CALIPTRA_IMEM_DEPTH     ),
        .DATA_WIDTH(`CALIPTRA_IMEM_DATA_WIDTH),
        .ADDR_WIDTH(`CALIPTRA_IMEM_ADDR_WIDTH)
    ) imem_inst1 (
        .clk_i   (core_clk),
        .cs_i    (imem_cs | ext_imem_we),
        .we_i    (ext_imem_we),
        .addr_i  (ext_imem_we ? ext_imem_addr : imem_addr),
        .wdata_i (ext_imem_wdata),
        .rdata_o (imem_rdata)
    );

    // ABR (Adams Bridge / ML-DSA & ML-KEM) Dual-Port SRAMs
    import abr_params_pkg::*;

    abr_1r1w_ram #(.DEPTH(ABR_MEM_W1_DEPTH), .DATA_WIDTH(ABR_MEM_W1_DATA_W)) abr_w1_mem (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.w1_mem_we_i),
        .waddr_i (abr_memory_export.w1_mem_waddr_i),
        .wdata_i (abr_memory_export.w1_mem_wdata_i),
        .re_i    (abr_memory_export.w1_mem_re_i),
        .raddr_i (abr_memory_export.w1_mem_raddr_i),
        .rdata_o (abr_memory_export.w1_mem_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(ABR_MEM_INST0_DEPTH), .DATA_WIDTH(ABR_MEM_INST0_DATA_W)) abr_mem_inst0_bank0 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.mem_inst0_bank0_we_i),
        .waddr_i (abr_memory_export.mem_inst0_bank0_waddr_i),
        .wdata_i (abr_memory_export.mem_inst0_bank0_wdata_i),
        .re_i    (abr_memory_export.mem_inst0_bank0_re_i),
        .raddr_i (abr_memory_export.mem_inst0_bank0_raddr_i),
        .rdata_o (abr_memory_export.mem_inst0_bank0_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(ABR_MEM_INST0_DEPTH), .DATA_WIDTH(ABR_MEM_INST0_DATA_W)) abr_mem_inst0_bank1 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.mem_inst0_bank1_we_i),
        .waddr_i (abr_memory_export.mem_inst0_bank1_waddr_i),
        .wdata_i (abr_memory_export.mem_inst0_bank1_wdata_i),
        .re_i    (abr_memory_export.mem_inst0_bank1_re_i),
        .raddr_i (abr_memory_export.mem_inst0_bank1_raddr_i),
        .rdata_o (abr_memory_export.mem_inst0_bank1_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(ABR_MEM_INST1_DEPTH), .DATA_WIDTH(ABR_MEM_INST1_DATA_W)) abr_mem_inst1 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.mem_inst1_we_i),
        .waddr_i (abr_memory_export.mem_inst1_waddr_i),
        .wdata_i (abr_memory_export.mem_inst1_wdata_i),
        .re_i    (abr_memory_export.mem_inst1_re_i),
        .raddr_i (abr_memory_export.mem_inst1_raddr_i),
        .rdata_o (abr_memory_export.mem_inst1_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(ABR_MEM_INST2_DEPTH), .DATA_WIDTH(ABR_MEM_INST2_DATA_W)) abr_mem_inst2 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.mem_inst2_we_i),
        .waddr_i (abr_memory_export.mem_inst2_waddr_i),
        .wdata_i (abr_memory_export.mem_inst2_wdata_i),
        .re_i    (abr_memory_export.mem_inst2_re_i),
        .raddr_i (abr_memory_export.mem_inst2_raddr_i),
        .rdata_o (abr_memory_export.mem_inst2_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(ABR_MEM_INST3_DEPTH), .DATA_WIDTH(ABR_MEM_INST3_DATA_W)) abr_mem_inst3 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.mem_inst3_we_i),
        .waddr_i (abr_memory_export.mem_inst3_waddr_i),
        .wdata_i (abr_memory_export.mem_inst3_wdata_i),
        .re_i    (abr_memory_export.mem_inst3_re_i),
        .raddr_i (abr_memory_export.mem_inst3_raddr_i),
        .rdata_o (abr_memory_export.mem_inst3_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(SK_MEM_BANK_DEPTH), .DATA_WIDTH(SK_MEM_BANK_DATA_W)) abr_sk_mem_bank0 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.sk_mem_bank0_we_i),
        .waddr_i (abr_memory_export.sk_mem_bank0_waddr_i),
        .wdata_i (abr_memory_export.sk_mem_bank0_wdata_i),
        .re_i    (abr_memory_export.sk_mem_bank0_re_i),
        .raddr_i (abr_memory_export.sk_mem_bank0_raddr_i),
        .rdata_o (abr_memory_export.sk_mem_bank0_rdata_o)
    );

    abr_1r1w_ram #(.DEPTH(SK_MEM_BANK_DEPTH), .DATA_WIDTH(SK_MEM_BANK_DATA_W)) abr_sk_mem_bank1 (
        .clk_i   (core_clk),
        .we_i    (abr_memory_export.sk_mem_bank1_we_i),
        .waddr_i (abr_memory_export.sk_mem_bank1_waddr_i),
        .wdata_i (abr_memory_export.sk_mem_bank1_wdata_i),
        .re_i    (abr_memory_export.sk_mem_bank1_re_i),
        .raddr_i (abr_memory_export.sk_mem_bank1_raddr_i),
        .rdata_o (abr_memory_export.sk_mem_bank1_rdata_o)
    );

    abr_1r1w_be_ram #(.DEPTH(SIG_Z_MEM_DEPTH), .DATA_WIDTH(SIG_Z_MEM_DATA_W)) abr_sig_z_mem (
        .clk_i    (core_clk),
        .we_i     (abr_memory_export.sig_z_mem_we_i),
        .wstrobe_i(abr_memory_export.sig_z_mem_wstrobe_i),
        .waddr_i  (abr_memory_export.sig_z_mem_waddr_i),
        .wdata_i  (abr_memory_export.sig_z_mem_wdata_i),
        .re_i     (abr_memory_export.sig_z_mem_re_i),
        .raddr_i  (abr_memory_export.sig_z_mem_raddr_i),
        .rdata_o  (abr_memory_export.sig_z_mem_rdata_o)
    );

    abr_1r1w_be_ram #(.DEPTH(PK_MEM_DEPTH), .DATA_WIDTH(PK_MEM_DATA_W)) abr_pk_mem (
        .clk_i    (core_clk),
        .we_i     (abr_memory_export.pk_mem_we_i),
        .wstrobe_i(abr_memory_export.pk_mem_wstrobe_i),
        .waddr_i  (abr_memory_export.pk_mem_waddr_i),
        .wdata_i  (abr_memory_export.pk_mem_wdata_i),
        .re_i     (abr_memory_export.pk_mem_re_i),
        .raddr_i  (abr_memory_export.pk_mem_raddr_i),
        .rdata_o  (abr_memory_export.pk_mem_rdata_o)
    );

    //=========================================================================-
    // Zero-cycle DPI-C Backdoor Accessors for WASM Browser UI
    //=========================================================================-

    export "DPI-C" function wasm_write_rom_u64;
    function void wasm_write_rom_u64(input int word_addr, input int unsigned lo, input int unsigned hi);
        if (word_addr >= 0 && word_addr < `CALIPTRA_IMEM_DEPTH) begin
            imem_inst1.ram[word_addr][0] = lo[7:0];
            imem_inst1.ram[word_addr][1] = lo[15:8];
            imem_inst1.ram[word_addr][2] = lo[23:16];
            imem_inst1.ram[word_addr][3] = lo[31:24];
            imem_inst1.ram[word_addr][4] = hi[7:0];
            imem_inst1.ram[word_addr][5] = hi[15:8];
            imem_inst1.ram[word_addr][6] = hi[23:16];
            imem_inst1.ram[word_addr][7] = hi[31:24];
        end
    endfunction

    export "DPI-C" function wasm_peek_kv_entry;
    function int unsigned wasm_peek_kv_entry(input int slot, input int dword);
        if (slot >= 0 && slot < 24 && dword >= 0 && dword < 16) begin
            return caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_ENTRY[slot][dword].data.value;
        end
        return 32'h0;
    endfunction

    export "DPI-C" function wasm_peek_kv_ctrl;
    function int unsigned wasm_peek_kv_ctrl(input int slot);
        if (slot >= 0 && slot < 24) begin
            return {
                10'b0,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].last_dword.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].dest_valid.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].rsvd1.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].rsvd0.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].clear.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].lock_use.value,
                caliptra_top_dut.key_vault1.kv_reg1.field_storage.KEY_CTRL[slot].lock_wr.value
            };
        end
        return 32'h0;
    endfunction

    export "DPI-C" function wasm_peek_pcr_entry;
    function int unsigned wasm_peek_pcr_entry(input int slot, input int dword);
        if (slot >= 0 && slot < 32 && dword >= 0 && dword < 12) begin
            return caliptra_top_dut.pcr_vault1.pv_reg1.field_storage.PCR_ENTRY[slot][dword].data.value;
        end
        return 32'h0;
    endfunction

    export "DPI-C" function wasm_peek_pcr_ctrl;
    function int unsigned wasm_peek_pcr_ctrl(input int slot);
        if (slot >= 0 && slot < 32) begin
            return {
                24'b0,
                caliptra_top_dut.pcr_vault1.pv_reg1.field_storage.PCR_CTRL[slot].rsvd1.value,
                caliptra_top_dut.pcr_vault1.pv_reg1.field_storage.PCR_CTRL[slot].rsvd0.value,
                caliptra_top_dut.pcr_vault1.pv_reg1.field_storage.PCR_CTRL[slot].clear.value,
                caliptra_top_dut.pcr_vault1.pv_reg1.field_storage.PCR_CTRL[slot].lock.value
            };
        end
        return 32'h0;
    endfunction

    export "DPI-C" function wasm_peek_status_reg;
    function int unsigned wasm_peek_status_reg(input int id);
        case (id)
            0: return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_BOOT_STATUS.status.value;
            1: return {
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FLOW_STATUS.mailbox_flow_done.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.hwif_in.CPTRA_FLOW_STATUS.ready_for_fuses.next,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FLOW_STATUS.ready_for_runtime.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FLOW_STATUS.ready_for_mb_processing.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.hwif_in.CPTRA_FLOW_STATUS.boot_fsm_ps.next,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FLOW_STATUS.idevid_csr_ready.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FLOW_STATUS.status.value
            };
            2: return {
                28'b0,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_FATAL.crypto_err.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_FATAL.nmi_pin.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_FATAL.dccm_ecc_unc.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_FATAL.iccm_ecc_unc.value
            };
            3: return {
                29'b0,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_NON_FATAL.mbox_ecc_unc.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_NON_FATAL.mbox_prot_ooo.value,
                caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_HW_ERROR_NON_FATAL.mbox_prot_no_lock.value
            };
            4: return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FW_ERROR_FATAL.error_code.value;
            5: return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FW_ERROR_NON_FATAL.error_code.value;
            6, 7, 8, 9, 10, 11, 12, 13: begin
                int ext_idx;
                ext_idx = id - 6;
                return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_FW_EXTENDED_ERROR_INFO[ext_idx].error_info.value;
            end
            default: return 32'h0;
        endcase
    endfunction

    export "DPI-C" function wasm_peek_fuse_reg;
    function int unsigned wasm_peek_fuse_reg(input int id, input int idx);
        case (id)
            0: if (idx >= 0 && idx < 12) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_vendor_pk_hash[idx].hash.value;
            1: if (idx >= 0 && idx < 12) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.CPTRA_OWNER_PK_HASH[idx].hash.value;
            2: return {28'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_ecc_revocation.ecc_revocation.value};
            3: return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_fmc_key_manifest_svn.svn.value;
            4: if (idx >= 0 && idx < 4) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_runtime_svn[idx].svn.value;
            5: return {31'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_anti_rollback_disable.dis.value};
            6: if (idx >= 0 && idx < 24) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_idevid_cert_attr[idx].cert.value;
            7: if (idx >= 0 && idx < 4) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_idevid_manuf_hsm_id[idx].hsm_id.value;
            8: return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_lms_revocation.lms_revocation.value;
            9: return {28'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_mldsa_revocation.mldsa_revocation.value};
            10: return {16'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_soc_stepping_id.soc_stepping_id.value};
            11: if (idx >= 0 && idx < 16) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_manuf_dbg_unlock_token[idx].token.value;
            12: return {30'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_pqc_key_type.key_type.value};
            13: if (idx >= 0 && idx < 4) return caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_soc_manifest_svn[idx].svn.value;
            14: return {24'b0, caliptra_top_dut.soc_ifc_top1.i_soc_ifc_reg.field_storage.fuse_soc_manifest_max_svn.svn.value};
            default: return 32'h0;
        endcase
        return 32'h0;
    endfunction

endmodule
