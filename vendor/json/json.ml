(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The JSON value type and its serializer. No parser here (that is [Json_parse],
   split off up front because value + parser together broke the 300-line cap),
   and no I/O — this is pure values-to-strings so the library gate holds.

   Serialization follows RFC 8259: escape only the quote, the backslash, and the
   control codes below 0x20 (with the named short escapes where they exist, a
   \uXXXX escape otherwise). Non-ASCII bytes are emitted raw as UTF-8 — never as
   \uXXXX, never a slash escape. Integer-valued numbers round-trip through Int. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Assoc of (string * t) list

(* Lower-case hex, four digits, for a [\uXXXX] escape. Hand-rolled because the
   library may not touch [Printf]/[Format] (the no-I/O gate). *)
let hex4 code =
  let digit n = "0123456789abcdef".[n land 0xf] in
  let b = Bytes.create 4 in
  Bytes.set b 0 (digit (code lsr 12));
  Bytes.set b 1 (digit (code lsr 8));
  Bytes.set b 2 (digit (code lsr 4));
  Bytes.set b 3 (digit code);
  Bytes.unsafe_to_string b

let escape s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf ("\\u" ^ hex4 (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* [string_of_float] can yield a bare-trailing-dot form ("1.") that is not legal
   JSON, so pad it. Floats are peripheral (the RPC layer emits [Int]); this only
   has to be well-formed for the values the parser round-trips. *)
let float_to_string f =
  let s = string_of_float f in
  let n = String.length s in
  if n > 0 && s.[n - 1] = '.' then s ^ "0" else s

let rec to_string = function
  | Null -> "null"
  | Bool true -> "true"
  | Bool false -> "false"
  | Int i -> string_of_int i
  | Float f -> float_to_string f
  | String s -> escape s
  | List xs -> "[" ^ String.concat "," (List.map to_string xs) ^ "]"
  | Assoc kvs ->
      "{"
      ^ String.concat ","
          (List.map (fun (k, v) -> escape k ^ ":" ^ to_string v) kvs)
      ^ "}"

let member key = function Assoc kvs -> List.assoc_opt key kvs | _ -> None
let to_string_opt = function String s -> Some s | _ -> None
let to_int_opt = function Int i -> Some i | _ -> None
