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
// calightra_ss_ulx3s_top.sv
//
// Radiona ULX3S (Lattice ECP5-85F, LFE5U-85F-6BG381C) top-level wrapper for
// the stripped Caliptra 2.1 Subsystem ("Calightra-SS"):
//   - Instantiates caliptra_ss_top (MCU VeeR EL2 + Caliptra Core VeeR EL2 +
//     MCI + OTP_CTRL + LC_CTRL + MCU ROM controller).
//   - Instantiates the open-source 5-Manager x 7-Subordinate AXI4 Crossbar
//     (calightra_ss_axi_xbar).
//   - Connects the onboard ESP32 SPI Host Bridge to AXI4 Manager M3 (m3_soc)
//     with full 32-bit addressing across the subsystem address map.
//   - Maps MCU ROM (initialized with mcu_rom.hex), MCU DCCM, MCI MCU SRAM,
//     MCU MBOX0 SRAM, and SoC SRAM to ECP5 EBR block RAMs, and exports
//     Caliptra Core ICCM/DCCM/MBOX/IMEM to the external QSPI RAM bridge.
//   - Streams MCI DEBUG_OUT / Caliptra Core UART characters to the onboard
//     FTDI USB-UART (115200 baud @ 12.5 MHz core clock) and drives the 8 LEDs.

