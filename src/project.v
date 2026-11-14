/*
 * Copyright (c) 2026 dean
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout top level of the macro probe (branch probe-macros). Hand-written so that the
 * pin contract does not depend on generated port names. It adds the reset synchroniser and
 * instantiates the generated probe (src/probe_macros.v, from probe/macros).
 *
 * Reset: rst_n is asynchronous. rst_sync_n is asserted asynchronously and released through
 * two flops; everything else uses it as a synchronous clear.
 */

`default_nettype none

module tt_um_rj6cr_8npx (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  reg [1:0] rst_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else        rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_sync_n = rst_sync[1];

  probe_macros core (
      .clock     (clk),
      .rst_sync_n(rst_sync_n),
      .ui_in     (ui_in),
      .uo_out    (uo_out),
      .uio_out   (uio_out),
      .uio_oe    (uio_oe)
  );

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, 1'b0};

endmodule
