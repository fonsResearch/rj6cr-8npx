(* Every register of the chip, as nested Hardcaml interfaces. Field widths and reset values
   follow spec/model.ml (create, new_thread, new_rule, new_line); where the model holds an
   unbounded integer the register saturates at a value the model's comparisons cannot tell
   apart (noted at the field). *)
open! Base

module Thread = struct
  type 'a t =
    { st : 'a [@bits 3] (* 0 idle, 1 run, 2 wait, 3 halted, 4 faulted *)
    ; fcode : 'a [@bits 4] (* fault code as in host register 1: 1 ILLEGAL .. 8 RULE *)
    ; farg : 'a [@bits 8]
    ; r : 'a list [@length 8] [@bits 16]
    ; pc : 'a [@bits 10]
    ; t_int : 'a [@bits 32]
    ; t_frac : 'a [@bits 8]
    ; p : 'a [@bits 32]
    ; armed : 'a
    ; due : 'a
    ; adv : 'a
    ; deadline : 'a
    ; sv : 'a [@bits 16]
    ; sm : 'a [@bits 16]
    ; ev : 'a [@bits 8]
    ; em : 'a [@bits 8]
    ; cap : 'a [@bits 24]
    ; evf : 'a
    ; late : 'a
    ; slack_min : 'a [@bits 16] (* signed *)
    ; w_pin : 'a (* wait fields are meaningful while st = 2 *)
    ; w_idx : 'a [@bits 5]
    ; w_cond : 'a [@bits 2]
    ; w_to : 'a
    ; w_cm : 'a
    ; w_re : 'a
    ; w_adv : 'a
    ; w_due : 'a [@bits 2]
    ; pbase : 'a [@bits 9]
    ; psize : 'a [@bits 10]
    ; dbase : 'a [@bits 10]
    ; dsize : 'a [@bits 11]
    ; strict : 'a
    ; loaded : 'a
    ; loading : 'a
    ; load_count : 'a [@bits 10]
    ; crc : 'a [@bits 16]
    ; digest : 'a [@bits 16]
    ; entry : 'a [@bits 10]
    ; fl_valid : 'a (* an instruction in flight, fetched in the thread's slot *)
    ; fl_pcb : 'a (* it was fetched with pc >= psize *)
    ; fl_word : 'a [@bits 32] (* captured from the program memory one cycle after the fetch *)
    ; in_v : 'a
    ; in_d : 'a [@bits 16]
    ; out_v : 'a
    ; out_d : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module Rule = struct
  type 'a t =
    { en : 'a
    ; guarantee : 'a
    ; policy : 'a [@bits 2]
    ; owner : 'a [@bits 2]
    ; ps : 'a [@bits 2]
    ; sel_start : 'a [@bits 16]
    ; sel_stop : 'a [@bits 16]
    ; sel_abort : 'a [@bits 16]
    ; rmin : 'a [@bits 16]
    ; rmax : 'a [@bits 16]
    ; active : 'a
    ; cnt : 'a [@bits 16]
    ; v_min : 'a
    ; v_max : 'a
    ; repaired : 'a
    ; obs_min : 'a [@bits 16]
    ; obs_max : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module Verdict = struct
  type 'a t =
    { valid : 'a
    ; rule : 'a [@bits 2]
    ; max_kind : 'a
    ; cycle : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module Host = struct
  type 'a t =
    { count : 'a [@bits 6] (* bits of this transaction, saturating at 63 *)
    ; cmod : 'a [@bits 5] (* bits of this transaction modulo 32 *)
    ; sh : 'a [@bits 32]
    ; cmd : 'a [@bits 8]
    ; haddr : 'a [@bits 16]
    ; osh : 'a [@bits 32]
    ; miso : 'a
    ; rbuf : 'a [@bits 32] (* the model's rbuf one cycle late; see rd_p, rd_d *)
    ; rd_p : 'a (* the program memory was read for the host in the previous cycle *)
    ; rd_d : 'a (* the data memory was read for the host in the previous cycle *)
    ; rq_v : 'a
    ; rq_prog : 'a
    ; rq_write : 'a
    ; rq_addr : 'a [@bits 16]
    ; rq_data : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module Trace = struct
  type 'a t =
    { en : 'a
    ; freeze : 'a
    ; base : 'a [@bits 10]
    ; size : 'a [@bits 9]
    ; mask : 'a [@bits 24]
    ; post : 'a [@bits 8]
    ; ptr : 'a [@bits 8]
    ; wrapped : 'a
    ; frozen : 'a
    ; trig : 'a
    ; left : 'a [@bits 8]
    ; rec_ : 'a list [@length 4] [@bits 16]
    ; widx : 'a [@bits 3]
    ; lost : 'a
    }
  [@@deriving hardcaml]
end

module Resp = struct
  type 'a t =
    { ctl : 'a [@bits 14]
    ; mtch : 'a [@bits 16]
    ; pos : 'a [@bits 14]
    ; reply : 'a [@bits 16]
    ; len : 'a [@bits 6]
    ; fired : 'a
    }
  [@@deriving hardcaml]
end

module Line = struct
  type 'a t =
    { owner : 'a [@bits 2]
    ; lc : 'a list [@length 17] [@bits 16] (* registers 1..17 *)
    ; resp : 'a Resp.t list [@length 2] [@rtlmangle true]
    ; cmd : 'a [@bits 5]
    ; q_pv : 'a
    ; q_pk : 'a
    ; t_st : 'a [@bits 3]
    ; t_acc : 'a [@bits 16]
    ; t_bnd : 'a
    ; t_sent : 'a [@bits 14]
    ; t_word : 'a [@bits 16]
    ; t_next : 'a [@bits 16] (* the model's t_next one cycle late; see t_rd *)
    ; t_rd : 'a (* the data memory was read for the transmitter in the previous cycle *)
    ; t_nvalid : 'a
    ; t_req_v : 'a
    ; t_req : 'a [@bits 11]
    ; t_crc : 'a [@bits 16]
    ; t_crcleft : 'a [@bits 5]
    ; t_run : 'a [@bits 4] (* saturating at 15 *)
    ; t_last : 'a
    ; t_line : 'a
    ; t_bit : 'a
    ; t_half : 'a
    ; t_tail : 'a [@bits 3]
    ; t_out : 'a [@bits 2]
    ; t_rel : 'a
    ; t_rwait : 'a [@bits 4]
    ; t_rleft : 'a [@bits 5]
    ; t_rsh : 'a [@bits 16]
    ; t_rtail : 'a
    ; t_done : 'a
    ; t_err : 'a [@bits 3]
    ; r_st : 'a [@bits 2]
    ; r_idle_seen : 'a
    ; r_ph : 'a [@bits 16]
    ; r_lv : 'a
    ; r_prev : 'a
    ; r_hcnt : 'a [@bits 4]
    ; r_cnt : 'a [@bits 14]
    ; r_sh : 'a [@bits 16]
    ; r_hist : 'a [@bits 16]
    ; r_crc : 'a [@bits 16]
    ; r_run : 'a [@bits 4] (* saturating at 15 *)
    ; r_last : 'a
    ; r_quiet : 'a [@bits 9] (* saturating at 511 *)
    ; r_wv : 'a
    ; r_widx : 'a [@bits 10]
    ; r_wd : 'a [@bits 16]
    ; r_done : 'a
    ; r_crcok : 'a
    ; r_err : 'a [@bits 2]
    }
  [@@deriving hardcaml]
end

module Chip = struct
  type 'a t =
    { now : 'a [@bits 32]
    ; value : 'a [@bits 16]
    ; dir : 'a [@bits 8]
    ; owner : 'a list [@length 16] [@bits 3]
    ; od : 'a [@bits 8]
    ; safe_val : 'a [@bits 16]
    ; safe_dir : 'a [@bits 8]
    ; filt : 'a list [@length 24] [@bits 2]
    ; x : 'a [@bits 24]
    ; s : 'a [@bits 24]
    ; fcnt : 'a list [@length 24] [@bits 2]
    ; pv_prev : 'a [@bits 24]
    ; oe_hist : 'a list [@length 7] [@bits 8] (* element k: uio_oe during cycle now - 1 - k *)
    ; fail : 'a Verdict.t [@rtlprefix "fail_"]
    ; blame : 'a Verdict.t [@rtlprefix "blame_"]
    ; blame_before_fail : 'a
    ; hstat : 'a [@bits 5]
    ; now_latch : 'a [@bits 16]
    ; host : 'a Host.t [@rtlprefix "host_"]
    ; trace : 'a Trace.t [@rtlprefix "tr_"]
    ; line : 'a Line.t [@rtlprefix "line_"]
    ; th : 'a Thread.t list [@length 3] [@rtlmangle true]
    ; rules : 'a Rule.t list [@length 4] [@rtlmangle true]
    }
  [@@deriving hardcaml]
end

(* Reset values: as the model's constructors; every field not listed is 0. *)
let reset : int Chip.t =
  let th = { (Thread.map Thread.port_names_and_widths ~f:(fun _ -> 0)) with slack_min = 0x7FFF; strict = 1 } in
  let rule =
    { (Rule.map Rule.port_names_and_widths ~f:(fun _ -> 0)) with
      owner = 3; sel_start = 0x380; sel_stop = 0x380; sel_abort = 0x380; rmax = 0xFFFF; obs_min = 0xFFFF }
  in
  let c = Chip.map Chip.port_names_and_widths ~f:(fun _ -> 0) in
  { c with
    owner = List.init 16 ~f:(fun _ -> 7)
  ; trace = { c.trace with post = 4; widx = 4 }
  ; line = { c.line with owner = 3 }
  ; th = List.init 3 ~f:(fun _ -> th)
  ; rules = List.init 4 ~f:(fun _ -> rule)
  }
;;
