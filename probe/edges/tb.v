`timescale 1ns/1ps
// Reference behaviour of the emitted Verilog. Same stimulus and print format as the
// Cyclesim test in edges.ml: values 1 ns after each rising edge.
module tb;
  reg clock = 0;
  reg clear = 1;
  reg [3:0] d = 0;
  wire [3:0] r0, qf, qfr, qr1, qr2;
  integer k;

  edges dut (.clock(clock), .clear(clear), .d(d), .r0(r0), .qf(qf), .qfr(qfr), .qr1(qr1), .qr2(qr2));

  initial begin
    #4 clock = 1; #5 clock = 0; #1 clear = 0;   // one cycle of clear, covering both edges
    for (k = 1; k <= 6; k = k + 1) begin
      d = k;
      #4 clock = 1;
      #1 $display("cycle %0d: r0=%0d qf=%0d qfr=%0d qr1=%0d qr2=%0d", k, r0, qf, qfr, qr1, qr2);
      #4 clock = 0;
      #1;
    end
    $finish;
  end
endmodule
