(* Verilog of the specification circuit, for synthesis estimates (not for the chip). *)
open! Base
open Hardcaml

let () = Rtl.print Verilog (Spec_circuit.Top.circuit ())
