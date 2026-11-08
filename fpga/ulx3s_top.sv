// SPDX-License-Identifier: Apache-2.0
//
// ulx3s_top.sv
//
// Radiona ULX3S (LFE5U-85F-6BG381C) top-level wrapper for Calightra:
//   - Connects the onboard ESP32 via SPI to an internal AXI4-Lite Master
//     bridge (allowing the ESP32 to act as the SoC host: programming fuses,
//     uploading firmware to the mailbox, and issuing runtime commands).
//   - Connects exported ECC-free SRAMs (ICCM, DCCM, MBOX, IMEM) to
//     calightra_spi_ram_bridge over QSPI pins.
//   - Serializes Caliptra's 9-bit character log output to the ULX3S FTDI
//     USB-UART (115200 baud @ 12.5 MHz core clock).
//   - Maps Caliptra boot & error status signals to the 8 onboard LEDs.

module ulx3s_top (
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
    inout  wire  [3:0] qspi_io
);

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
    wire cptra_rst_b   = rst_sync[2];
    wire cptra_pwrgood = rst_sync[2];

    // -------------------------------------------------------------------------
    // ESP32 SPI Slave -> AXI4-Lite Master Bridge (64-bit frame protocol)
    //   Byte 0:   [7]=Write(1)/Read(0), [6]=SoftResetN, [5:0]=Reserved
    //   Byte 1-3: {6'b0, axi_addr[17:0]}
    //   Byte 4-7: Write data (MOSI) / Read data from previous transaction (MISO)
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
    logic [17:0] spi_cmd_addr;
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
            spi_cmd_addr  <= 18'd0;
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
                        spi_cmd_valid <= spi_rx_shreg[62] | spi_rx_shreg[61];
                        spi_cmd_write <= spi_rx_shreg[62];
                        esp_rst_n     <= spi_rx_shreg[60];
                        spi_cmd_addr  <= spi_rx_shreg[48:31];
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

    // AXI4-Lite Master FSM driven by spi_cmd_valid
    logic [17:0] s_axi_awaddr, s_axi_araddr;
    logic        s_axi_awvalid, s_axi_awready;
    logic [31:0] s_axi_wdata, s_axi_rdata;
    logic        s_axi_wvalid, s_axi_wready;
    logic [1:0]  s_axi_bresp, s_axi_rresp;
    logic        s_axi_bvalid, s_axi_bready;
    logic        s_axi_arvalid, s_axi_arready;
    logic        s_axi_rvalid, s_axi_rready;

    assign s_axi_bready = 1'b1;
    assign s_axi_rready = 1'b1;

    always_ff @(posedge clk_core or negedge cptra_rst_b) begin
        if (!cptra_rst_b) begin
            s_axi_awaddr   <= 18'd0;
            s_axi_awvalid  <= 1'b0;
            s_axi_wdata    <= 32'd0;
            s_axi_wvalid   <= 1'b0;
            s_axi_araddr   <= 18'd0;
            s_axi_arvalid  <= 1'b0;
            last_axi_rdata <= 32'd0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) s_axi_awvalid <= 1'b0;
            if (s_axi_wvalid  && s_axi_wready)  s_axi_wvalid  <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) s_axi_arvalid <= 1'b0;
            if (s_axi_rvalid  && s_axi_rready)  last_axi_rdata <= s_axi_rdata;

            if (spi_cmd_valid) begin
                if (spi_cmd_write) begin
                    s_axi_awaddr  <= spi_cmd_addr;
                    s_axi_awvalid <= 1'b1;
                    s_axi_wdata   <= spi_cmd_wdata;
                    s_axi_wvalid  <= 1'b1;
                end else begin
                    s_axi_araddr  <= spi_cmd_addr;
                    s_axi_arvalid <= 1'b1;
                end
            end
        end
    end

    // QSPI tri-state buffers
    logic [3:0] qspi_io_o, qspi_io_i, qspi_io_oe;
    assign qspi_io[0] = qspi_io_oe[0] ? qspi_io_o[0] : 1'bz;
    assign qspi_io[1] = qspi_io_oe[1] ? qspi_io_o[1] : 1'bz;
    assign qspi_io[2] = qspi_io_oe[2] ? qspi_io_o[2] : 1'bz;
    assign qspi_io[3] = qspi_io_oe[3] ? qspi_io_o[3] : 1'bz;
    assign qspi_io_i  = qspi_io;

    // Status & UART wires
    logic       ready_for_fuses;
    logic       ready_for_mb_processing;
    logic       ready_for_runtime;
    logic       mailbox_data_avail;
    logic       mailbox_flow_done;
    logic       cptra_error_fatal;
    logic       cptra_error_non_fatal;
    logic [8:0] uart_output;

    assign status_byte = {
        cptra_error_fatal,
        cptra_error_non_fatal,
        mailbox_flow_done,
        mailbox_data_avail,
        ready_for_runtime,
        ready_for_mb_processing,
        ready_for_fuses,
        cptra_rst_b
    };
    assign led = status_byte;

    // Simple 8N1 UART TX serializer for Caliptra's generic_output_wires[8:0]
    // (12.5 MHz / 108 = 115,740 baud)
    logic [6:0] uart_div;
    logic [3:0] uart_bit;
    logic [9:0] uart_shreg;
    logic       uart_prev_vld;
    assign ftdi_rxd = uart_shreg[0];

    always_ff @(posedge clk_core or negedge cptra_rst_b) begin
        if (!cptra_rst_b) begin
            uart_div      <= 7'd0;
            uart_bit      <= 4'd0;
            uart_shreg    <= 10'h3FF;
            uart_prev_vld <= 1'b0;
        end else begin
            uart_prev_vld <= uart_output[8];
            if (uart_bit == 4'd0) begin
                if (uart_output[8] && !uart_prev_vld) begin
                    uart_shreg <= {1'b1, uart_output[7:0], 1'b0};
                    uart_bit   <= 4'd10;
                    uart_div   <= 7'd107;
                end
            end else if (uart_div == 7'd0) begin
                uart_shreg <= {1'b1, uart_shreg[9:1]};
                uart_bit   <= uart_bit - 4'd1;
                uart_div   <= 7'd107;
            end else begin
                uart_div   <= uart_div - 7'd1;
            end
        end
    end

    // Instantiate Calightra Core + QSPI RAM Bridge
    calightra_spi_top u_calightra (
        .clk                    (clk_core),
        .cptra_pwrgood          (cptra_pwrgood),
        .cptra_rst_b            (cptra_rst_b),

        .s_axi_awaddr           (s_axi_awaddr),
        .s_axi_awvalid          (s_axi_awvalid),
        .s_axi_awready          (s_axi_awready),

        .s_axi_wdata            (s_axi_wdata),
        .s_axi_wstrb            (4'b1111),
        .s_axi_wvalid           (s_axi_wvalid),
        .s_axi_wready           (s_axi_wready),

        .s_axi_bresp            (s_axi_bresp),
        .s_axi_bvalid           (s_axi_bvalid),
        .s_axi_bready           (s_axi_bready),

        .s_axi_araddr           (s_axi_araddr),
        .s_axi_arvalid          (s_axi_arvalid),
        .s_axi_arready          (s_axi_arready),

        .s_axi_rdata            (s_axi_rdata),
        .s_axi_rresp            (s_axi_rresp),
        .s_axi_rvalid           (s_axi_rvalid),
        .s_axi_rready           (s_axi_rready),

        .qspi_sck               (qspi_sck),
        .qspi_ce_n              (qspi_ce_n),
        .qspi_io_o              (qspi_io_o),
        .qspi_io_i              (qspi_io_i),
        .qspi_io_oe             (qspi_io_oe),

        .ready_for_fuses        (ready_for_fuses),
        .ready_for_mb_processing(ready_for_mb_processing),
        .ready_for_runtime      (ready_for_runtime),
        .mailbox_data_avail     (mailbox_data_avail),
        .mailbox_flow_done      (mailbox_flow_done),
        .cptra_error_fatal      (cptra_error_fatal),
        .cptra_error_non_fatal  (cptra_error_non_fatal),
        .uart_output            (uart_output)
    );

endmodule
