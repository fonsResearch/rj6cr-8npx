(* Area proxy only: one execute stage for all threads (not functionally the specification). *)
open! Base
open Hardcaml
open Signal
open State
open W

let exec (ctx : ctx) (w : Signal.t W.t) ~slot =
  let sel i = slot ==:. ((i + 3) land 3) in
  let ths = w.c.th in
  let virt =
    List.foldi ths ~init:(List.hd_exn ths) ~f:(fun i acc t ->
      if i = 0 then acc else Thread.map2 acc t ~f:(fun a b -> mux2 (sel i) b a))
  in
  let ex = virt.fl_valid &: (sel 0 |: sel 1 |: sel 2) in
  let w0 = { w with c = { w.c with th = U.set ths 0 virt } } in
  let w1 = w_if ex w0 (fun w -> Exec.execute ctx w 0) in
  let virt' = List.hd_exn w1.c.th in
  let th =
    List.mapi ths ~f:(fun i t ->
      Thread.map2 t (Thread.map2 virt virt' ~f:(fun v n -> v, n)) ~f:(fun o (v, n) ->
        if phys_equal v n then o else mux2 (sel i) n o))
  in
  { w1 with c = { w1.c with th } }
;;
