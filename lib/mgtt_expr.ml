(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* mgtt's expression language, re-read.

   The grammar is mgtt's own (`internal/expr/parser.go`) and this module tracks
   it deliberately rather than approximating it:

     or      = and ("|" and)*
     and     = primary ("&" primary)*
     primary = cmp | "(" or ")"
     cmp     = ref cmpop value

   Six comparison operators, two connectives, parentheses, and NO ARITHMETIC.
   That last absence is not a detail — it is what makes the reduction in
   [Mgtt_domains] lossless. Every predicate is a comparison against a constant,
   so the constants a model mentions cut each fact's value line into finitely
   many regions on which every predicate is constant. Add `+` to mgtt and that
   stops being true; this parser must then FAIL rather than guess, which is why
   an unrecognised token is an error and never a silently-skipped one.

   The value rule is the subtle part, and getting it wrong is silent. mgtt's
   [compareFactValue] re-interprets a non-numeric right-hand side as a
   reference to a sibling fact of the same component, so `ready_replicas ==
   desired_replicas` compares two cells. Reading the right side as a string
   literal would produce a comparison against the WORD "desired_replicas",
   which is false in every state — a model that checks clean because it asks
   nothing. Quoting is how an author says they meant the word itself. *)

type cmp = Eq | Neq | Lt | Gt | Lte | Gte

type rhs =
  | Lit_int of int
  | Lit_bool of bool
  | Lit_str of string
  | Fact_ref of string

(* A named record rather than an inline one, so that consumers outside this
   module can read a comparison's parts without pattern-matching it apart. *)
type comparison = { fact : string; op : cmp; rhs : rhs }
type t = And of t * t | Or of t * t | Cmp of comparison

exception Err of string

(* ---- tokens -------------------------------------------------------------- *)

let is_word_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_' || c = '.' || c = '-'

(* Two-character operators are scanned before their one-character prefixes, so
   `<=` never reads as `<` followed by a stray `=`. *)
let tokenize (s : string) : string list =
  let n = String.length s in
  let out = ref [] in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = ' ' || c = '\t' || c = '\n' || c = '\r' then incr i
    else if c = '"' then begin
      let j = ref (!i + 1) in
      while !j < n && s.[!j] <> '"' do
        incr j
      done;
      if !j >= n then raise (Err "unterminated string literal");
      out := String.sub s !i (!j - !i + 1) :: !out;
      i := !j + 1
    end
    else if
      !i + 1 < n
      && (c = '=' || c = '!' || c = '<' || c = '>')
      && s.[!i + 1] = '='
    then begin
      out := String.sub s !i 2 :: !out;
      i := !i + 2
    end
    else if c = '<' || c = '>' || c = '&' || c = '|' || c = '(' || c = ')' then begin
      out := String.make 1 c :: !out;
      incr i
    end
    else if is_word_char c then begin
      let j = ref !i in
      while !j < n && is_word_char s.[!j] do
        incr j
      done;
      out := String.sub s !i (!j - !i) :: !out;
      i := !j
    end
    else raise (Err ("unexpected character '" ^ String.make 1 c ^ "'"))
  done;
  List.rev !out

let op_of_token = function
  | "==" -> Some Eq
  | "!=" -> Some Neq
  | "<" -> Some Lt
  | ">" -> Some Gt
  | "<=" -> Some Lte
  | ">=" -> Some Gte
  | _ -> None

(* mgtt's InferValue, with one deliberate difference: a non-integer numeric
   constant is refused instead of becoming a float. Writ has no numbers, so a
   float has no member name to take and no ordering worth inventing. *)
let infer_rhs (tok : string) : rhs =
  let n = String.length tok in
  if n >= 2 && tok.[0] = '"' && tok.[n - 1] = '"' then
    Lit_str (String.sub tok 1 (n - 2))
  else if tok = "true" then Lit_bool true
  else if tok = "false" then Lit_bool false
  else
    match int_of_string_opt tok with
    | Some i -> Lit_int i
    | None -> (
        match float_of_string_opt tok with
        | Some _ -> raise (Err ("non-integer constant: " ^ tok))
        | None -> Fact_ref tok)

(* ---- the parser ---------------------------------------------------------- *)

let parse (src : string) : (t, string) result =
  try
    let toks = ref (tokenize src) in
    let peek () = match !toks with [] -> None | x :: _ -> Some x in
    let advance () =
      match !toks with
      | [] -> raise (Err "unexpected end of expression")
      | x :: rest ->
          toks := rest;
          x
    in
    let rec parse_or () =
      let left = parse_and () in
      match peek () with
      | Some "|" ->
          ignore (advance ());
          Or (left, parse_or ())
      | _ -> left
    and parse_and () =
      let left = parse_primary () in
      match peek () with
      | Some "&" ->
          ignore (advance ());
          And (left, parse_and ())
      | _ -> left
    and parse_primary () =
      match peek () with
      | Some "(" ->
          ignore (advance ());
          let inner = parse_or () in
          if advance () <> ")" then raise (Err "expected )");
          inner
      | _ -> parse_cmp ()
    and parse_cmp () =
      let fact = advance () in
      if op_of_token fact <> None || fact = "(" || fact = ")" then
        raise (Err ("expected a fact name, got " ^ fact));
      let op_tok = advance () in
      match op_of_token op_tok with
      | None -> raise (Err ("expected a comparison operator, got " ^ op_tok))
      | Some op -> Cmp { fact; op; rhs = infer_rhs (advance ()) }
    in
    if !toks = [] then Error "empty expression"
    else
      let e = parse_or () in
      if !toks <> [] then Error ("trailing input: " ^ String.concat " " !toks)
      else Ok e
  with Err m -> Error m

(* Every fact the expression reads, both sides of a reference included. Used to
   decide which facts a type's predicates actually mention — a fact nothing
   mentions has no regions to name and so cannot become an arrow. *)
let rec facts_of (e : t) : string list =
  match e with
  | And (a, b) | Or (a, b) -> facts_of a @ facts_of b
  | Cmp { fact; rhs = Fact_ref other; _ } -> [ fact; other ]
  | Cmp { fact; _ } -> [ fact ]

(* The pairs a type's predicates compare with each other, each ordered so that
   one pair has one name however it was written. *)
let rec pairs_of (e : t) : (string * string) list =
  match e with
  | And (a, b) | Or (a, b) -> pairs_of a @ pairs_of b
  | Cmp { fact; rhs = Fact_ref other; _ } ->
      [ (if fact <= other then (fact, other) else (other, fact)) ]
  | Cmp _ -> []
