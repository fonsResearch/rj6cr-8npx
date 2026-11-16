(* Working state of one cycle: the registers being updated plus the values the model keeps
   only for the duration of a cycle. *)
open! Base
open Hardcaml
open State

module Tmp = struct
  type 'a t =
    { value_n : 'a [@bits 16]
    ; dir_n : 'a [@bits 8]
    ; ev_rise : 'a [@bits 16]
    ; ev_fall : 'a [@bits 16]
    ; em_v : 'a (* an EMIT executed in this cycle (at most one thread executes per cycle) *)
    ; em_t : 'a [@bits 2]
    ; em_c : 'a [@bits 8]
    ; l_ev : 'a [@bits 11] (* line unit symbols of this cycle *)
    ; l_mask : 'a [@bits 16] (* pins the line unit drives in this cycle *)
    ; l_val : 'a [@bits 16]
    ; l_dir : 'a [@bits 8]
    ; l_slot : 'a (* the line unit uses the data memory's system slot *)
    ; p_en : 'a (* program memory port *)
    ; p_wen : 'a
    ; p_addr : 'a [@bits 9]
    ; p_din : 'a [@bits 32]
    ; d_en : 'a (* data memory port *)
    ; d_wen : 'a
    ; d_addr : 'a [@bits 10]
    ; d_din : 'a [@bits 16]
    ; p_users : 'a [@bits 2] (* number of requests on each port in this cycle, for checking *)
    ; d_users : 'a [@bits 2]
    }
  [@@deriving hardcaml]
end

module W = struct
  type 'a t =
    { c : 'a Chip.t [@rtlprefix "c_"]
    ; t : 'a Tmp.t [@rtlprefix "t_"]
    }
  [@@deriving hardcaml]
end

(* Values fixed for the whole cycle. *)
type ctx =
  { n : Signal.t (* now *)
  ; e : Signal.t (* now + 1, the effect cycle of an instruction executing now *)
  ; pv : Signal.t (* pins as read in this cycle *)
  ; pv_prev : Signal.t
  ; oe0 : Signal.t (* uio_oe during this cycle *)
  ; snap : Signal.t Line.t (* the line unit at the start of the cycle *)
  ; prog_dout : Signal.t
  ; data_dout : Signal.t
  }

let w_if c (w : Signal.t W.t) f = W.map2 w (f w) ~f:(U.upd c)
let w_ite c (w : Signal.t W.t) ~t ~e = W.map2 (e w) (t w) ~f:(U.upd c)
let th (w : Signal.t W.t) i = U.nth w.c.th i
let set_th (w : Signal.t W.t) i x = { w with c = { w.c with th = U.set w.c.th i x } }
let rule (w : Signal.t W.t) i = U.nth w.c.rules i
let set_rule (w : Signal.t W.t) i x = { w with c = { w.c with rules = U.set w.c.rules i x } }
let map_th w i f = set_th w i (f (th w i))
let tmp (w : Signal.t W.t) f = { w with t = f w.t }

(* a memory request; the port counters let the tests check that every port has one user *)
let prog_req (w : Signal.t W.t) ~en ~wen ~addr ~din =
  let open Signal in
  let t = w.t in
  { w with
    t =
      { t with
        p_en = U.upd en t.p_en vdd
      ; p_wen = U.upd en t.p_wen wen
      ; p_addr = U.upd en t.p_addr (uresize addr 9)
      ; p_din = U.upd en t.p_din (uresize din 32)
      ; p_users = U.upd en t.p_users (t.p_users +:. 1)
      }
  }
;;

let data_req (w : Signal.t W.t) ~en ~wen ~addr ~din =
  let open Signal in
  let t = w.t in
  { w with
    t =
      { t with
        d_en = U.upd en t.d_en vdd
      ; d_wen = U.upd en t.d_wen wen
      ; d_addr = U.upd en t.d_addr (uresize addr 10)
      ; d_din = U.upd en t.d_din (uresize din 16)
      ; d_users = U.upd en t.d_users (t.d_users +:. 1)
      }
  }
;;
