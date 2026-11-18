(* Instruction decode generated from spec/isa.ml: the same table drives the model's decoder. *)
open! Base
open Hardcaml
open Signal

type t =
  { w : Signal.t
  ; tm : Signal.t
  ; is : Spec.Isa.op -> Signal.t (* the word is a legal instruction of this op *)
  ; legal : Signal.t
  ; f : Spec.Isa.op -> string -> Signal.t (* operand field of the op, by name *)
  }

let def_of op = List.find_exn Spec.Isa.defs ~f:(fun (d : Spec.Isa.def) -> Poly.equal d.op op)

let decode w =
  let tm = select w 25 24 in
  let operand = select w 23 0 in
  let opcode = select w 31 26 in
  let legal_def (d : Spec.Isa.def) =
    let used = Spec.Isa.used_mask d in
    let unused_zero = operand &: of_int ~width:24 (lnot used land 0xFFFFFF) ==:. 0 in
    let tm_ok = if d.timed then vdd else tm ==:. 0 in
    let ranges =
      List.map d.fields ~f:(fun (f : Spec.Isa.field) ->
        let v = select w f.hi f.lo in
        if f.max >= (1 lsl (f.hi - f.lo + 1)) - 1 then vdd else v <=:. f.max)
    in
    opcode ==:. d.code &: unused_zero &: tm_ok &: U.all ranges
  in
  let table = List.map Spec.Isa.defs ~f:(fun d -> d.op, legal_def d) in
  let is op = List.Assoc.find_exn table ~equal:Poly.equal op in
  let legal = U.any (List.map table ~f:snd) in
  let f op name =
    let d = def_of op in
    let fd = List.find_exn d.fields ~f:(fun (x : Spec.Isa.field) -> String.equal x.name name) in
    select w fd.hi fd.lo
  in
  { w; tm; is; legal; f }
;;

(* the model's is_sync, for a legal word *)
let is_sync (dd : t) =
  let module I = Spec.Isa in
  let by_sync sy = List.filter I.defs ~f:(fun (x : I.def) -> Poly.equal x.sync sy) in
  let sync_always = U.any (List.map (by_sync I.Sync) ~f:(fun (x : I.def) -> dd.is x.op)) in
  let sync_cap = U.any (List.map (by_sync I.Sync_if_cap) ~f:(fun (x : I.def) -> dd.is x.op &: dd.f x.op "src")) in
  dd.tm <>:. 0 |: sync_always |: sync_cap
;;
