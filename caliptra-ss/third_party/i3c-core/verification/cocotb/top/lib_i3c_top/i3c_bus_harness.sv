// SPDX-License-Identifier: Apache-2.0

/*
    I3C Bus Harness

    Model the tristate bus with proper Open-Drain and Push-Pull mode support.
    Number of controllers and targets is configurable.

    Verilator does not simulate 'x' and 'z' natively.

    For Open-Drain (OD) mode:
      - All devices use wired-AND behavior
      - A device drives low by outputting 0 with OE=1
      - A device releases the bus by setting OE=0 (or outputting 1 with OE=1)
      - Bus is pulled high by external pull-up when no device drives low

    For Push-Pull (PP) mode:
      - Device actively drives both high and low
      - Only one device should drive at a time in PP mode

    Each device provides:
      - sda_i[n]: SDA data output from device n
      - sda_oe_i[n]: SDA output enable from device n (1 = driving, 0 = hi-z)
      - sel_od_pp_i[n]: Drive mode selection (0 = Open-Drain, 1 = Push-Pull)

    For simulation BFMs (controller/target models) that don't have OE:
      - They operate in OD mode by convention
      - sda_oe is derived as: sda_oe = !sda (driving when outputting 0)

*/
module i3c_bus_harness #(
    parameter int unsigned NumDevices = 3 // Joint number of Controller and Target devices
) (
    // SDA signals per device
    input wire [NumDevices-1:0] sda_i,      // SDA data from each device
    input wire [NumDevices-1:0] sda_oe_i,   // SDA output enable from each device
    input wire [NumDevices-1:0] sel_od_pp_i, // OD/PP mode per device (0=OD, 1=PP)

    // SCL signals per device
    input wire [NumDevices-1:0] scl_i,      // SCL data from each device
    input wire [NumDevices-1:0] scl_oe_i,   // SCL output enable from each device

    // Bus outputs
    output wire sda_o,
    output wire scl_o
);

  // =========================================================================
  // SDA Bus Logic
  // =========================================================================
  // For each device, determine what it's driving on the bus:
  // - In OD mode: device can only pull low (when sda=0 and oe=1), otherwise releases
  // - In PP mode: device drives its value when oe=1
  //
  // Bus value is wired-AND of all devices that are actively driving low,
  // with pull-up providing default high.

  logic [NumDevices-1:0] sda_driving_low;

  always_comb begin
    for (int i = 0; i < NumDevices; i++) begin
      if (sda_oe_i[i]) begin
        if (sel_od_pp_i[i]) begin
          // Push-Pull mode: drive the actual value
          // For bus modeling, we still use wired-AND, so only low matters
          sda_driving_low[i] = !sda_i[i];
        end else begin
          // Open-Drain mode: can only pull low
          sda_driving_low[i] = !sda_i[i];
        end
      end else begin
        // Not driving (hi-z)
        sda_driving_low[i] = 1'b0;
      end
    end
  end

  // Bus is low if any device is driving low, otherwise pulled high
  assign sda_o = ~(|sda_driving_low);

  // =========================================================================
  // SCL Bus Logic
  // =========================================================================
  // SCL is typically only driven by the controller in OD mode
  // Simple wired-AND for SCL

  logic [NumDevices-1:0] scl_driving_low;

  always_comb begin
    for (int i = 0; i < NumDevices; i++) begin
      if (scl_oe_i[i]) begin
        scl_driving_low[i] = !scl_i[i];
      end else begin
        scl_driving_low[i] = 1'b0;
      end
    end
  end

  assign scl_o = ~(|scl_driving_low);

endmodule
