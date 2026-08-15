(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* An mgtt predicate, written as a writ guard — and the search for an
   assignment realising one.

   The translation is set-valued, which is the part worth stating. A predicate
   like `connection_count < 500` does not name a member; it names the SET of
   members satisfying it, and the writ guard is the disjunction over that set.
   That the set is usually a singleton is a happy consequence of [Mgtt_domains]
   merging regions nothing separates, not something this module may assume.

   An empty set is a predicate no assignment satisfies. There is no `false` in
   the twenty-six words to write it with, and inventing one — `(and (is x m)
   (not (is x m)))` — would put a guard in the model that reads like a mistake.
   So it is refused here and becomes a decline, which is also the more useful
   answer: a state nothing can satisfy is an unreachable state, the same
   finding mgtt's own validate pass reports for a `triggered_by` label with no
   producer. *)

type member_assignment = (string * Mgtt_domains.member) list

exception Refused of string

(* mgtt spells names with underscores; writ spells them with hyphens. Doing it
   in one place is what keeps a chain in a witness route readable back to the
   YAML the author wrote. *)
let writ_name (s : string) : string =
  String.map (fun c -> if c = '_' || c = '.' then '-' else c) s

(* The arrow a domain becomes. A pair domain is one cell read by two facts, so
   it takes a name naming both — and the order is the domain's own, which is
   alphabetical, so the same pair always spells the same way. *)
let arrow_of_domain (d : Mgtt_domains.domain) : string =
  match String.index_opt d.Mgtt_domains.dfact ':' with
  | None -> writ_name d.Mgtt_domains.dfact
  | Some i ->
      let a = String.sub d.Mgtt_domains.dfact 0 i in
      let b =
        String.sub d.Mgtt_domains.dfact (i + 1)
          (String.length d.Mgtt_domains.dfact - i - 1)
      in
      writ_name a ^ "-vs-" ^ writ_name b

(* The enumerated type a domain becomes. Qualified by the owning mgtt type,
   because two types may each have a fact called `available` whose predicates
   cut it differently, and one global name for both would silently merge them. *)
let domain_type_name (owner : string) (d : Mgtt_domains.domain) : string =
  writ_name owner ^ "-" ^ arrow_of_domain d

(* ---- predicate to guard --------------------------------------------------- *)

