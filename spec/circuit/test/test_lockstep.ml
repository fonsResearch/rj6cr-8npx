open Spec_xcheck
open Lockstep

let%expect_test "reset and idle pads" =
  Random.init 1;
  let t = create () in
  for _ = 1 to 300 do step t ~pad:(1 lsl 18) done;
  report t;
  [%expect {| 300 cycles: 0 mismatches, 0 port conflicts, 0 program and 0 data words differ |}]
;;

let%expect_test "threads and host" =
  Campaign.scenario ~name:"core" ~seed:1 ~runs:2 { rules = false; trace = false; line = false; fuzz = false; frames = false; directed = false; run = 30 };
  [%expect {|
    core: 2 runs, 133923 cycles, 0 mismatches, 0 port conflicts, 0 memory words differ
      coverage: fault DBOUND 7, fault IOPERM 11, fault PCBOUND 11, fault TRAP 168 6, fetch 465, pad change 53, wait cycle 19
      ops fetched: 23 of 48 kinds; not fetched: ALU SHI CRC STX JMP JAL JR BR BST HALT PDIR PINR PDRM PDRI OUTS OUTSC INS PINRD TADDR TGET TSET PULL PUSH IOR IOW
    |}]
;;

let%expect_test "rules and trace" =
  Campaign.scenario ~name:"rules" ~seed:2 ~runs:2 { rules = true; trace = true; line = false; fuzz = false; frames = false; directed = false; run = 30 };
  [%expect {|
    rules: 2 runs, 120679 cycles, 0 mismatches, 0 port conflicts, 0 memory words differ
      coverage: fault DBOUND 3, fault ILLEGAL 2, fault IOPERM 3, fault PINOWN 2, fault TRAP 57 1, fetch 4041, pad change 19, trace record 1882, wait cycle 6114
      ops fetched: 26 of 48 kinds; not fetched: NOP SHV ST JMP JAL BBIT HALT PDRM PDRI INS PINRD TNOW TADDI TADDR TPERI TPERR TGET TSET PUSH EMIT IOR IOW
    |}]
;;

let%expect_test "line unit" =
  Campaign.scenario ~name:"line" ~seed:3 ~runs:2 { rules = true; trace = true; line = false; fuzz = false; frames = true; directed = false; run = 40 };
  [%expect {|
    line: 2 runs, 173993 cycles, 0 mismatches, 0 port conflicts, 0 memory words differ
      coverage: blame verdict 1, fail verdict 1, fault IOPERM 13, fault PINOWN 9, fetch 15772, line drives 2750, line rx bit 156, line rx crc bad 11, line rx end 11, line rx start 11, line rx stuff error 477, line tx begin 6, line tx bit 409, line tx end 5, pad change 438, trace record 2004
      ops fetched: 15 of 48 kinds; not fetched: NOP ALU SHI SHV CRC ST STX JAL BR BRI DJNZ BBIT BPIN BST HALT TRAP PINV PDRI OUTSC INSC PINRD TNOW TADDI TADDR TPERI TPERR TGET TSET WAITP WAITS PULL EMIT IOW
    |}]
;;

let%expect_test "random register writes" =
  Campaign.scenario ~name:"fuzz" ~seed:4 ~runs:2 { rules = true; trace = true; line = true; fuzz = true; frames = false; directed = false; run = 40 };
  [%expect {|
    fuzz: 2 runs, 200991 cycles, 0 mismatches, 0 port conflicts, 0 memory words differ
      coverage: blame verdict 1, fault IOPERM 1, fault LATE 15, fault TRAP 52 10, fetch 7335, line drives 330, line rx stuff error 227, line tx begin 4, line tx bit 77, line tx end 3, pad change 85, trace record 4721, wait cycle 48603
      ops fetched: 20 of 48 kinds; not fetched: ALUI SHI SHV CRC LD LDX STX JMP JR BR BRI DJNZ BPIN BST HALT PDIR PINR PINM PINI PDRI INSC TNOW TADDR TPERI TPERR TGET IOR IOW
    |}]
;;

(* negative control: a register of the model changed behind the circuit's back is reported *)
let%expect_test "a planted difference is found" =
  Random.init 7;
  let t = create () in
  for _ = 1 to 50 do step t ~pad:(1 lsl 18) done;
  t.model.th.(1).r.(3) <- 5;
  t.model.tr_base <- 5;
  for _ = 1 to 3 do step t ~pad:(1 lsl 18) done;
  report t;
  [%expect {|
    53 cycles: 6 mismatches, 0 port conflicts, 0 program and 0 data words differ
      cycle 50 dbg_tr_base: model 5 (0x5), circuit 0 (0x0)
      cycle 50 dbg_th_r31: model 5 (0x5), circuit 0 (0x0)
      cycle 51 dbg_tr_base: model 5 (0x5), circuit 0 (0x0)
      cycle 51 dbg_th_r31: model 5 (0x5), circuit 0 (0x0)
      cycle 52 dbg_tr_base: model 5 (0x5), circuit 0 (0x0)
      cycle 52 dbg_th_r31: model 5 (0x5), circuit 0 (0x0)
    |}]
;;
