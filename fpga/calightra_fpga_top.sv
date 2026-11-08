// SPDX-License-Identifier: Apache-2.0
//
// calightra_fpga_top.sv
//
// Synthesizable FPGA top-level wrapper for Caliptra 2.1 ("Calightra") with:
//   - Flattened standard Verilog-2005 ports (for sv2v + Yosys + nextpnr)
//   - Exported ECC-free 32-bit SRAM interfaces for ICCM, DCCM, Mailbox, and IMEM
//   - Configurable tie-offs for unused JTAG, trace, and subsystem straps

`include "config_defines.svh"

module calightra_fpga_top
    import soc_ifc_pkg::*;
    import el2_pkg::*;
#(
    `include "el2_param.vh"
) (
    input  logic        clk,
    input  logic        cptra_pwrgood,
    input  logic        cptra_rst_b,

    // SoC AXI4 Subordinate Interface (flattened)
    input  logic [31:0] s_axi_awaddr,
    input  logic [1:0]  s_axi_awburst,
    input  logic [2:0]  s_axi_awsize,
    input  logic [7:0]  s_axi_awlen,
    input  logic [31:0] s_axi_awuser,
    input  logic [7:0]  s_axi_awid,
    input  logic        s_axi_awlock,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    input  logic        s_axi_wlast,

    output logic [1:0]  s_axi_bresp,
    output logic [7:0]  s_axi_bid,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [31:0] s_axi_araddr,
    input  logic [1:0]  s_axi_arburst,
    input  logic [2:0]  s_axi_arsize,
    input  logic [7:0]  s_axi_arlen,
    input  logic [31:0] s_axi_aruser,
    input  logic [7:0]  s_axi_arid,
    input  logic        s_axi_arlock,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic [7:0]  s_axi_rid,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // Exported ECC-Free ICCM Interface (8 banks x 4K x 32-bit = 128 KB)
    output logic [pt.ICCM_NUM_BANKS-1:0]                                       iccm_clken,
    output logic [pt.ICCM_NUM_BANKS-1:0]                                       iccm_wren_bank,
    output logic [pt.ICCM_NUM_BANKS-1:0][pt.ICCM_BITS-1:pt.ICCM_BANK_INDEX_LO] iccm_addr_bank,
    output logic [pt.ICCM_NUM_BANKS-1:0][31:0]                                 iccm_bank_wr_data,
    input  logic [pt.ICCM_NUM_BANKS-1:0][31:0]                                 iccm_bank_dout,

    // Exported ECC-Free DCCM Interface (8 banks x 4K x 32-bit = 128 KB)
    output logic [pt.DCCM_NUM_BANKS-1:0]                                       dccm_clken,
    output logic [pt.DCCM_NUM_BANKS-1:0]                                       dccm_wren_bank,
    output logic [pt.DCCM_NUM_BANKS-1:0][pt.DCCM_BITS-1:(pt.DCCM_BANK_BITS+2)] dccm_addr_bank,
    output logic [pt.DCCM_NUM_BANKS-1:0][31:0]                                 dccm_wr_data_bank,
    input  logic [pt.DCCM_NUM_BANKS-1:0][31:0]                                 dccm_bank_dout,

    // Exported ECC-Free Mailbox SRAM Interface (64K x 32-bit = 256 KB)
    output logic                          mbox_sram_cs,
    output logic                          mbox_sram_we,
    output logic [CPTRA_MBOX_ADDR_W-1:0]  mbox_sram_addr,
    output logic [31:0]                   mbox_sram_wdata,
    input  logic [31:0]                   mbox_sram_rdata,

    // Exported IMEM (ROM) Interface (12K x 64-bit = 96 KB)
    output logic                                 imem_cs,
    output logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] imem_addr,
    input  logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] imem_rdata,

    // Status & Control Signals
    output logic        ready_for_fuses,
    output logic        ready_for_mb_processing,
    output logic        ready_for_runtime,
    output logic        mailbox_data_avail,
    output logic        mailbox_flow_done,
    output logic        etrng_req,
    output logic        cptra_error_fatal,
    output logic        cptra_error_non_fatal,
    output logic [8:0]  uart_output
);

    axi_if #(
        .AW(`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)),
        .DW(`CALIPTRA_AXI_DATA_WIDTH),
        .UW(`CALIPTRA_AXI_USER_WIDTH),
        .IW(`CALIPTRA_AXI_ID_WIDTH)
    ) m_axi_bfm_if (.clk(clk), .rst_n(cptra_rst_b));

    axi_if #(
        .AW(`CALIPTRA_AXI_DMA_ADDR_WIDTH),
        .DW(CPTRA_AXI_DMA_DATA_WIDTH),
        .UW(CPTRA_AXI_DMA_USER_WIDTH),
        .IW(CPTRA_AXI_DMA_ID_WIDTH)
    ) m_axi_if (.clk(clk), .rst_n(cptra_rst_b));

    assign m_axi_bfm_if.awvalid = s_axi_awvalid;
    assign s_axi_awready        = m_axi_bfm_if.awready;
    assign m_axi_bfm_if.awaddr  = s_axi_awaddr[`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)-1:0];
    assign m_axi_bfm_if.awburst = s_axi_awburst;
    assign m_axi_bfm_if.awsize  = s_axi_awsize;
    assign m_axi_bfm_if.awlen   = s_axi_awlen;
    assign m_axi_bfm_if.awuser  = s_axi_awuser;
    assign m_axi_bfm_if.awid    = s_axi_awid;
    assign m_axi_bfm_if.awlock  = s_axi_awlock;

    assign m_axi_bfm_if.wvalid  = s_axi_wvalid;
    assign s_axi_wready         = m_axi_bfm_if.wready;
    assign m_axi_bfm_if.wdata   = s_axi_wdata;
    assign m_axi_bfm_if.wstrb   = s_axi_wstrb;
    assign m_axi_bfm_if.wlast   = s_axi_wlast;

    assign s_axi_bvalid         = m_axi_bfm_if.bvalid;
    assign m_axi_bfm_if.bready  = s_axi_bready;
    assign s_axi_bresp          = m_axi_bfm_if.bresp;
    assign s_axi_bid            = m_axi_bfm_if.bid;

    assign m_axi_bfm_if.arvalid = s_axi_arvalid;
    assign s_axi_arready        = m_axi_bfm_if.arready;
    assign m_axi_bfm_if.araddr  = s_axi_araddr[`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)-1:0];
    assign m_axi_bfm_if.arburst = s_axi_arburst;
    assign m_axi_bfm_if.arsize  = s_axi_arsize;
    assign m_axi_bfm_if.arlen   = s_axi_arlen;
    assign m_axi_bfm_if.aruser  = s_axi_aruser;
    assign m_axi_bfm_if.arid    = s_axi_arid;
    assign m_axi_bfm_if.arlock  = s_axi_arlock;

    assign s_axi_rvalid         = m_axi_bfm_if.rvalid;
    assign m_axi_bfm_if.rready  = s_axi_rready;
    assign s_axi_rdata          = m_axi_bfm_if.rdata;
    assign s_axi_rresp          = m_axi_bfm_if.rresp;
    assign s_axi_rid            = m_axi_bfm_if.rid;
    assign s_axi_rlast          = m_axi_bfm_if.rlast;

    // Tie off unused AXI manager interface
    assign m_axi_if.awready = 1'b0;
    assign m_axi_if.wready  = 1'b0;
    assign m_axi_if.bvalid  = 1'b0;
    assign m_axi_if.bid     = '0;
    assign m_axi_if.bresp   = '0;
    assign m_axi_if.buser   = '0;
    assign m_axi_if.arready = 1'b0;
    assign m_axi_if.rvalid  = 1'b0;
    assign m_axi_if.rdata   = '0;
    assign m_axi_if.rid     = '0;
    assign m_axi_if.rresp   = '0;
    assign m_axi_if.ruser   = '0;
    assign m_axi_if.rlast   = 1'b0;

    // VeeR EL2 SRAM export interface (ECC stripped)
    el2_mem_if el2_mem_export ();
    assign iccm_clken                    = el2_mem_export.iccm_clken;
    assign iccm_wren_bank                = el2_mem_export.iccm_wren_bank;
    assign iccm_addr_bank                = el2_mem_export.iccm_addr_bank;
    assign iccm_bank_wr_data             = el2_mem_export.iccm_bank_wr_data;
    assign el2_mem_export.iccm_bank_dout = iccm_bank_dout;
    assign el2_mem_export.iccm_bank_ecc  = '0;

    assign dccm_clken                    = el2_mem_export.dccm_clken;
    assign dccm_wren_bank                = el2_mem_export.dccm_wren_bank;
    assign dccm_addr_bank                = el2_mem_export.dccm_addr_bank;
    assign dccm_wr_data_bank             = el2_mem_export.dccm_wr_data_bank;
    assign el2_mem_export.dccm_bank_dout = dccm_bank_dout;
    assign el2_mem_export.dccm_bank_ecc  = '0;

    // Adams Bridge memory export interface
    abr_mem_if abr_memory_export ();
    assign abr_memory_export.w1_mem_rdata_o          = '0;
    assign abr_memory_export.mem_inst0_bank0_rdata_o = '0;
    assign abr_memory_export.mem_inst0_bank1_rdata_o = '0;
    assign abr_memory_export.mem_inst1_rdata_o       = '0;
    assign abr_memory_export.mem_inst2_rdata_o       = '0;
    assign abr_memory_export.mem_inst3_rdata_o       = '0;
    assign abr_memory_export.sk_mem_bank0_rdata_o    = '0;
    assign abr_memory_export.sk_mem_bank1_rdata_o    = '0;
    assign abr_memory_export.sig_z_mem_rdata_o       = '0;
    assign abr_memory_export.pk_mem_rdata_o          = '0;

    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_sram_wdata_full;
    assign mbox_sram_wdata = mbox_sram_wdata_full[31:0];

    logic [63:0] generic_output_wires;
    assign uart_output = generic_output_wires[8:0];

    caliptra_top caliptra_top_dut (
        .clk                        (clk),
        .cptra_pwrgood              (cptra_pwrgood),
        .cptra_rst_b                (cptra_rst_b),

        .cptra_obf_key              (256'hdeadbeef_deadbeef_deadbeef_deadbeef_deadbeef_deadbeef_deadbeef_deadbeef),
        .cptra_csr_hmac_key         ('0),
        .cptra_obf_field_entropy_vld(1'b0),
        .cptra_obf_field_entropy    ('0),
        .cptra_obf_uds_seed_vld     (1'b0),
        .cptra_obf_uds_seed         ('0),

        .jtag_tck                   (1'b0),
        .jtag_tms                   (1'b0),
        .jtag_tdi                   (1'b0),
        .jtag_trst_n                (1'b0),
        .jtag_tdo                   (),
        .jtag_tdoEn                 (),

        .s_axi_w_if                 (m_axi_bfm_if.w_sub),
        .s_axi_r_if                 (m_axi_bfm_if.r_sub),
        .m_axi_w_if                 (m_axi_if.w_mgr),
        .m_axi_r_if                 (m_axi_if.r_mgr),

        .el2_mem_export             (el2_mem_export.veer_sram_src),
        .abr_memory_export          (abr_memory_export.req),

        .mbox_sram_cs               (mbox_sram_cs),
        .mbox_sram_we               (mbox_sram_we),
        .mbox_sram_addr             (mbox_sram_addr),
        .mbox_sram_wdata            (mbox_sram_wdata_full),
        .mbox_sram_rdata            ({7'h0, mbox_sram_rdata}),

        .imem_cs                    (imem_cs),
        .imem_addr                  (imem_addr),
        .imem_rdata                 (imem_rdata),

        .ready_for_fuses            (ready_for_fuses),
        .ready_for_mb_processing    (ready_for_mb_processing),
        .ready_for_runtime          (ready_for_runtime),

        .mailbox_data_avail         (mailbox_data_avail),
        .mailbox_flow_done          (mailbox_flow_done),

        .recovery_data_avail        (1'b0),
        .recovery_image_activated   (1'b0),
        .BootFSM_BrkPoint           (1'b0),

        .cptra_error_fatal          (cptra_error_fatal),
        .cptra_error_non_fatal      (cptra_error_non_fatal),

        .etrng_req                  (etrng_req),
        .itrng_data                 (4'h0),
        .itrng_valid                (1'b0),

        .strap_ss_caliptra_base_addr                            ('0),
        .strap_ss_mci_base_addr                                 ('0),
        .strap_ss_recovery_ifc_base_addr                        ('0),
        .strap_ss_external_staging_area_base_addr               ('0),
        .strap_ss_otp_fc_base_addr                              ('0),
        .strap_ss_uds_seed_base_addr                            ('0),
        .strap_ss_key_release_base_addr                         ('0),
        .strap_ss_key_release_key_size                          ('0),
        .strap_ss_prod_debug_unlock_auth_pk_hash_reg_bank_offset('0),
        .strap_ss_num_of_prod_debug_unlock_auth_pk_hashes       ('0),
        .strap_ss_caliptra_dma_axi_user                         ('0),
        .strap_ss_strap_generic_0                               ('0),
        .strap_ss_strap_generic_1                               ('0),
        .strap_ss_strap_generic_2                               ('0),
        .strap_ss_strap_generic_3                               ('0),
        .ss_debug_intent                                        (1'b0),
        .ss_ocp_lock_en                                         (1'b0),

        .ss_dbg_manuf_enable        (),
        .ss_soc_dbg_unlock_level    (),
        .ss_generic_fw_exec_ctrl    (),

        .generic_input_wires        ('0),
        .generic_output_wires       (generic_output_wires),

        .trace_rv_i_insn_ip         (),
        .trace_rv_i_address_ip      (),
        .trace_rv_i_valid_ip        (),
        .trace_rv_i_exception_ip    (),
        .trace_rv_i_ecause_ip       (),
        .trace_rv_i_interrupt_ip    (),
        .trace_rv_i_tval_ip         (),

        .security_state             (3'b000),
        .scan_mode                  (1'b0)
    );

endmodule

// Pin-efficient FPGA top-level integrating calightra_fpga_top + calightra_spi_ram_bridge
// Total top-level IOs: 141 pins (fits in ECP5 CABGA256 / CABGA381 packages)
module calightra_spi_top
    import soc_ifc_pkg::*;
    import el2_pkg::*;
#(
    `include "el2_param.vh"
) (
    input  logic        clk,
    input  logic        cptra_pwrgood,
    input  logic        cptra_rst_b,

    // Compact AXI4-Lite Subordinate Interface (18-bit byte address)
    input  logic [17:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [17:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // External QSPI RAM / Flash Interface (ICCM + DCCM + MBOX + IMEM)
    output logic        qspi_sck,
    output logic        qspi_ce_n,
    output logic [3:0]  qspi_io_o,
    input  logic [3:0]  qspi_io_i,
    output logic [3:0]  qspi_io_oe,

    // Status & UART Output
    output logic        ready_for_fuses,
    output logic        ready_for_mb_processing,
    output logic        ready_for_runtime,
    output logic        mailbox_data_avail,
    output logic        mailbox_flow_done,
    output logic        cptra_error_fatal,
    output logic        cptra_error_non_fatal,
    output logic [8:0]  uart_output
);

    logic [pt.ICCM_NUM_BANKS-1:0]                                       iccm_clken;
    logic [pt.ICCM_NUM_BANKS-1:0]                                       iccm_wren_bank;
    logic [pt.ICCM_NUM_BANKS-1:0][pt.ICCM_BITS-1:pt.ICCM_BANK_INDEX_LO] iccm_addr_bank;
    logic [pt.ICCM_NUM_BANKS-1:0][31:0]                                 iccm_bank_wr_data;
    logic [pt.ICCM_NUM_BANKS-1:0][31:0]                                 iccm_bank_dout;

    logic [pt.DCCM_NUM_BANKS-1:0]                                       dccm_clken;
    logic [pt.DCCM_NUM_BANKS-1:0]                                       dccm_wren_bank;
    logic [pt.DCCM_NUM_BANKS-1:0][pt.DCCM_BITS-1:(pt.DCCM_BANK_BITS+2)] dccm_addr_bank;
    logic [pt.DCCM_NUM_BANKS-1:0][31:0]                                 dccm_wr_data_bank;
    logic [pt.DCCM_NUM_BANKS-1:0][31:0]                                 dccm_bank_dout;

    logic                         mbox_sram_cs;
    logic                         mbox_sram_we;
    logic [CPTRA_MBOX_ADDR_W-1:0] mbox_sram_addr;
    logic [31:0]                  mbox_sram_wdata;
    logic [31:0]                  mbox_sram_rdata;

    logic                                 imem_cs;
    logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] imem_addr;
    logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] imem_rdata;

    calightra_fpga_top u_core (
        .clk                    (clk),
        .cptra_pwrgood          (cptra_pwrgood),
        .cptra_rst_b            (cptra_rst_b),

        .s_axi_awaddr           ({14'h0, s_axi_awaddr}),
        .s_axi_awburst          (2'b01),
        .s_axi_awsize           (3'b010),
        .s_axi_awlen            (8'h00),
        .s_axi_awuser           (32'h0000_0001),
        .s_axi_awid             (8'h00),
        .s_axi_awlock           (1'b0),
        .s_axi_awvalid          (s_axi_awvalid),
        .s_axi_awready          (s_axi_awready),

        .s_axi_wdata            (s_axi_wdata),
        .s_axi_wstrb            (s_axi_wstrb),
        .s_axi_wvalid           (s_axi_wvalid),
        .s_axi_wready           (s_axi_wready),
        .s_axi_wlast            (1'b1),

        .s_axi_bresp            (s_axi_bresp),
        .s_axi_bid              (),
        .s_axi_bvalid           (s_axi_bvalid),
        .s_axi_bready           (s_axi_bready),

        .s_axi_araddr           ({14'h0, s_axi_araddr}),
        .s_axi_arburst          (2'b01),
        .s_axi_arsize           (3'b010),
        .s_axi_arlen            (8'h00),
        .s_axi_aruser           (32'h0000_0001),
        .s_axi_arid             (8'h00),
        .s_axi_arlock           (1'b0),
        .s_axi_arvalid          (s_axi_arvalid),
        .s_axi_arready          (s_axi_arready),

        .s_axi_rdata            (s_axi_rdata),
        .s_axi_rresp            (s_axi_rresp),
        .s_axi_rid              (),
        .s_axi_rlast            (),
        .s_axi_rvalid           (s_axi_rvalid),
        .s_axi_rready           (s_axi_rready),

        .iccm_clken             (iccm_clken),
        .iccm_wren_bank         (iccm_wren_bank),
        .iccm_addr_bank         (iccm_addr_bank),
        .iccm_bank_wr_data      (iccm_bank_wr_data),
        .iccm_bank_dout         (iccm_bank_dout),

        .dccm_clken             (dccm_clken),
        .dccm_wren_bank         (dccm_wren_bank),
        .dccm_addr_bank         (dccm_addr_bank),
        .dccm_wr_data_bank      (dccm_wr_data_bank),
        .dccm_bank_dout         (dccm_bank_dout),

        .mbox_sram_cs           (mbox_sram_cs),
        .mbox_sram_we           (mbox_sram_we),
        .mbox_sram_addr         (mbox_sram_addr),
        .mbox_sram_wdata        (mbox_sram_wdata),
        .mbox_sram_rdata        (mbox_sram_rdata),

        .imem_cs                (imem_cs),
        .imem_addr              (imem_addr),
        .imem_rdata             (imem_rdata),

        .ready_for_fuses        (ready_for_fuses),
        .ready_for_mb_processing(ready_for_mb_processing),
        .ready_for_runtime      (ready_for_runtime),
        .mailbox_data_avail     (mailbox_data_avail),
        .mailbox_flow_done      (mailbox_flow_done),
        .etrng_req              (),
        .cptra_error_fatal      (cptra_error_fatal),
        .cptra_error_non_fatal  (cptra_error_non_fatal),
        .uart_output            (uart_output)
    );

    calightra_spi_ram_bridge u_spi_ram (
        .clk               (clk),
        .rst_n             (cptra_rst_b),
        .iccm_clken        (iccm_clken),
        .iccm_wren_bank    (iccm_wren_bank),
        .iccm_addr_bank    (iccm_addr_bank),
        .iccm_bank_wr_data (iccm_bank_wr_data),
        .iccm_bank_dout    (iccm_bank_dout),
        .dccm_clken        (dccm_clken),
        .dccm_wren_bank    (dccm_wren_bank),
        .dccm_addr_bank    (dccm_addr_bank),
        .dccm_wr_data_bank (dccm_wr_data_bank),
        .dccm_bank_dout    (dccm_bank_dout),
        .mbox_sram_cs      (mbox_sram_cs),
        .mbox_sram_we      (mbox_sram_we),
        .mbox_sram_addr    (mbox_sram_addr),
        .mbox_sram_wdata   (mbox_sram_wdata),
        .mbox_sram_rdata   (mbox_sram_rdata),
        .imem_cs           (imem_cs),
        .imem_addr         (imem_addr),
        .imem_rdata        (imem_rdata),
        .qspi_sck          (qspi_sck),
        .qspi_ce_n         (qspi_ce_n),
        .qspi_io_o         (qspi_io_o),
        .qspi_io_i         (qspi_io_i),
        .qspi_io_oe        (qspi_io_oe)
    );

endmodule
