(* Physical skeleton, not part of the design: the specification circuit with one shared
   execute stage and one host register read multiplexer (README.md), the two SRAM macros
   behind its memory ports, and the pins of the chip. Its function is not the
   specification; it is a test load with the chip's state, logic and wiring. *)
open! Base
open Hardcaml
open Signal

let macro ~instance ~name ~clock ~en ~wen ~addr ~din =
  let abits = width addr and dbits = width din in
  let outputs =
    Instantiation.create ~instance () ~name
      ~inputs:
        [ "A_CLK", clock; "A_MEN", en; "A_WEN", wen; "A_REN", en &: ~:wen; "A_ADDR", addr; "A_DIN", din
        ; "A_DLY", vdd; "A_BM", ones dbits; "A_BIST_CLK", gnd; "A_BIST_EN", gnd; "A_BIST_MEN", gnd
        ; "A_BIST_WEN", gnd; "A_BIST_REN", gnd; "A_BIST_ADDR", zero abits; "A_BIST_DIN", zero dbits
        ; "A_BIST_BM", zero dbits ]
      ~outputs:[ "A_DOUT", dbits ]
  in
  Map.find_exn outputs "A_DOUT"
;;

let circuit () =
  let clock = input "clock" 1 in
  let rst_sync_n = input "rst_sync_n" 1 in
  let ui_in = input "ui_in" 8 in
  let uio_in = input "uio_in" 8 in
  let prog_dout = wire 32 and data_dout = wire 16 in
  let pad = concat_msb [ ui_in; zero 8; uio_in ] in
  let o, _ =
    Skel_core_lib.Top.create { Skel_core_lib.Top.I.clock; clear = ~:rst_sync_n; pad; prog_dout; data_dout }
  in
  prog_dout
  <== macro ~instance:"u_prog" ~name:"RM_IHPSG13_1P_512x32_c2_bm_bist" ~clock ~en:o.prog_en ~wen:o.prog_wen
        ~addr:o.prog_addr ~din:o.prog_din;
  data_dout
  <== macro ~instance:"u_data" ~name:"RM_IHPSG13_1P_1024x16_c2_bm_bist" ~clock ~en:o.data_en ~wen:o.data_wen
        ~addr:o.data_addr ~din:o.data_din;
  Circuit.create_exn ~name:"skel_core"
    [ output "uo_out" o.uo_out; output "uio_out" o.uio_out; output "uio_oe" o.uio_oe ]
;;
