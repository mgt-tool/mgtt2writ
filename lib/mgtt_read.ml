(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Json.t] -> [Mgtt_ast.doc].

   The version check comes first and it REFUSES rather than warns. A document
   from a newer mgtt may mean something different by the same key, and a bridge
   that guessed would emit a model whose findings nobody could trust — which is
   worse than no bridge, because the findings look the same either way.

   Everything else is tolerant on purpose: an absent list is an empty list, an
   absent object an empty ledger. The export is machine-written and its optional
   blocks are genuinely optional (most types declare no failure modes), so
   demanding them would reject valid documents to catch a corruption that the
   version field already guards. *)

open Mgtt_ast

let supported_version = 1
let as_string = function Json.String s -> Some s | _ -> None

let string_field key j =
  match Json.member key j with Some (Json.String s) -> s | _ -> ""

let list_field key j =
  match Json.member key j with Some (Json.List xs) -> xs | _ -> []

let string_list key j = List.filter_map as_string (list_field key j)

(* `failure_modes` is an object of state -> label list. *)
let modes_field key j =
  match Json.member key j with
  | Some (Json.Assoc kvs) ->
      List.map
        (fun (k, v) ->
          let labels =
            match v with
            | Json.List xs -> List.filter_map as_string xs
            | _ -> []
          in
          (k, labels))
        kvs
  | _ -> []

let read_state j =
  {
    sname = string_field "name" j;
    swhen = string_field "when" j;
    striggered = string_list "triggered_by" j;
  }

let read_fact j = (string_field "name" j, string_field "type" j)

let read_type j =
  {
    tname = string_field "name" j;
    facts = List.map read_fact (list_field "facts" j);
    thealthy = string_list "healthy" j;
    states = List.map read_state (list_field "states" j);
    default_state = string_field "default_active_state" j;
    tmodes = modes_field "failure_modes" j;
  }

let read_dep j = (string_field "on" j, string_field "while" j)

let read_comp j =
  {
    cname = string_field "name" j;
    ctype = string_field "type" j;
    depends = List.map read_dep (list_field "depends" j);
    chealthy = string_list "healthy" j;
    cmodes = modes_field "failure_modes" j;
  }

let read_decline j =
  { what = string_field "what" j; why = string_field "why" j }

let of_json (j : Json.t) : (doc, string) result =
  match Json.member "mgtt_export_version" j with
  | Some (Json.Int v) when v = supported_version ->
      let d =
        {
          name = string_field "name" j;
          components = List.map read_comp (list_field "components" j);
          types = List.map read_type (list_field "types" j);
          declines = List.map read_decline (list_field "declines" j);
        }
      in
      (* An export with no components is not a small model, it is a failed
         export — and saying so here costs one line, where saying it later
         costs a model file that reads like an answer. *)
      if d.components = [] then Error "no components in the export" else Ok d
  | Some (Json.Int v) ->
      Error
        ("mgtt_export_version " ^ string_of_int v
       ^ " is not supported (this writ reads version "
        ^ string_of_int supported_version
        ^ ")")
  | _ -> Error "not an mgtt export: no mgtt_export_version"
