(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The shape of `mgtt model export --json`, as records.

   A separate module from the reader for the reason [Json] is separate from
   [Json_parse]: these types are what every other module here talks about, and
   the reader is one function that stops mattering the moment it has run.

   What arrives is the RESOLVED model — mgtt has already merged each provider
   type into the components using it and applied every component-level
   override. So there is no precedence to work out here, and deliberately: a
   second implementation of mgtt's override rules would be one free to drift
   from the first.

   Expressions arrive as SOURCE TEXT (`connection_count < 500`) and are parsed
   by [Mgtt_expr], not here. Keeping the document layer free of interpretation
   means a malformed expression is reported against the text the author wrote
   rather than against some half-built value. *)

(* Something the export could not carry faithfully. mgtt fills these in (the
   generic-type fallback is the one it knows about); the reduction and the
   emitter add their own, and [Cmd_mgtt] prints the union. Never a hard error:
   a decline is a fact about the crossing, and the run continues so that the
   rest of the model still gets checked. *)
type decline = { what : string; why : string }

type state = {
  sname : string;
  swhen : string;  (** the raw `when:` expression, unparsed *)
  striggered : string list;  (** `triggered_by` labels *)
  sverdict : string;
      (** "" when the healthy rules decide; "healthy" for a state that is no
          failure, "broken" for a component's own state *)
}

type ty = {
  tname : string;
  facts : (string * string) list;  (** fact name, mgtt data type *)
  thealthy : string list;
  states : state list;
      (** DECLARED ORDER, which is load-bearing: the emitter walks it to pick a
          representative assignment per state, so sorting would silently change
          which assignment a propagation move writes. *)
  default_state : string;
  tmodes : (string * string list) list;  (** state -> can_cause labels *)
}

type comp = {
  cname : string;
  ctype : string;
  depends : (string * string) list;
      (** target, and the while-guard ("" when the edge is always active) *)
  cgroups : (string * (string list * int)) list;
      (** target -> the redundancy group it belongs to: its members, and how
          many must stay healthy for the group to hold. A target absent here is
          a plain, hard dependency. *)
  chealthy : string list;  (** already effective: mgtt applied the override *)
  cmodes : (string * string list) list;
  cstates : state list;
      (** the component's own states, checked before its type's, each broken *)
  chealthy_in : string list;
      (** type states in which this component is healthy whatever the rules *)
}

type doc = {
  name : string;
  components : comp list;
  types : ty list;
  declines : decline list;
}

let type_of (d : doc) (name : string) : ty option =
  List.find_opt (fun (t : ty) -> t.tname = name) d.types

let component_of (d : doc) (name : string) : comp option =
  List.find_opt (fun (c : comp) -> c.cname = name) d.components

(* Every component sharing one type. The reduction needs this: a fact's domain
   is cut by the constants the TYPE mentions and by those every component of
   that type mentions in its own healthy override, so the domain is a property
   of the type and its whole roster rather than of either alone. *)
let components_of_type (d : doc) (tyname : string) : comp list =
  List.filter (fun (c : comp) -> c.ctype = tyname) d.components

(* The labels a state emits when it is the failing one, from this component's
   effective ledger. *)
let can_cause (c : comp) (state : string) : string list =
  match List.assoc_opt state c.cmodes with Some ls -> ls | None -> []

(* A component's effective type: its own states first, its healthy_in states
   marked healthy -- the model's word on that node over its provider's, as mgtt
   reads it. *)
let effective_type (d : doc) (c : comp) : ty option =
  match type_of d c.ctype with
  | None -> None
  | Some ty when c.cstates = [] && c.chealthy_in = [] -> Some ty
  | Some ty ->
      let mark (st : state) =
        if List.mem st.sname c.chealthy_in && st.sverdict <> "broken" then
          { st with sverdict = "healthy" }
        else st
      in
      Some { ty with states = List.map mark (c.cstates @ ty.states) }

(* A healthy state is no failure: it starts and carries no chain. *)
let is_failure (ty : ty) (st : state) : bool =
  st.sname <> ty.default_state && st.sverdict <> "healthy"

(* Whether [dep], failing into [failing], can put a component of type [ty] into
   [target]: mgtt's own rule, the one its scenarios enumerate by. Only failure
   states take part on either side: [failing] is not [dep_ty]'s default and
   emits at least one `can_cause` label, and [target] is not [ty]'s default. A
   target whose `triggered_by` names labels answers to those; one naming none
   answers to any. That permissive default is what a provider omitting
   `triggered_by` gets from mgtt, and most of them omit it. *)
let triggers (dep : comp) (dep_ty : ty) (failing : state) (ty : ty)
    (target : state) : bool =
  let labels =
    if failing.sname = dep_ty.default_state then []
    else can_cause dep failing.sname
  in
  labels <> []
  && failing.sverdict <> "healthy"
  && target.sname <> ty.default_state
  && target.sverdict <> "healthy"
  && (target.striggered = []
     || List.exists (fun l -> List.mem l target.striggered) labels)
