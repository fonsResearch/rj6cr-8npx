(* Helpers for writing the model's sequential code as single-assignment logic. *)
open! Base
open Hardcaml
open Signal

(* [upd c old nw]: nw where c holds, old elsewhere; no logic where nothing changed. *)
let upd c old nw = if phys_equal old nw then old else mux2 c nw old
let k w v = of_int ~width:w v
let nth = List.nth_exn
let set l i v = List.mapi l ~f:(fun j x -> if j = i then v else x)

(* bit [idx] of [v], 0 where idx >= width v *)
let bit_at v idx =
  let n = 1 lsl width idx in
  mux idx (List.init n ~f:(fun i -> if i < width v then bit v i else gnd))
;;

(* element [idx] of a list, [default] where idx >= length *)
let get_at l idx ~default =
  let n = 1 lsl width idx in
  mux idx (List.init n ~f:(fun i -> if i < List.length l then nth l i else default))
;;

(* one-hot mask of width [w] with bit [idx] set (0 if idx >= w) *)
let onehot w idx = concat_lsb (List.init w ~f:(fun i -> idx ==:. i))

(* OR of the values whose condition holds; conditions are mutually exclusive *)
let oh_mux ~width:w cases =
  List.fold cases ~init:(zero w) ~f:(fun acc (c, v) -> acc |: (repeat c w &: uresize v w))
;;

let any l = List.fold l ~init:gnd ~f:( |: )
let all l = List.fold l ~init:vdd ~f:( &: )
let umin a b = mux2 (a <: b) a b
let umax a b = mux2 (a >: b) a b

(* the model's crc_bit: refl selects the right-shifting form; 16-bit register *)
let crc_bit ~refl crc poly d =
  let fb_l = lsb crc ^: d in
  let c_l = srl crc 1 in
  let r_l = mux2 fb_l (c_l ^: poly) c_l in
  let fb_m = msb crc ^: d in
  let c_m = sll crc 1 in
  let r_m = mux2 fb_m (c_m ^: poly) c_m in
  mux2 refl r_l r_m
;;

let crc_bit_msb crc poly d =
  let fb = msb crc ^: d in
  let c = sll crc 1 in
  mux2 fb (c ^: poly) c
;;