(* The pair domain a fact shares, if it shares one. A fact compared with a
   sibling has no cell of its own — the pair owns it — so a comparison against
   a CONSTANT has to be answered from the pair's cell too. *)
let pair_domain_of (doms : Mgtt_domains.domain list) (fact : string) :
    Mgtt_domains.domain option =
  List.find_opt
    (fun (d : Mgtt_domains.domain) ->
      match String.index_opt d.Mgtt_domains.dfact ':' with
      | None -> false
      | Some i ->
          let key = d.Mgtt_domains.dfact in
          let a = String.sub key 0 i in
          let b = String.sub key (i + 1) (String.length key - i - 1) in
          a = fact || b = fact)
    doms

let domain_for (doms : Mgtt_domains.domain list) (c : Mgtt_expr.comparison) :
    Mgtt_domains.domain option =
  match c.Mgtt_expr.rhs with
  | Mgtt_expr.Fact_ref other ->
      let a, b = (c.Mgtt_expr.fact, other) in
      let key = if a <= b then a ^ ":" ^ b else b ^ ":" ^ a in
      List.find_opt
        (fun (d : Mgtt_domains.domain) -> d.Mgtt_domains.dfact = key)
        doms
  | _ -> (
      match
        List.find_opt
          (fun (d : Mgtt_domains.domain) ->
            d.Mgtt_domains.dfact = c.Mgtt_expr.fact)
          doms
      with
      | Some d -> Some d
      | None -> pair_domain_of doms c.Mgtt_expr.fact)

(* Which of a domain's members satisfy this one comparison. Decided by asking
   [Mgtt_domains.satisfies] member by member, so there is exactly one place
   that knows what a member means. *)
let members_satisfying (doms : Mgtt_domains.domain list)
    (d : Mgtt_domains.domain) (c : Mgtt_expr.comparison) :
    Mgtt_domains.member list =
  List.filter
    (fun m ->
      Mgtt_domains.satisfies doms (Mgtt_expr.Cmp c)
        [ (d.Mgtt_domains.dfact, m) ])
    d.Mgtt_domains.members

let disjunction (parts : string list) : string =
  match parts with
  | [ one ] -> one
  | many -> "(or " ^ String.concat " " many ^ ")"

(* [subject] is what a chain is rooted at: an entity name in a transition, a
   TYPE name in an equation (kernel spec §8.6 — a law's chains are written from
   the type, so that it ranges over every entity of it). *)
let rec to_writ (doms : Mgtt_domains.domain list) ~(subject : string)
    (e : Mgtt_expr.t) : string =
  match e with
  | Mgtt_expr.And (a, b) ->
      "(and " ^ to_writ doms ~subject a ^ " " ^ to_writ doms ~subject b ^ ")"
  | Mgtt_expr.Or (a, b) ->
      "(or " ^ to_writ doms ~subject a ^ " " ^ to_writ doms ~subject b ^ ")"
  | Mgtt_expr.Cmp c -> (
      match domain_for doms c with
      | None ->
          raise
            (Refused
               ("fact `" ^ c.Mgtt_expr.fact ^ "` was not carried into the model"))
      | Some d -> (
          let arrow = arrow_of_domain d in
          match members_satisfying doms d c with
          | [] ->
              raise
                (Refused
                   ("no value of `" ^ c.Mgtt_expr.fact
                  ^ "` satisfies this comparison"))
          | ms ->
              disjunction
                (List.map
                   (fun m -> "(is " ^ subject ^ "." ^ arrow ^ " " ^ m ^ ")")
                   ms)))

let to_writ_opt doms ~subject e =
  try Ok (to_writ doms ~subject e) with Refused m -> Error m

(* A list of clauses is an implicit conjunction, which is how mgtt reads a
   `healthy:` block. An empty list is a predicate that says nothing; rather
   than emit a vacuous guard, callers are given [None] and decide. *)
let clauses_to_writ (doms : Mgtt_domains.domain list) ~(subject : string)
    (clauses : Mgtt_expr.t list) : (string option, string) result =
  match clauses with
  | [] -> Ok None
  | first :: rest -> (
      try
        let body =
          List.fold_left
            (fun acc e -> "(and " ^ acc ^ " " ^ to_writ doms ~subject e ^ ")")
            (to_writ doms ~subject first)
            rest
        in
        Ok (Some body)
      with Refused m -> Error m)

(* ---- witness search ------------------------------------------------------- *)

(* Assignments are enumerated rather than solved for. The product is small by
   construction — a type has a handful of facts and each domain a handful of
   members, because [Mgtt_domains] merged everything nothing separates — and an
   enumeration cannot be subtly wrong the way a solver can. The cap exists so
   that a pathological type fails loudly instead of hanging. *)
let cap = 100_000

let assignments (doms : Mgtt_domains.domain list) :
    member_assignment list option =
  let size =
    List.fold_left (fun n d -> n * List.length d.Mgtt_domains.members) 1 doms
  in
  if size > cap || size <= 0 then None
  else
    Some
      (List.fold_left
         (fun acc (d : Mgtt_domains.domain) ->
           List.concat_map
             (fun partial ->
               List.map
                 (fun m -> partial @ [ (d.Mgtt_domains.dfact, m) ])
                 d.Mgtt_domains.members)
             acc)
         [ [] ] doms)

(* The first assignment satisfying [e], in domain-declaration order.
   FIRST rather than any: the choice must be reproducible, or two runs of the
   emitter would write different moves from one model and `writ compare` would
   report a change nobody made. *)
let witness (doms : Mgtt_domains.domain list) (e : Mgtt_expr.t) :
    member_assignment option =
  match assignments doms with
  | None -> None
  | Some all -> List.find_opt (fun a -> Mgtt_domains.satisfies doms e a) all

(* The first assignment satisfying both, falling back to the first alone.
   Used for the initial situation: every component starts in its default active
   state, and healthy too where the two can agree. Where they cannot, the
   fallback is what makes the disagreement VISIBLE — the model starts in a
   state its own health law reports as violated, which is the finding. *)
let witness_preferring (doms : Mgtt_domains.domain list) (first : Mgtt_expr.t)
    (also : Mgtt_expr.t option) : member_assignment option =
  match also with
  | None -> witness doms first
  | Some extra -> (
      match witness doms (Mgtt_expr.And (first, extra)) with
      | Some a -> Some a
      | None -> witness doms first)

(* ---- move names ----------------------------------------------------------- *)

(* The names of the two kinds of move, in one place.

   They are here rather than inline in the emitter because a SECOND consumer
   now needs them: the diagnosability rules ([Emit_rules]) name moves in order
   to ask which of them could have caused a situation. If the two spellings
   ever drift, the rules match no edge, derive nothing, and report a clean
   answer — a false all-clear, which is the worst failure this tool has. One
   function each is what makes that drift impossible rather than unlikely. *)

(* A component failing on its own: the root cause of a chain. *)
let origination_move ~(component : string) ~(state : string) : string =
  writ_name component ^ "-fails-" ^ writ_name state

(* A failure crossing a dependency edge: [dep] in [dep_state] puts [component]
   into [state]. *)
let propagation_move ~(dep : string) ~(dep_state : string) ~(component : string)
    ~(state : string) : string =
  writ_name dep ^ "-" ^ writ_name dep_state ^ "-triggers-" ^ writ_name component
  ^ "-" ^ writ_name state
