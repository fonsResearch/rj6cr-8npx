(* Physical probe, not part of the design: the two SRAM macro types the architecture uses,
   each with every pin driven from a register and every output captured by a register, so
   that one hardening run shows whether the macros place, get power, pass the checks, and
   what the paths to and from them cost at the 20.83 ns clock.

   A 72-bit shift register is loaded through ui_in[0] (data) while ui_in[1] (shift) is
   high. A rising edge on ui_in[2] (go) performs one access on both macros with the fields
   below. ui_in[5:3] selects the byte of the captured read data shown on uo_out.

     [8:0]   program address     [40:9]  program data in   [41] write  [42] read
     [52:43] data address        [68:53] data data in      [69] write  [70] read *)
open Hardcaml
open Signal

let macro ~instance ~name ~clock ~men ~wen ~ren ~addr ~din =
  let abits = width addr and dbits = width din in
  let outputs =
    Instantiation.create ~instance () ~name
      ~inputs:
        [ "A_CLK", clock; "A_MEN", men; "A_WEN", wen; "A_REN", ren; "A_ADDR", addr; "A_DIN", din
        ; "A_DLY", vdd; "A_BM", ones dbits; "A_BIST_CLK", gnd; "A_BIST_EN", gnd; "A_BIST_MEN", gnd
        ; "A_BIST_WEN", gnd; "A_BIST_REN", gnd; "A_BIST_ADDR", zero abits; "A_BIST_DIN", zero dbits
        ; "A_BIST_BM", zero dbits ]
      ~outputs:[ "A_DOUT", dbits ]
  in
  Base.Map.find_exn outputs "A_DOUT"
;;

let circuit () =
  let clock = input "clock" 1 in
  let rst_sync_n = input "rst_sync_n" 1 in
  let ui_in = input "ui_in" 8 in
  let spec = Reg_spec.create ~clock ~clear:(~:rst_sync_n) () in
  let sync x = reg spec (reg spec x) in
  let sin = sync (bit ui_in 0) and shift = sync (bit ui_in 1) and go = sync (bit ui_in 2) in
  let sel = sync (select ui_in 5 3) in
  let sr = reg_fb spec ~enable:shift ~width:72 ~f:(fun q -> select q 70 0 @: sin) in
  let go_pulse = go &: ~:(reg spec go) in
  let field hi lo = select sr hi lo in
  let p_wen = bit sr 41 &: go_pulse and p_ren = bit sr 42 &: go_pulse in
  let d_wen = bit sr 69 &: go_pulse and d_ren = bit sr 70 &: go_pulse in
  let p_dout =
    macro ~instance:"u_prog" ~name:"RM_IHPSG13_1P_512x32_c2_bm_bist" ~clock ~men:(p_wen |: p_ren) ~wen:p_wen ~ren:p_ren
      ~addr:(field 8 0) ~din:(field 40 9)
  in
  let d_dout =
    macro ~instance:"u_data" ~name:"RM_IHPSG13_1P_1024x16_c2_bm_bist" ~clock ~men:(d_wen |: d_ren) ~wen:d_wen ~ren:d_ren
      ~addr:(field 52 43) ~din:(field 68 53)
  in
  let p_q = reg spec p_dout and d_q = reg spec d_dout in
  let bytes =
    [ select p_q 7 0; select p_q 15 8; select p_q 23 16; select p_q 31 24; select d_q 7 0; select d_q 15 8; zero 8; zero 8 ]
  in
  Circuit.create_exn ~name:"probe_macros"
    [ output "uo_out" (reg spec (mux sel bytes)); output "uio_out" (zero 8); output "uio_oe" (zero 8) ]
;;
