(* Line unit registers as seen by threads and the host (model: line_status, line_peek,
   line_poke, line_io_index). *)
open! Base
open Hardcaml
open Signal
open State

let line_status (l : Signal.t Line.t) =
  let r0 = U.nth l.resp 0 and r1 = U.nth l.resp 1 in
  concat_lsb
    [ l.t_st <>:. 0; l.r_st ==:. 1 |: (l.r_st ==:. 2); l.r_st ==:. 3; l.t_done; l.r_done; l.r_crcok
    ; bit l.r_err 0; bit l.r_err 1; bit l.t_err 0; bit l.t_err 1; bit l.t_err 2; gnd; r0.fired; r1.fired; gnd; gnd ]
;;

(* [snap]: the start-of-cycle state, for the status word and the four read-only registers *)
let line_peek ~(snap : Signal.t Line.t) (l : Signal.t Line.t) j =
  let resp_word k o =
    let q = U.nth l.resp k in
    match o with
    | 0 -> uresize q.ctl 16 |: (uresize q.fired 16 |> fun x -> sll x 15)
    | 1 -> q.mtch
    | 2 -> uresize q.pos 16
    | 3 -> q.reply
    | _ -> uresize q.len 16
  in
  let table =
    List.init 64 ~f:(fun i ->
      if i = 0
      then line_status snap
      else if i >= 1 && i <= 17
      then U.nth l.lc (i - 1)
      else if i = 18
      then uresize snap.r_cnt 16
      else if i = 19
      then snap.r_hist
      else if i = 20
      then snap.r_crc
      else if i = 21
      then uresize snap.t_sent 16
      else if i = 22
      then uresize l.owner 16
      else if i >= 32 && i < 48 && i land 7 <= 4
      then resp_word ((i - 32) / 8) (i land 7)
      else zero 16)
  in
  mux j table
;;

let line_poke (l : Signal.t Line.t) ~en j v =
  let v = uresize v 16 in
  let at i = en &: (j ==:. i) in
  let l = { l with cmd = U.upd (at 0) l.cmd (l.cmd |: select v 4 0) } in
  let l = { l with lc = List.mapi l.lc ~f:(fun i x -> U.upd (at (i + 1)) x v) } in
  let l = { l with owner = U.upd (at 22) l.owner (select v 1 0) } in
  let resp =
    List.mapi l.resp ~f:(fun k (q : Signal.t Resp.t) ->
      let a o = at (32 + (8 * k) + o) in
      { Resp.ctl = U.upd (a 0) q.ctl (select v 13 0)
      ; fired = U.upd (a 0) q.fired gnd
      ; mtch = U.upd (a 1) q.mtch v
      ; pos = U.upd (a 2) q.pos (select v 13 0)
      ; reply = U.upd (a 3) q.reply v
      ; len = U.upd (a 4) q.len (select v 5 0)
      })
  in
  { l with resp }
;;

(* I/O address of a thread -> (valid, register index) *)
let line_io_index addr =
  let j = uresize (addr -:. 0x40) 8 in
  let valid =
    addr >=:. 0x40
    &: (j <=:. 21 |: (j >=:. 32 &: (j <:. 48) &: (select j 2 0 <=:. 4)))
  in
  valid, select j 5 0
;;
