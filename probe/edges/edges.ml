(* Probe: what does Cyclesim do with a register clocked on the falling edge?

   d -> r0 (rising) -> qf (FALLING) -> qfr (rising)
              r0    -> qr1 (rising) -> qr2 (rising)

   In hardware qf is captured half a cycle after r0, so qfr follows r0 by one cycle, like
   qr1. A simulator that treats the falling-edge register as a rising-edge one shows qfr
   following r0 by two cycles, like qr2. run.sh simulates the emitted Verilog with Icarus
   for the reference behaviour. *)
open Core
open Hardcaml
open Signal

let circuit () =
  let clock = input "clock" 1 in
  let clear = input "clear" 1 in
  let d = input "d" 4 in
  let rise = Reg_spec.create ~clock ~clear () in
  let fall = Reg_spec.override ~clock_edge:Edge.Falling rise in
  let r0 = reg rise d in
  let qf = reg fall r0 in
  let qfr = reg rise qf in
  let qr1 = reg rise r0 in
  let qr2 = reg rise qr1 in
  Circuit.create_exn
    ~name:"edges"
    [ output "r0" r0; output "qf" qf; output "qfr" qfr; output "qr1" qr1; output "qr2" qr2 ]
;;

let%expect_test "emitted Verilog" =
  Rtl.print Verilog (circuit ());
  [%expect {|
    module edges (
        clear,
        clock,
        d,
        r0,
        qf,
        qfr,
        qr1,
        qr2
    );

        input clear;
        input clock;
        input [3:0] d;
        output [3:0] r0;
        output [3:0] qf;
        output [3:0] qfr;
        output [3:0] qr1;
        output [3:0] qr2;

        wire [3:0] _17;
        reg [3:0] _18;
        reg [3:0] _15;
        reg [3:0] _24;
        reg [3:0] _21;
        wire vdd;
        reg [3:0] _12;
        assign _17 = 4'b0000;
        always @(posedge clock) begin
            if (clear)
                _18 <= _17;
            else
                _18 <= _15;
        end
        always @(posedge clock) begin
            if (clear)
                _15 <= _17;
            else
                _15 <= _12;
        end
        always @(posedge clock) begin
            if (clear)
                _24 <= _17;
            else
                _24 <= _21;
        end
        always @(negedge clock) begin
            if (clear)
                _21 <= _17;
            else
                _21 <= _12;
        end
        assign vdd = 1'b1;
        always @(posedge clock) begin
            if (clear)
                _12 <= _17;
            else
                _12 <= d;
        end
        assign r0 = _12;
        assign qf = _21;
        assign qfr = _24;
        assign qr1 = _15;
        assign qr2 = _18;

    endmodule
    |}]
;;

let%expect_test "Cyclesim, outputs after each rising edge" =
  let sim = Cyclesim.create (circuit ()) in
  let i n = Cyclesim.in_port sim n in
  let o n = Cyclesim.out_port sim n in
  let clear, d = i "clear", i "d" in
  let r0, qf, qfr, qr1, qr2 = o "r0", o "qf", o "qfr", o "qr1", o "qr2" in
  clear := Bits.vdd;
  Cyclesim.cycle sim;
  clear := Bits.gnd;
  for k = 1 to 6 do
    d := Bits.of_int ~width:4 k;
    Cyclesim.cycle sim;
    let v x = Bits.to_int !x in
    printf "cycle %d: r0=%d qf=%d qfr=%d qr1=%d qr2=%d\n" k (v r0) (v qf) (v qfr) (v qr1) (v qr2)
  done;
  [%expect {|
    cycle 1: r0=1 qf=0 qfr=0 qr1=0 qr2=0
    cycle 2: r0=2 qf=1 qfr=0 qr1=1 qr2=0
    cycle 3: r0=3 qf=2 qfr=1 qr1=2 qr2=1
    cycle 4: r0=4 qf=3 qfr=2 qr1=3 qr2=2
    cycle 5: r0=5 qf=4 qfr=3 qr1=4 qr2=3
    cycle 6: r0=6 qf=5 qfr=4 qr1=5 qr2=4
    |}]
;;
