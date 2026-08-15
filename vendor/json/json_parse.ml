(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The JSON parser (split from [Json] up front — value plus parser overflowed
   the 300-line cap last time). Pure, no I/O.

   [\uXXXX] escapes decode to UTF-8, including surrogate pairs: a high surrogate
   (0xD800-0xDBFF) must be followed by a [\u] low surrogate (0xDC00-0xDFFF), and
   the pair becomes the 4-byte encoding of the astral code point (so a grinning
   face U+1F600 yields its four UTF-8 bytes). A lone or mismatched surrogate is an
   [Error], not a crash. Trailing garbage, unterminated strings, and bad escapes
   are rejected; nesting past a depth cap is an [Error] rather than a stack
   overflow. *)

exception Err of string

let depth_cap = 512

(* Append the UTF-8 encoding of a Unicode scalar to [buf]. *)
let add_utf8 buf cp =
  if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
  else if cp < 0x800 then (
    Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))
  else if cp < 0x10000 then (
    Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))
  else (
    Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F))))

let parse (s : string) : (Json.t, string) result =
  let n = String.length s in
  let pos = ref 0 in
  let peek () = if !pos < n then Some s.[!pos] else None in
  let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let skip_ws () =
    while !pos < n && is_ws s.[!pos] do
      incr pos
    done
  in
  let hex_val c =
    match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
    | _ -> raise (Err "bad hex digit in \\u escape")
  in
  (* Read exactly four hex digits after a [\u]; [!pos] sits just past the 'u'. *)
  let read_hex4 () =
    if !pos + 4 > n then raise (Err "truncated \\u escape");
    let v =
      (hex_val s.[!pos] lsl 12)
      lor (hex_val s.[!pos + 1] lsl 8)
      lor (hex_val s.[!pos + 2] lsl 4)
      lor hex_val s.[!pos + 3]
    in
    pos := !pos + 4;
    v
  in
  let read_unicode_escape buf =
    let u = read_hex4 () in
    if u >= 0xD800 && u <= 0xDBFF then
      if
        (* high surrogate: a [\u] low surrogate must follow *)
        !pos + 1 < n && s.[!pos] = '\\' && s.[!pos + 1] = 'u'
      then (
        pos := !pos + 2;
        let lo = read_hex4 () in
        if lo < 0xDC00 || lo > 0xDFFF then
          raise (Err "high surrogate not followed by low surrogate");
        let cp = 0x10000 + ((u - 0xD800) lsl 10) + (lo - 0xDC00) in
        add_utf8 buf cp)
      else raise (Err "lone high surrogate")
    else if u >= 0xDC00 && u <= 0xDFFF then raise (Err "lone low surrogate")
    else add_utf8 buf u
  in
  let parse_string () =
    (* [!pos] sits on the opening quote *)
    incr pos;
    let buf = Buffer.create 16 in
    let rec loop () =
      if !pos >= n then raise (Err "unterminated string");
      let c = s.[!pos] in
      if c = '"' then incr pos
      else if c = '\\' then (
        incr pos;
        if !pos >= n then raise (Err "unterminated escape");
        (match s.[!pos] with
        | '"' ->
            Buffer.add_char buf '"';
            incr pos
        | '\\' ->
            Buffer.add_char buf '\\';
            incr pos
        | '/' ->
            Buffer.add_char buf '/';
            incr pos
        | 'b' ->
            Buffer.add_char buf '\b';
            incr pos
        | 'f' ->
            Buffer.add_char buf '\012';
            incr pos
        | 'n' ->
            Buffer.add_char buf '\n';
            incr pos
        | 'r' ->
            Buffer.add_char buf '\r';
            incr pos
        | 't' ->
            Buffer.add_char buf '\t';
            incr pos
        | 'u' ->
            incr pos;
            read_unicode_escape buf
        | _ -> raise (Err "bad escape"));
        loop ())
      else if Char.code c < 0x20 then raise (Err "control code in string")
      else (
        Buffer.add_char buf c;
        incr pos;
        loop ())
    in
    loop ();
    Buffer.contents buf
  in
  let parse_number () =
    let start = !pos in
    if peek () = Some '-' then incr pos;
    let digits () =
      let d0 = !pos in
      while !pos < n && match s.[!pos] with '0' .. '9' -> true | _ -> false do
        incr pos
      done;
      !pos > d0
    in
    if not (digits ()) then raise (Err "number missing integer digits");
    let is_float = ref false in
    if peek () = Some '.' then (
      is_float := true;
      incr pos;
      if not (digits ()) then raise (Err "number missing fraction digits"));
    (match peek () with
    | Some ('e' | 'E') ->
        is_float := true;
        incr pos;
        (match peek () with Some ('+' | '-') -> incr pos | _ -> ());
        if not (digits ()) then raise (Err "number missing exponent digits")
    | _ -> ());
    let sub = String.sub s start (!pos - start) in
    if !is_float then Json.Float (float_of_string sub)
    else
      match int_of_string_opt sub with
      | Some i -> Json.Int i
      | None -> Json.Float (float_of_string sub)
  in
  let expect_lit word v =
    let len = String.length word in
    if !pos + len <= n && String.sub s !pos len = word then (
      pos := !pos + len;
      v)
    else raise (Err ("expected " ^ word))
  in
  let rec parse_value depth =
    if depth > depth_cap then raise (Err "nesting too deep");
    skip_ws ();
    match peek () with
    | None -> raise (Err "unexpected end of input")
    | Some '{' -> parse_object depth
    | Some '[' -> parse_array depth
    | Some '"' -> Json.String (parse_string ())
    | Some 't' -> expect_lit "true" (Json.Bool true)
    | Some 'f' -> expect_lit "false" (Json.Bool false)
    | Some 'n' -> expect_lit "null" Json.Null
    | Some ('-' | '0' .. '9') -> parse_number ()
    | Some c -> raise (Err ("unexpected char '" ^ String.make 1 c ^ "'"))
  and parse_array depth =
    incr pos;
    skip_ws ();
    if peek () = Some ']' then (
      incr pos;
      Json.List [])
    else
      let rec items acc =
        let v = parse_value (depth + 1) in
        skip_ws ();
        match peek () with
        | Some ',' ->
            incr pos;
            items (v :: acc)
        | Some ']' ->
            incr pos;
            Json.List (List.rev (v :: acc))
        | _ -> raise (Err "expected ',' or ']'")
      in
      items []
  and parse_object depth =
    incr pos;
    skip_ws ();
    if peek () = Some '}' then (
      incr pos;
      Json.Assoc [])
    else
      let rec members acc =
        skip_ws ();
        if peek () <> Some '"' then raise (Err "expected object key");
        let k = parse_string () in
        skip_ws ();
        if peek () <> Some ':' then raise (Err "expected ':'");
        incr pos;
        let v = parse_value (depth + 1) in
        skip_ws ();
        match peek () with
        | Some ',' ->
            incr pos;
            members ((k, v) :: acc)
        | Some '}' ->
            incr pos;
            Json.Assoc (List.rev ((k, v) :: acc))
        | _ -> raise (Err "expected ',' or '}'")
      in
      members []
  in
  try
    let v = parse_value 0 in
    skip_ws ();
    if !pos <> n then Error "trailing garbage after value" else Ok v
  with
  | Err m -> Error m
  | Invalid_argument _ | Failure _ -> Error "malformed JSON"
