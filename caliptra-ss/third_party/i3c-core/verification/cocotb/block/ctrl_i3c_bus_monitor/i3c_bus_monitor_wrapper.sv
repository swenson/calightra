module i3c_bus_monitor_wrapper
  import i3c_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic enable_i,  // Enable

    input logic scl_i,  // Bus SCL
    input logic sda_i,  // Bus SDA

    input logic [19:0] t_hd_dat_i,  // Data hold time
    input logic [19:0] t_r_i,       // Rise time
    input logic [19:0] t_f_i,       // Fall time

    input logic is_in_hdr_mode_i,  // Module is in HDR mode
    input logic is_in_hdr_err_mode_i,  // In HDR mode due to TE0/TE1 error
    input logic        hdr_timeout_en_i,  // CSR enable for 60µs recovery timer
    input logic [19:0] t_hdr_timeout_i,   // CSR threshold in clock cycles
    output logic hdr_exit_detect_o,     // Detected HDR exit condition (see: 5.2.1.1.1 of the base spec)
    output logic target_reset_detect_o  // Detected Target Reset condtition
);

  bus_state_t state;           // Gated bus state (unused here)
  bus_state_t hdr_exit_state;  // Ungated bus state for HDR exit detection

  bus_monitor xmonitor (
    .in_hdr_mode_i   (is_in_hdr_mode_i),
    .state_o         (state),
    .hdr_exit_state_o(hdr_exit_state),
    .*
  );

  // i3c_bus_monitor uses the ungated signals for HDR exit detection
  i3c_bus_monitor xi3c_monitor(
    .bus_i (hdr_exit_state),
    .*
  );

endmodule
