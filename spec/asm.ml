(* Assembler derived from Isa.defs.

   One statement per line:
     label:
     MNEM operand, operand, ...  [@now | @at | @adv]     ; comment
   Operands follow the field order of the instruction (doc/spec/isa.md). A register is
   written r0..r7; an enumerated field by name or number; a program address by label or
   number; anything else as a decimal or 0x number. *)
open Isa

exception Error of int * string

let fail line fmt = Printf.ksprintf (fun s -> raise (Error (line, s))) fmt
let strip_comment s = match String.index_opt s ';' with Some i -> String.sub s 0 i | None -> s

let parse_int line s =
  match int_of_string_opt s with
  | Some v -> v
  | None -> fail line "not a number: %s" s
;;

let operand line labels (f : field) s =
  let s = String.trim s in
  let v =
    match f.kind with
    | Reg ->
      if String.length s = 2 && (s.[0] = 'r' || s.[0] = 'R') && s.[1] >= '0' && s.[1] <= '7'
      then Char.code s.[1] - Char.code '0'
      else fail line "%s: expected a register, got %s" f.name s
    | Enum names ->
      let lower = String.lowercase_ascii s in
      let rec find k = if k >= Array.length names then parse_int line s else if names.(k) = lower then k else find (k + 1) in
      find 0
    | Target -> (match List.assoc_opt s labels with Some a -> a | None -> parse_int line s)
    | Uint | Bit | Pin _ -> parse_int line s
  in
  if v < 0 || v > f.max then fail line "%s = %d is outside 0..%d" f.name v f.max;
  v
;;

let statements text =
  String.split_on_char '\n' text
  |> List.mapi (fun k l -> k + 1, String.trim (strip_comment l))
  |> List.filter (fun (_, l) -> l <> "")
;;

let assemble (text : string) : int array =
  (* a label may stand alone or in front of an instruction: split it off as its own statement *)
  let stmts =
    List.concat_map
      (fun (line, l) ->
        match String.index_opt l ':' with
        | Some i when i < String.length l - 1 ->
          [ line, String.sub l 0 (i + 1); line, String.trim (String.sub l (i + 1) (String.length l - i - 1)) ]
        | _ -> [ line, l ])
      (statements text)
  in
  let is_label l = l.[String.length l - 1] = ':' in
  let labels, _ =
    List.fold_left
      (fun (labels, addr) (_, l) ->
        if is_label l then (String.trim (String.sub l 0 (String.length l - 1)), addr) :: labels, addr
        else labels, addr + 1)
      ([], 0) stmts
  in
  stmts
  |> List.filter (fun (_, l) -> not (is_label l))
  |> List.map (fun (line, l) ->
    let l, tm =
      match String.index_opt l '@' with
      | None -> l, 0
      | Some i ->
        let name = String.lowercase_ascii (String.trim (String.sub l (i + 1) (String.length l - i - 1))) in
        let tm = match name with "now" -> 1 | "at" -> 2 | "adv" -> 3 | _ -> fail line "unknown timing mode @%s" name in
        String.trim (String.sub l 0 i), tm
    in
    let mnem, rest =
      match String.index_opt l ' ' with
      | None -> l, ""
      | Some i -> String.sub l 0 i, String.sub l i (String.length l - i)
    in
    let def = match by_mnem (String.uppercase_ascii mnem) with Some d -> d | None -> fail line "unknown instruction %s" mnem in
    let ops = if String.trim rest = "" then [] else String.split_on_char ',' rest in
    if List.length ops <> List.length def.fields
    then fail line "%s takes %d operands, got %d" def.mnem (List.length def.fields) (List.length ops);
    let args = Array.of_list (List.map2 (operand line labels) def.fields ops) in
    try encode { def; args; tm } with Invalid_argument m -> fail line "%s" m)
  |> Array.of_list
;;

let disassemble (w : int) : string =
  match decode w with
  | None -> Printf.sprintf "ILLEGAL 0x%08X" (w land 0xFFFF_FFFF)
  | Some i ->
    let ops =
      List.mapi
        (fun k (f : field) ->
          let v = i.args.(k) in
          match f.kind with
          | Reg -> Printf.sprintf "r%d" v
          | Enum names -> names.(v)
          | _ -> string_of_int v)
        i.def.fields
    in
    let tm = if i.tm = 0 then "" else " @" ^ tm_names.(i.tm) in
    String.trim (i.def.mnem ^ " " ^ String.concat ", " ops) ^ tm
;;
