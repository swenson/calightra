// SPDX-License-Identifier: Apache-2.0
module bus_rx_flow_test_wrapper
  import i3c_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input scl_i,  // Additional signal for SCL bus mock

    // I3C bus timings
    input logic [12:0] t_r_i,      // rise time of both SDA and SCL in clock units
    input logic [12:0] t_f_i,      // rise time of both SDA and SCL in clock units

    // Begin reading in data.
    // From now on, each SCL negedge is a data bit
    input logic scl_posedge_i,
    input logic scl_stable_high_i,
    input logic sda_i,

    input logic rx_req_bit_i,
    input logic rx_req_byte_i,
    output logic [7:0] rx_data_o,
    output logic rx_done_o,
    output logic rx_idle_o
);

  // Map individual signals to struct
  bus_rx_req_t rx_req_i;
  bus_rx_rsp_t rx_rsp_o;

  assign rx_req_i.req_bit  = rx_req_bit_i;
  assign rx_req_i.req_byte = rx_req_byte_i;

  assign rx_data_o = rx_rsp_o.data;
  assign rx_done_o = rx_rsp_o.done;
  assign rx_idle_o = rx_rsp_o.idle;

  bus_rx_flow xbus_rx_flow (
    .clk_i,
    .rst_ni,
    .scl_posedge_i,
    .scl_stable_high_i,
    .sda_i,
    .rx_req_i,
    .rx_rsp_o
  );
endmodule
