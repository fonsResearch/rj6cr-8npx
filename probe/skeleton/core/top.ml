(* The specification circuit: State.Chip registers around Step.step, with the two memories
   outside it behind synchronous single-port interfaces like the SRAM macros. *)
open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a (* synchronous, active high *)
    ; pad : 'a [@bits 24] (* uio_in in bits 7..0, ui_in in bits 23..16 *)
    ; prog_dout : 'a [@bits 32]
    ; data_dout : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uo_out : 'a [@bits 8]
    ; uio_out : 'a [@bits 8]
    ; uio_oe : 'a [@bits 8]
    ; prog_en : 'a
    ; prog_wen : 'a
    ; prog_addr : 'a [@bits 9]
    ; prog_din : 'a [@bits 32]
    ; data_en : 'a
    ; data_wen : 'a
    ; data_addr : 'a [@bits 10]
    ; data_din : 'a [@bits 16]
    ; prog_users : 'a [@bits 2]
    ; data_users : 'a [@bits 2]
    }
  [@@deriving hardcaml]
end

(* [debug]: also output every register, as the model has it after the previous cycle *)
let create ?(debug = false) (i : Signal.t I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let q = State.Chip.Of_signal.wires () in
  let next, t, _ = Step.step q ~pad:i.pad ~prog_dout:i.prog_dout ~data_dout:i.data_dout in
  let regs =
    State.Chip.map2 next State.reset ~f:(fun d rv ->
      add_attribute (reg (Reg_spec.override spec ~clear_to:(of_int ~width:(width d) rv)) d) (Rtl_attribute.Vivado.fsm_encoding `none))
  in
  State.Chip.Of_signal.assign q regs;
  let value = q.value in
  let o =
    { O.uo_out = select value 15 8
    ; uio_out = select value 7 0 &: ~:(q.od)
    ; uio_oe = q.dir &: ~:(q.od &: select value 7 0)
    ; prog_en = t.p_en
    ; prog_wen = t.p_wen
    ; prog_addr = t.p_addr
    ; prog_din = t.p_din
    ; data_en = t.d_en
    ; data_wen = t.d_wen
    ; data_addr = t.d_addr
    ; data_din = t.d_din
    ; prog_users = t.p_users
    ; data_users = t.d_users
    }
  in
  let dbg =
    if debug
    then (
      let eff = Step.effective q ~prog_dout:i.prog_dout ~data_dout:i.data_dout in
      State.Chip.to_list (State.Chip.map2 State.Chip.port_names_and_widths eff ~f:(fun (nm, _) s -> output ("dbg_" ^ nm) s)))
    else []
  in
  o, dbg
;;

let circuit ?debug () =
  let i = I.Of_signal.inputs () in
  let o, dbg = create ?debug i in
  let outs = O.to_list (O.map2 O.port_names_and_widths o ~f:(fun (nm, _) s -> output nm s)) in
  Circuit.create_exn ~name:"spec_chip" (outs @ dbg)
;;