`include "common_defines.sv"
`include "config_defines.svh"
`include "caliptra_reg_defines.svh"
`include "caliptra_macros.svh"
`include "caliptra_ss_includes.svh"

module calightra_ss_ulx3s_top
    import axi_pkg::*;
    import axi_struct_pkg::*;
    import soc_ifc_pkg::*;
    import caliptra_ss_top_pkg::*;
    import otp_ctrl_pkg::*;
    import lc_ctrl_pkg::*;
#(
    `include "css_mcu0_el2_param.vh"
) (
    input  logic       clk_25mhz,
    input  logic       btn_pwr_n,   // Active-low button (B0)
    input  logic       fire1,       // Active-high reset button (B1)

    // 8 Onboard Status LEDs
    output logic [7:0] led,

    // FTDI USB-UART (fpga TX -> ftdi_rxd)
    output logic       ftdi_rxd,
    input  logic       ftdi_txd,

    // Onboard ESP32 Control & SPI Host Interface
    output logic       wifi_en,
    output logic       wifi_gpio0,
    input  logic       esp_sck,     // wifi_gpio16
    input  logic       esp_cs_n,    // wifi_gpio5
    input  logic       esp_mosi,    // wifi_gpio17
    output logic       esp_miso,    // wifi_gpio12

    // External QSPI PSRAM / Flash Interface (Header GP/GN)
    output logic       qspi_sck,
    output logic       qspi_ce_n,
    inout  wire  [3:0] qspi_io,

    // MIPI I3C / I2C Recovery Target Interface
    //   - i3c_scl / i3c_sda (SITE F4 / E3): connected on ULX3S PCB to both
    //     onboard ESP32 (wifi_gpio26 / wifi_gpio25) and header (gp[11] / gn[11]).
    //   - ext_i3c_scl / ext_i3c_sda (SITE A7 / A8): dedicated external GPIO
    //     header pins (gp[4] / gn[4]) for external BMC/RoT host or analyzer.
    inout  wire        i3c_scl,
    inout  wire        i3c_sda,
    inout  wire        ext_i3c_scl,
    inout  wire        ext_i3c_sda
);

    localparam int MCU_SRAM_SIZE_KB  = 4;
    localparam int MCU_MBOX0_SIZE_KB = 4;
    localparam int MCU_MBOX1_SIZE_KB = 0;

    localparam int ID_W   = `CALIPTRA_AXI_ID_WIDTH;
    localparam int USER_W = `CALIPTRA_AXI_USER_WIDTH;

    localparam int MCU_SRAM_DEPTH      = (MCU_SRAM_SIZE_KB * 1024) / 4;
    localparam int MCU_SRAM_ADDR_WIDTH = $clog2(MCU_SRAM_DEPTH);
    localparam int MCU_MBOX0_DEPTH     = (MCU_MBOX0_SIZE_KB * 1024) / 4;
    localparam int MCU_MBOX0_ADDR_W    = $clog2(MCU_MBOX0_DEPTH);

    localparam [4:0]       SET_MCU_MBOX0_AXI_USER_INTEG = 5'b00000;
    localparam [4:0][31:0] MCU_MBOX0_VALID_AXI_USER     = {
        32'h0000_0003, 32'h0000_0002, 32'h0000_0001, 32'h1111_1111, 32'h0000_0000
    };
    localparam [4:0]       SET_MCU_MBOX1_AXI_USER_INTEG = 5'b00000;
    localparam [4:0][31:0] MCU_MBOX1_VALID_AXI_USER     = {
        32'h0000_0003, 32'h0000_0002, 32'h0000_0001, 32'h1111_1111, 32'h0000_0000
    };

    // Keep ESP32 enabled and in normal boot mode
    assign wifi_en    = 1'b1;
    assign wifi_gpio0 = 1'b1;

    // Generate 12.5 MHz core clock from 25 MHz oscillator
    logic clk_core = 1'b0;
    always_ff @(posedge clk_25mhz) begin
        clk_core <= ~clk_core;
    end

    // Synchronize reset buttons + allow ESP32 soft reset override
    logic esp_rst_n;
    logic [2:0] rst_sync = 3'b000;
    always_ff @(posedge clk_core) begin
        rst_sync <= {rst_sync[1:0], (btn_pwr_n & ~fire1 & esp_rst_n)};
    end
    wire cptra_ss_rst_b_i   = rst_sync[2];
    wire cptra_ss_pwrgood_i = rst_sync[2];

    // -------------------------------------------------------------------------
    // ESP32 SPI Slave -> 32-bit AXI4 Master Bridge (72-bit / 64-bit frame)
    //   Bits [63:62]: [63]=Valid, [62]=Write(1)/Read(0)
    //   Bit  [61]:    SoftResetN
    //   Bits [60:32]: {3'b0, axi_addr[28:0]} (with bit 31 = axi_addr[28])
    //   Bits [31:0]:  Write data (MOSI) / Read data from previous op (MISO)
    // -------------------------------------------------------------------------
    logic [2:0] sck_sync, csn_sync;
    logic [1:0] mosi_sync;
    always_ff @(posedge clk_core or negedge btn_pwr_n) begin
        if (!btn_pwr_n) begin
            sck_sync  <= 3'b000;
            csn_sync  <= 3'b111;
            mosi_sync <= 2'b00;
        end else begin
            sck_sync  <= {sck_sync[1:0], esp_sck};
            csn_sync  <= {csn_sync[1:0], esp_cs_n};
            mosi_sync <= {mosi_sync[0],  esp_mosi};
        end
    end

    wire sck_rise = (sck_sync[2:1] == 2'b01);
    wire sck_fall = (sck_sync[2:1] == 2'b10);
    wire csn_act  = ~csn_sync[2];

    logic [5:0]  spi_bit_cnt;
    logic [63:0] spi_rx_shreg;
    logic [63:0] spi_tx_shreg;
    logic        spi_cmd_valid;
    logic        spi_cmd_write;
    logic [31:0] spi_cmd_addr;
    logic [31:0] spi_cmd_wdata;
    logic [31:0] last_axi_rdata;
    logic [7:0]  status_byte;

    always_ff @(posedge clk_core or negedge btn_pwr_n) begin
        if (!btn_pwr_n) begin
            spi_bit_cnt   <= 6'd0;
            spi_rx_shreg  <= 64'd0;
            spi_tx_shreg  <= 64'd0;
            spi_cmd_valid <= 1'b0;
            spi_cmd_write <= 1'b0;
            spi_cmd_addr  <= 32'd0;
            spi_cmd_wdata <= 32'd0;
            esp_rst_n     <= 1'b1;
            esp_miso      <= 1'b0;
        end else begin
            spi_cmd_valid <= 1'b0;
            if (!csn_act) begin
                spi_bit_cnt  <= 6'd0;
                spi_tx_shreg <= {status_byte, 24'd0, last_axi_rdata};
                esp_miso     <= status_byte[7];
            end else begin
                if (sck_rise) begin
                    spi_rx_shreg <= {spi_rx_shreg[62:0], mosi_sync[1]};
                    spi_bit_cnt  <= spi_bit_cnt + 6'd1;
                    if (spi_bit_cnt == 6'd63) begin
                        spi_cmd_valid <= spi_rx_shreg[62];
                        spi_cmd_write <= spi_rx_shreg[61];
                        if (!spi_rx_shreg[62] && spi_rx_shreg[61]) begin
                            esp_rst_n <= spi_rx_shreg[60];
                        end
                        spi_cmd_addr  <= {spi_rx_shreg[60:31], 2'b00};
                        spi_cmd_wdata <= {spi_rx_shreg[30:0], mosi_sync[1]};
                    end
                end
                if (sck_fall) begin
                    esp_miso     <= spi_tx_shreg[63];
                    spi_tx_shreg <= {spi_tx_shreg[62:0], 1'b0};
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI4 Interfaces for Crossbar
    // -------------------------------------------------------------------------
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_ifu_m_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_lsu_m_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_sb_m_axi_if  (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_cptra_core_m_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) soc_m_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));

    axi_if #(.AW(CPTRA_SS_ROM_AXI_ADDR_W), .DW(64), .IW(ID_W), .UW(USER_W)) cptra_ss_mcu_rom_s_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_mci_s_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(`CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC)), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_cptra_core_s_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_i3c_s_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));
    axi_if #(.AW(32), .DW(32), .IW(ID_W), .UW(USER_W)) cptra_ss_soc_sram_s_axi_if (.clk(clk_core), .rst_n(cptra_ss_rst_b_i));

    axi_wr_req_t cptra_ss_otp_core_axi_wr_req_i;
    axi_wr_rsp_t cptra_ss_otp_core_axi_wr_rsp_o;
    axi_rd_req_t cptra_ss_otp_core_axi_rd_req_i;
    axi_rd_rsp_t cptra_ss_otp_core_axi_rd_rsp_o;

    axi_wr_req_t cptra_ss_lc_axi_wr_req_i;
    axi_wr_rsp_t cptra_ss_lc_axi_wr_rsp_o;
    axi_rd_req_t cptra_ss_lc_axi_rd_req_i;
    axi_rd_rsp_t cptra_ss_lc_axi_rd_rsp_o;

    // Drive soc_m_axi_if from ESP32 SPI Master Bridge
    assign soc_m_axi_if.awid    = '0;
    assign soc_m_axi_if.awlen   = 8'd0;
    assign soc_m_axi_if.awsize  = 3'd2;
    assign soc_m_axi_if.awburst = 2'b01;
    assign soc_m_axi_if.awlock  = 1'b0;
    assign soc_m_axi_if.awuser  = 32'h0000_0001;
    assign soc_m_axi_if.wstrb   = 4'hF;
    assign soc_m_axi_if.wlast   = 1'b1;
    assign soc_m_axi_if.wuser   = '0;
    assign soc_m_axi_if.bready  = 1'b1;

    assign soc_m_axi_if.arid    = '0;
    assign soc_m_axi_if.arlen   = 8'd0;
    assign soc_m_axi_if.arsize  = 3'd2;
    assign soc_m_axi_if.arburst = 2'b01;
    assign soc_m_axi_if.arlock  = 1'b0;
    assign soc_m_axi_if.aruser  = 32'h0000_0001;
    assign soc_m_axi_if.rready  = 1'b1;

    always_ff @(posedge clk_core or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            soc_m_axi_if.awaddr  <= 32'd0;
            soc_m_axi_if.awvalid <= 1'b0;
            soc_m_axi_if.wdata   <= 32'd0;
            soc_m_axi_if.wvalid  <= 1'b0;
            soc_m_axi_if.araddr  <= 32'd0;
            soc_m_axi_if.arvalid <= 1'b0;
            last_axi_rdata       <= 32'd0;
        end else begin
            if (soc_m_axi_if.awvalid && soc_m_axi_if.awready) soc_m_axi_if.awvalid <= 1'b0;
            if (soc_m_axi_if.wvalid  && soc_m_axi_if.wready)  soc_m_axi_if.wvalid  <= 1'b0;
            if (soc_m_axi_if.arvalid && soc_m_axi_if.arready) soc_m_axi_if.arvalid <= 1'b0;
            if (soc_m_axi_if.rvalid  && soc_m_axi_if.rready)  last_axi_rdata       <= soc_m_axi_if.rdata;

            if (spi_cmd_valid) begin
                if (spi_cmd_write) begin
                    soc_m_axi_if.awaddr  <= spi_cmd_addr;
                    soc_m_axi_if.awvalid <= 1'b1;
                    soc_m_axi_if.wdata   <= spi_cmd_wdata;
                    soc_m_axi_if.wvalid  <= 1'b1;
                end else begin
                    soc_m_axi_if.araddr  <= spi_cmd_addr;
                    soc_m_axi_if.arvalid <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Open-Source AXI4 Crossbar (calightra_ss_axi_xbar)
    // -------------------------------------------------------------------------
    calightra_ss_axi_xbar u_axi_xbar (
        .clk             (clk_core),
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
    // Memory Export Interfaces & ECP5 EBR Backing Memories
    // -------------------------------------------------------------------------
    mci_mcu_sram_if #(
        .ADDR_WIDTH(MCU_SRAM_ADDR_WIDTH)
    ) cptra_ss_mci_mcu_sram_req_if (
        .clk(clk_core),
        .rst_b(cptra_ss_rst_b_i)
    );

    mci_mcu_sram_if #(
        .ADDR_WIDTH(MCU_MBOX0_ADDR_W),
        .DATA_WIDTH(32),
        .ECC_WIDTH(7)
    ) cptra_ss_mcu_mbox0_sram_req_if (
        .clk(clk_core),
        .rst_b(cptra_ss_rst_b_i)
    );

    mci_mcu_sram_if #(
        .ADDR_WIDTH(10),
        .DATA_WIDTH(32),
        .ECC_WIDTH(7)
    ) cptra_ss_mcu_mbox1_sram_req_if (
        .clk(clk_core),
        .rst_b(cptra_ss_rst_b_i)
    );
    assign cptra_ss_mcu_mbox1_sram_req_if.resp = '0;

    axi_mem_if #(
        .ADDR_WIDTH(CPTRA_SS_ROM_MEM_ADDR_W),
        .DATA_WIDTH(CPTRA_SS_ROM_DATA_W)
    ) mcu_rom_mem_export_if (
        .clk(clk_core),
        .rst_b(cptra_ss_rst_b_i)
    );

    css_mcu0_el2_mem_if cptra_ss_mcu0_el2_mem_export ();
    el2_mem_if          cptra_ss_cptra_core_el2_mem_export ();
    abr_mem_if          abr_memory_export ();

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

    // 1. MCU VeeR EL2 DCCM (16 KB = 4 banks x 1024 x 32-bit in ECP5 EBR)
    assign cptra_ss_mcu0_el2_mem_export.iccm_bank_dout            = '0;
    assign cptra_ss_mcu0_el2_mem_export.iccm_bank_ecc             = '0;
    assign cptra_ss_mcu0_el2_mem_export.dccm_bank_ecc             = '0;
    assign cptra_ss_mcu0_el2_mem_export.wb_packeddout_pre         = '0;
    assign cptra_ss_mcu0_el2_mem_export.wb_dout_pre_up            = '0;
    assign cptra_ss_mcu0_el2_mem_export.ic_tag_data_raw_packed_pre = '0;
    assign cptra_ss_mcu0_el2_mem_export.ic_tag_data_raw_pre       = '0;

    for (genvar b = 0; b < pt.DCCM_NUM_BANKS; b++) begin : g_mcu_dccm_bank
        logic [31:0] mcu_dccm_ram [0:1023];
        logic [31:0] mcu_dccm_dout_q;
        always_ff @(posedge clk_core) begin
            if (cptra_ss_mcu0_el2_mem_export.dccm_clken[b]) begin
                if (cptra_ss_mcu0_el2_mem_export.dccm_wren_bank[b]) begin
                    mcu_dccm_ram[cptra_ss_mcu0_el2_mem_export.dccm_addr_bank[b][11:2]] <=
                        cptra_ss_mcu0_el2_mem_export.dccm_wr_data_bank[b];
                end else begin
                    mcu_dccm_dout_q <=
                        mcu_dccm_ram[cptra_ss_mcu0_el2_mem_export.dccm_addr_bank[b][11:2]];
                end
            end
        end
        assign cptra_ss_mcu0_el2_mem_export.dccm_bank_dout[b] = mcu_dccm_dout_q;
    end

    // 2. MCU ROM (4 KB = 512 x 64-bit in ECP5 EBR, initialized with mcu_rom.hex)
    logic [63:0] mcu_rom [0:511];
    initial begin
        $readmemh("../fw/mcu_rom.hex", mcu_rom);
    end
    always_ff @(posedge clk_core) begin
        if (mcu_rom_mem_export_if.req.cs) begin
            mcu_rom_mem_export_if.resp.rdata <= mcu_rom[mcu_rom_mem_export_if.req.addr[8:0]];
        end
    end

    // 3. MCI MCU SRAM (4 KB = 1024 x 32-bit in ECP5 EBR)
    logic [31:0] mcu_sram [0:MCU_SRAM_DEPTH-1];
    logic [31:0] mcu_sram_rdata_q;
    assign cptra_ss_mci_mcu_sram_req_if.resp.rdata.ecc  = 7'h00;
    assign cptra_ss_mci_mcu_sram_req_if.resp.rdata.data = mcu_sram_rdata_q;
    always_ff @(posedge clk_core) begin
        if (cptra_ss_mci_mcu_sram_req_if.req.cs) begin
            if (cptra_ss_mci_mcu_sram_req_if.req.we) begin
                mcu_sram[cptra_ss_mci_mcu_sram_req_if.req.addr] <= cptra_ss_mci_mcu_sram_req_if.req.wdata.data;
            end else begin
                mcu_sram_rdata_q <= mcu_sram[cptra_ss_mci_mcu_sram_req_if.req.addr];
            end
        end
    end

    // 4. MCI MCU MBOX0 SRAM (4 KB = 1024 x 32-bit in ECP5 EBR)
    logic [31:0] mcu_mbox0_sram [0:MCU_MBOX0_DEPTH-1];
    logic [31:0] mcu_mbox0_sram_rdata_q;
    assign cptra_ss_mcu_mbox0_sram_req_if.resp.rdata.ecc  = 7'h00;
    assign cptra_ss_mcu_mbox0_sram_req_if.resp.rdata.data = mcu_mbox0_sram_rdata_q;
    always_ff @(posedge clk_core) begin
        if (cptra_ss_mcu_mbox0_sram_req_if.req.cs) begin
            if (cptra_ss_mcu_mbox0_sram_req_if.req.we) begin
                mcu_mbox0_sram[cptra_ss_mcu_mbox0_sram_req_if.req.addr] <= cptra_ss_mcu_mbox0_sram_req_if.req.wdata.data;
            end else begin
                mcu_mbox0_sram_rdata_q <= mcu_mbox0_sram[cptra_ss_mcu_mbox0_sram_req_if.req.addr];
            end
        end
    end

    // 5. SoC SRAM on S6_SRAM AXI Subordinate (4 KB = 1024 x 32-bit in ECP5 EBR)
    logic [31:0] soc_sram [0:1023];
    logic [31:0] soc_sram_rdata_q;
    assign cptra_ss_soc_sram_s_axi_if.awready = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.wready  = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.bresp   = 2'b00;
    assign cptra_ss_soc_sram_s_axi_if.buser   = '0;
    assign cptra_ss_soc_sram_s_axi_if.arready = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.rresp   = 2'b00;
    assign cptra_ss_soc_sram_s_axi_if.rlast   = 1'b1;
    assign cptra_ss_soc_sram_s_axi_if.ruser   = '0;
    assign cptra_ss_soc_sram_s_axi_if.rdata   = soc_sram_rdata_q;

    always_ff @(posedge clk_core) begin
        if (cptra_ss_soc_sram_s_axi_if.awvalid && cptra_ss_soc_sram_s_axi_if.wvalid) begin
            soc_sram[cptra_ss_soc_sram_s_axi_if.awaddr[11:2]] <= cptra_ss_soc_sram_s_axi_if.wdata;
        end
        if (cptra_ss_soc_sram_s_axi_if.arvalid) begin
            soc_sram_rdata_q <= soc_sram[cptra_ss_soc_sram_s_axi_if.araddr[11:2]];
        end
    end

    always_ff @(posedge clk_core or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b0;
            cptra_ss_soc_sram_s_axi_if.bid    <= '0;
            cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b0;
            cptra_ss_soc_sram_s_axi_if.rid    <= '0;
        end else begin
            if (cptra_ss_soc_sram_s_axi_if.awvalid && cptra_ss_soc_sram_s_axi_if.wvalid) begin
                cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b1;
                cptra_ss_soc_sram_s_axi_if.bid    <= cptra_ss_soc_sram_s_axi_if.awid;
            end else if (cptra_ss_soc_sram_s_axi_if.bready) begin
                cptra_ss_soc_sram_s_axi_if.bvalid <= 1'b0;
            end

            if (cptra_ss_soc_sram_s_axi_if.arvalid) begin
                cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b1;
                cptra_ss_soc_sram_s_axi_if.rid    <= cptra_ss_soc_sram_s_axi_if.arid;
            end else if (cptra_ss_soc_sram_s_axi_if.rready) begin
                cptra_ss_soc_sram_s_axi_if.rvalid <= 1'b0;
            end
        end
    end

    // 6. Caliptra Core ICCM/DCCM/MBOX/IMEM -> External QSPI RAM Bridge
    logic [3:0] qspi_io_o, qspi_io_i, qspi_io_oe;
    assign qspi_io[0] = qspi_io_oe[0] ? qspi_io_o[0] : 1'bz;
    assign qspi_io[1] = qspi_io_oe[1] ? qspi_io_o[1] : 1'bz;
    assign qspi_io[2] = qspi_io_oe[2] ? qspi_io_o[2] : 1'bz;
    assign qspi_io[3] = qspi_io_oe[3] ? qspi_io_o[3] : 1'bz;
    assign qspi_io_i  = qspi_io;

    logic                                 cptra_ss_cptra_core_mbox_sram_cs_o;
    logic                                 cptra_ss_cptra_core_mbox_sram_we_o;
    logic [CPTRA_MBOX_ADDR_W-1:0]         cptra_ss_cptra_core_mbox_sram_addr_o;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] cptra_ss_cptra_core_mbox_sram_wdata_o;
    logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] cptra_ss_cptra_core_mbox_sram_rdata_i;
    logic                                 cptra_ss_cptra_core_imem_cs_o;
    logic [`CALIPTRA_IMEM_ADDR_WIDTH-1:0] cptra_ss_cptra_core_imem_addr_o;
    logic [`CALIPTRA_IMEM_DATA_WIDTH-1:0] cptra_ss_cptra_core_imem_rdata_i;
    logic [31:0]                          mbox_sram_rdata_32;

    assign cptra_ss_cptra_core_el2_mem_export.iccm_bank_ecc = '0;
    assign cptra_ss_cptra_core_el2_mem_export.dccm_bank_ecc = '0;
    assign cptra_ss_cptra_core_mbox_sram_rdata_i            = {7'h00, mbox_sram_rdata_32};

    calightra_spi_ram_bridge u_qspi_ram_bridge (
        .clk               (clk_core),
        .rst_n             (cptra_ss_rst_b_i),

        .iccm_clken        (cptra_ss_cptra_core_el2_mem_export.iccm_clken),
        .iccm_wren_bank    (cptra_ss_cptra_core_el2_mem_export.iccm_wren_bank),
        .iccm_addr_bank    (cptra_ss_cptra_core_el2_mem_export.iccm_addr_bank),
        .iccm_bank_wr_data (cptra_ss_cptra_core_el2_mem_export.iccm_bank_wr_data),
        .iccm_bank_dout    (cptra_ss_cptra_core_el2_mem_export.iccm_bank_dout),

        .dccm_clken        (cptra_ss_cptra_core_el2_mem_export.dccm_clken),
        .dccm_wren_bank    (cptra_ss_cptra_core_el2_mem_export.dccm_wren_bank),
        .dccm_addr_bank    (cptra_ss_cptra_core_el2_mem_export.dccm_addr_bank),
        .dccm_wr_data_bank (cptra_ss_cptra_core_el2_mem_export.dccm_wr_data_bank),
        .dccm_bank_dout    (cptra_ss_cptra_core_el2_mem_export.dccm_bank_dout),

        .mbox_sram_cs      (cptra_ss_cptra_core_mbox_sram_cs_o),
        .mbox_sram_we      (cptra_ss_cptra_core_mbox_sram_we_o),
        .mbox_sram_addr    (cptra_ss_cptra_core_mbox_sram_addr_o),
        .mbox_sram_wdata   (cptra_ss_cptra_core_mbox_sram_wdata_o[31:0]),
        .mbox_sram_rdata   (mbox_sram_rdata_32),

        .imem_cs           (cptra_ss_cptra_core_imem_cs_o),
        .imem_addr         (cptra_ss_cptra_core_imem_addr_o),
        .imem_rdata        (cptra_ss_cptra_core_imem_rdata_i),

        .qspi_sck          (qspi_sck),
        .qspi_ce_n         (qspi_ce_n),
        .qspi_io_o         (qspi_io_o),
        .qspi_io_i         (qspi_io_i),
        .qspi_io_oe        (qspi_io_oe)
    );

    // -------------------------------------------------------------------------
    // Caliptra Subsystem Top (caliptra_ss_top)
    // -------------------------------------------------------------------------
    logic cptra_ss_rst_b_o;
    logic cptra_ss_rdc_clk_cg_o;
    logic cptra_ss_mcu_clk_cg_o;
    logic cptra_ss_mci_cptra_rst_b_o;
    logic cptra_ss_mcu_rst_b_o;
    logic cptra_ss_all_error_fatal_o;
    logic cptra_ss_all_error_non_fatal_o;
    logic cptra_error_fatal;
    logic cptra_error_non_fatal;
    logic ready_for_fuses;
    logic ready_for_mb_processing;
    logic ready_for_runtime;
    logic [63:0] cptra_generic_output_wires_o;
    logic [63:0] mci_generic_output_wires_o;

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
    logic        cptra_ss_i3c_scl_i;
    logic        cptra_ss_i3c_sda_i;
    logic        cptra_ss_i3c_scl_o;
    logic        cptra_ss_i3c_sda_o;
    logic        cptra_ss_i3c_scl_oe;
    logic        cptra_ss_i3c_sda_oe;
    logic        cptra_ss_sel_od_pp_o;

    caliptra_ss_top #(
        .MCU_SRAM_SIZE_KB            (MCU_SRAM_SIZE_KB),
        .MCU_MBOX0_SIZE_KB           (MCU_MBOX0_SIZE_KB),
        .SET_MCU_MBOX0_AXI_USER_INTEG(SET_MCU_MBOX0_AXI_USER_INTEG),
        .MCU_MBOX0_VALID_AXI_USER    (MCU_MBOX0_VALID_AXI_USER),
        .MCU_MBOX1_SIZE_KB           (MCU_MBOX1_SIZE_KB),
        .SET_MCU_MBOX1_AXI_USER_INTEG(SET_MCU_MBOX1_AXI_USER_INTEG),
        .MCU_MBOX1_VALID_AXI_USER    (MCU_MBOX1_VALID_AXI_USER)
    ) caliptra_ss_dut (
        .cptra_ss_clk_i                       (clk_core),
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
        .cptra_ss_cptra_core_etrng_req_o      (),
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
        .cptra_ss_mci_generic_output_wires_o  (mci_generic_output_wires_o),
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

        .cptra_ss_i3c_scl_i                   (cptra_ss_i3c_scl_i),
        .cptra_ss_i3c_sda_i                   (cptra_ss_i3c_sda_i),
        .cptra_ss_i3c_scl_o                   (cptra_ss_i3c_scl_o),
        .cptra_ss_i3c_sda_o                   (cptra_ss_i3c_sda_o),
        .cptra_ss_i3c_scl_oe                  (cptra_ss_i3c_scl_oe),
        .cptra_ss_i3c_sda_oe                  (cptra_ss_i3c_sda_oe),
        .cptra_ss_sel_od_pp_o                 (cptra_ss_sel_od_pp_o),
        .cptra_ss_i3c_recovery_payload_available_o(cptra_ss_i3c_recovery_payload_available_o),
        .cptra_ss_i3c_recovery_payload_available_i(cptra_ss_i3c_recovery_payload_available_o),
        .cptra_ss_i3c_recovery_image_activated_o  (cptra_ss_i3c_recovery_image_activated_o),
        .cptra_ss_i3c_recovery_image_activated_i  (cptra_ss_i3c_recovery_image_activated_o),
        .cptra_i3c_axi_user_id_filtering_enable_i (1'b0),

        .cptra_ss_cptra_core_generic_input_wires_i (64'h0),
        .cptra_ss_cptra_core_generic_output_wires_o(cptra_generic_output_wires_o),
        .cptra_ss_cptra_core_scan_mode_i      (1'b0),
        .cptra_ss_cptra_core_ready_for_fuses_o        (ready_for_fuses),
        .cptra_ss_cptra_core_ready_for_mb_processing_o(ready_for_mb_processing),
        .cptra_ss_cptra_core_ready_for_runtime_o      (ready_for_runtime),
        .cptra_error_fatal                    (cptra_error_fatal),
        .cptra_error_non_fatal                (cptra_error_non_fatal)
    );

    // -------------------------------------------------------------------------
    // Bidirectional I3C / I2C Pad Drivers (ESP32 GPIO26/25 + Header GP11/GN11 & GP4/GN4)
    // -------------------------------------------------------------------------
    // SCL pad drive: open-drain low when scl_o==0, or active when scl_oe==1
    wire i3c_scl_drive_en = cptra_ss_i3c_scl_oe | ~cptra_ss_i3c_scl_o;
    // SDA pad drive: sda_oe from i3c_wrapper encodes open-drain (drive 0, high-Z 1)
    // and push-pull (drive 0 and 1 when sel_od_pp_o==1)
    wire i3c_sda_drive_en = cptra_ss_i3c_sda_oe | (cptra_ss_sel_od_pp_o & cptra_ss_i3c_sda_oe);

    assign i3c_scl     = i3c_scl_drive_en ? cptra_ss_i3c_scl_o : 1'bz;
    assign i3c_sda     = i3c_sda_drive_en ? cptra_ss_i3c_sda_o : 1'bz;
    assign ext_i3c_scl = i3c_scl_drive_en ? cptra_ss_i3c_scl_o : 1'bz;
    assign ext_i3c_sda = i3c_sda_drive_en ? cptra_ss_i3c_sda_o : 1'bz;

    // Wired-AND input across ESP32/GP11-GN11 and GP4-GN4 (both pulled up via PULLMODE=UP)
    assign cptra_ss_i3c_scl_i = i3c_scl & ext_i3c_scl;
    assign cptra_ss_i3c_sda_i = i3c_sda & ext_i3c_sda;

    // -------------------------------------------------------------------------
    // Status LEDs & FTDI 115200-Baud UART Serializer
    // -------------------------------------------------------------------------
    assign status_byte = {
        cptra_ss_all_error_fatal_o,
        cptra_error_non_fatal,
        ready_for_runtime,
        ready_for_mb_processing,
        ready_for_fuses,
        cptra_ss_mci_cptra_rst_b_o,
        cptra_ss_mcu_rst_b_o,
        cptra_ss_rst_b_o
    };

    assign led = status_byte;

    // Monitor MCI DEBUG_OUT (0x2100_0414) + Caliptra Core GENERIC_OUTPUT_WIRES[8:0]
    logic       mci_char_valid;
    logic [7:0] mci_char_data;
    always_ff @(posedge clk_core or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            mci_char_valid <= 1'b0;
            mci_char_data  <= 8'h00;
        end else begin
            mci_char_valid <= 1'b0;
            if (cptra_ss_mci_s_axi_if.awvalid && cptra_ss_mci_s_axi_if.awready &&
                cptra_ss_mci_s_axi_if.wvalid  && cptra_ss_mci_s_axi_if.wready &&
                (cptra_ss_mci_s_axi_if.awaddr[15:0] == 16'h0414)) begin
                mci_char_valid <= 1'b1;
                mci_char_data  <= cptra_ss_mci_s_axi_if.wdata[7:0];
            end
        end
    end

    localparam int CLKS_PER_BIT = 108; // 12.5 MHz / 115200 baud
    logic        uart_prev_valid;
    logic        tx_busy;
    logic [9:0]  tx_shreg;
    logic [3:0]  tx_bit_idx;
    logic [6:0]  tx_clk_cnt;

    wire cptra_char_valid = cptra_generic_output_wires_o[8] & ~uart_prev_valid;

    always_ff @(posedge clk_core or negedge cptra_ss_rst_b_i) begin
        if (!cptra_ss_rst_b_i) begin
            uart_prev_valid <= 1'b0;
            tx_busy         <= 1'b0;
            tx_shreg        <= 10'h3FF;
            tx_bit_idx      <= 4'd0;
            tx_clk_cnt      <= 7'd0;
        end else begin
            uart_prev_valid <= cptra_generic_output_wires_o[8];
            if (!tx_busy) begin
                if (mci_char_valid) begin
                    tx_busy    <= 1'b1;
                    tx_shreg   <= {1'b1, mci_char_data, 1'b0};
                    tx_bit_idx <= 4'd0;
                    tx_clk_cnt <= 7'd0;
                end else if (cptra_char_valid) begin
                    tx_busy    <= 1'b1;
                    tx_shreg   <= {1'b1, cptra_generic_output_wires_o[7:0], 1'b0};
                    tx_bit_idx <= 4'd0;
                    tx_clk_cnt <= 7'd0;
                end
            end else begin
                if (tx_clk_cnt == CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= 7'd0;
                    tx_shreg   <= {1'b1, tx_shreg[9:1]};
                    if (tx_bit_idx == 4'd9) begin
                        tx_busy <= 1'b0;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 4'd1;
                    end
                end else begin
                    tx_clk_cnt <= tx_clk_cnt + 7'd1;
                end
            end
        end
    end

    assign ftdi_rxd = tx_shreg[0] ^ (ftdi_txd & 1'b0);

endmodule
