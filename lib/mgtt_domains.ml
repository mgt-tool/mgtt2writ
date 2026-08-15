(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Facts to finite domains — the reduction the whole bridge rests on.

   Writ has no numbers, deliberately: it is what buys the negative answer, a
   `never` that is a census rather than a search that found nothing. mgtt's
   facts are ints, floats, durations and bytes. So this module is where the
   crossing is either honest or it is nothing.

   It is honest because of a property of mgtt rather than a cleverness here:
   its expression language compares a fact against a CONSTANT and has no
   arithmetic at all. So the constants a model mentions cut each fact's value
   line into finitely many regions, and every predicate in the model is
   constant on each region. A region becomes a member; two concrete values in
   one region were already indistinguishable to mgtt's own engine. Nothing is
   approximated and nothing is lost — this is the kernel spec's "counting
   becomes naming, calculating becomes writing down", applied to a fact.

   Merging matters as much as cutting. `connection_count < 500` does not
   separate 500 from 501, so a domain of three members would carry a
   distinction no rule can make and double the state space to do it. The
   regions are cut by every constant, then collapsed wherever no gathered
   predicate tells two neighbours apart.

   A fact NO predicate mentions has no regions at all. It cannot become an
   arrow — there is nothing to name — and it is declined rather than dropped,
   because a fact silently absent from the model is a probe whose result the
   check would ignore. *)

type member = string

(* What a member MEANS, kept beside the names rather than encoded in them.

   An earlier version read the meaning back out of the name — `below-500` gave
   499 — which worked while every domain was one fact deep and stopped working
   the moment a member had to say two things at once (this fact's region, the
   sibling's region, and how the two compare). Names are for the emitted model
   to read; this table is for the reduction to read. *)
type value =
  | Vbool of bool
  | Vstr of string
  | Vint of int  (** a representative of the region *)
  | Vpair of { left : int; right : int }
      (** representatives of BOTH facts of a pair, in the domain's own
          (alphabetical) order — so the ordering between them is a comparison
          rather than a third field that could disagree with the first two *)

type domain = {
  dfact : string;
  dtype : string;
  members : member list;
  interp : (member * value) list;
}

(* ---- gathering ----------------------------------------------------------- *)

(* Every predicate that bears on a type: its own healthy list, each state's
   guard, and the healthy override of every component using it. The last is why
   this takes a roster — a domain is a property of the type AND its components,
   since an override may compare against a constant the type never mentions. *)
let predicates_of (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) : string list
    =
  ty.Mgtt_ast.thealthy
  @ List.map (fun (s : Mgtt_ast.state) -> s.Mgtt_ast.swhen) ty.Mgtt_ast.states
  @ List.concat_map (fun (c : Mgtt_ast.comp) -> c.Mgtt_ast.chealthy) comps

(* Parse what parses; hand back what does not, as a decline naming the text.
   A predicate that will not parse is not fatal: the rest of the type still
   yields a model worth checking, and the decline says exactly what was lost. *)
let parsed_predicates (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) :
    Mgtt_expr.t list * Mgtt_ast.decline list =
  List.fold_left
    (fun (es, ds) src ->
      match Mgtt_expr.parse src with
      | Ok e -> (e :: es, ds)
      | Error m ->
          ( es,
            {
              Mgtt_ast.what = ty.Mgtt_ast.tname ^ ": " ^ src;
              why = "expression not readable: " ^ m;
            }
            :: ds ))
    ([], []) (predicates_of ty comps)

(* Every (op, constant) a predicate applies to one fact. *)
let rec constraints_on (fact : string) (e : Mgtt_expr.t) :
    (Mgtt_expr.cmp * Mgtt_expr.rhs) list =
  match e with
  | Mgtt_expr.And (a, b) | Mgtt_expr.Or (a, b) ->
      constraints_on fact a @ constraints_on fact b
  | Mgtt_expr.Cmp c when c.Mgtt_expr.fact = fact ->
      [ (c.Mgtt_expr.op, c.Mgtt_expr.rhs) ]
  | Mgtt_expr.Cmp _ -> []

(* ---- naming -------------------------------------------------------------- *)

let sanitize (s : string) : string =
  String.map
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' then c
      else if c >= 'A' && c <= 'Z' then Char.lowercase_ascii c
      else '-')
    s

(* ---- numeric domains ----------------------------------------------------- *)

(* A region of the value line, as a representative and a name. [rep] is what
   [satisfies] evaluates predicates at: any value in the region answers every
   predicate the same way, so one representative decides them all. *)
(* A region carries its BOUNDS, not just a representative.

   One representative is enough to answer "does this region satisfy `< 500`",
   which is all a single-fact domain ever asks. It is not enough for a pair:
   saying "both facts lie in this region, and the left one is the larger" needs
   two DISTINCT values that are both still inside it, and a lone representative
   cannot produce a second without escaping the region it names. [lo]/[hi] are
   inclusive; [None] is unbounded on that side. *)
type region = { rname : string; rep : int; lo : int option; hi : int option }

(* Two distinct values inside the region, or [None] where it holds only one. *)
let two_inside (r : region) : (int * int) option =
  match (r.lo, r.hi) with
  | Some l, Some h -> if h - l >= 1 then Some (l, l + 1) else None
  | Some l, None -> Some (l, l + 1)
  | None, Some h -> Some (h - 1, h)
  | None, None -> Some (r.rep, r.rep + 1)

let int_constants (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) : int list =
  List.sort_uniq compare
    (List.filter_map
       (function _, Mgtt_expr.Lit_int i -> Some i | _ -> None)
       cs)

let eval_int (op : Mgtt_expr.cmp) (v : int) (k : int) : bool =
  match op with
  | Mgtt_expr.Eq -> v = k
  | Mgtt_expr.Neq -> v <> k
  | Mgtt_expr.Lt -> v < k
  | Mgtt_expr.Gt -> v > k
  | Mgtt_expr.Lte -> v <= k
  | Mgtt_expr.Gte -> v >= k

(* Cut at every constant, finest-first: below k1, exactly k1, the open interval
   up to k2, exactly k2, … and everything above the last. [merge_regions] then
   collapses whatever no predicate separates, so cutting too finely here costs
   nothing and cutting too coarsely would lose a distinction for good. *)
let cut_regions (ks : int list) : region list =
  match ks with
  | [] -> []
  | first :: _ ->
      let last = List.nth ks (List.length ks - 1) in
      let rec weave = function
        | [] -> []
        | k :: rest ->
            let here =
              {
                rname = "exactly-" ^ string_of_int k;
                rep = k;
                lo = Some k;
                hi = Some k;
              }
            in
            let gap =
              match rest with
              | next :: _ ->
                  [
                    {
                      rname = "under-" ^ string_of_int next;
                      rep = next - 1;
                      lo = Some (k + 1);
                      hi = Some (next - 1);
                    };
                  ]
              | [] -> []
            in
            (here :: gap) @ weave rest
      in
      {
        rname = "below-" ^ string_of_int first;
        rep = first - 1;
        lo = None;
        hi = Some (first - 1);
      }
      :: weave ks
      @ [
          {
            rname = "above-" ^ string_of_int last;
            rep = last + 1;
            lo = Some (last + 1);
            hi = None;
          };
        ]

(* Two neighbouring regions merge when no gathered predicate tells them apart.
   The merged name is read off the pair: a region that runs from below a
   constant up to but not including it stays `below-k`; one that starts at a
   constant and runs on becomes `at-or-above-k`. *)
let merge_regions (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) (rs : region list)
    : region list =
  let same a b =
    List.for_all
      (function
        | op, Mgtt_expr.Lit_int k -> eval_int op a.rep k = eval_int op b.rep k
        | _ -> true)
      cs
  in
  let rename first last =
    if first.rname = last.rname then first.rname
    else
      match (first.rname, last.rname) with
      | f, _ when String.length f > 6 && String.sub f 0 6 = "below-" -> f
      | f, l when String.length f > 8 && String.sub f 0 8 = "exactly-" ->
          let k = String.sub f 8 (String.length f - 8) in
          if String.length l > 6 && String.sub l 0 6 = "above-" then
            "at-or-above-" ^ k
          else "from-" ^ k
      | f, _ -> f
  in
  let rec go acc = function
    | [] -> List.rev acc
    | r :: rest ->
        let rec take_while_same last kept = function
          | x :: xs when same last x -> take_while_same x (x :: kept) xs
          | remaining -> (List.rev kept, remaining)
        in
        let group, remaining = take_while_same r [ r ] rest in
        let last = List.nth group (List.length group - 1) in
        go
          ({ rname = rename r last; rep = r.rep; lo = r.lo; hi = last.hi }
          :: acc)
          remaining
  in
  go [] rs

(* ---- building the domains ------------------------------------------------ *)

let bool_members = [ "yes"; "no" ]

let string_members (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) : string list =
  let lits =
    List.sort_uniq compare
      (List.filter_map
         (function _, Mgtt_expr.Lit_str s -> Some (sanitize s) | _ -> None)
         cs)
  in
  lits @ [ "other" ]

let is_bool cs =
  List.exists (function _, Mgtt_expr.Lit_bool _ -> true | _ -> false) cs

let is_string cs =
  List.exists (function _, Mgtt_expr.Lit_str _ -> true | _ -> false) cs

(* ---- pair domains -------------------------------------------------------- *)

(* Two facts compared with each other share ONE cell, because the predicate
   reads the pair. What that cell must carry depends on what else is asked of
   them.

   When nothing else is asked, an ordering is enough — three members, which is
   exactly what six operators can distinguish about two values with no
   arithmetic between them.

   When a constant is also compared against either fact — `ready == desired`
   alongside `desired == 0` — an ordering is not enough, and neither are two
   independent region domains: independent regions cannot say `ready ==
   desired` when both land inside one region, and an ordering cannot say
   `desired == 0` at all. So the cell carries a REGION FOR EACH fact, cut by
   the constants applied to either of them, and the ordering falls out of
   comparing the two representatives. Combinations that cannot occur are not
   members: where the two regions differ, the ordering is already decided by
   which region is lower. *)

let pair_name (a, b) = a ^ ":" ^ b
let bare_pair_members = [ "fewer"; "equal"; "more" ]

(* Two values inside ONE region may still be ordered three ways — unless the
   region is a single point, where they can only be equal. *)
let within_region (r : region) =
  match two_inside r with
  | None -> [ ("equal", r.rep, r.rep) ]
  | Some (v1, v2) -> [ ("fewer", v1, v2); ("equal", v1, v1); ("more", v2, v1) ]

let joint_members (rs : region list) : (member * value) list =
  List.concat_map
    (fun (i, ri) ->
      List.concat_map
        (fun (j, rj) ->
          if i <> j then
            (* different regions: the ordering is already settled by which
               region is the lower, so there is one member and not three *)
            [
              ( ri.rname ^ "-vs-" ^ rj.rname,
                Vpair { left = ri.rep; right = rj.rep } );
            ]
          else
            List.map
              (fun (tag, l, r) ->
                (ri.rname ^ "-" ^ tag, Vpair { left = l; right = r }))
              (within_region ri))
        (List.mapi (fun j r -> (j, r)) rs))
    (List.mapi (fun i r -> (i, r)) rs)

(* ---- building the domains ------------------------------------------------ *)

let of_type (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) :
    domain list * Mgtt_ast.decline list =
  let exprs, declines = parsed_predicates ty comps in
  let pairs =
    List.sort_uniq compare (List.concat_map Mgtt_expr.pairs_of exprs)
  in
  let paired fact = List.exists (fun (a, b) -> a = fact || b = fact) pairs in
  let mentioned =
    List.sort_uniq compare (List.concat_map Mgtt_expr.facts_of exprs)
  in
  let constraints fact = List.concat_map (constraints_on fact) exprs in

  (* A pair's regions are cut by the constants applied to EITHER fact, and
     merged against both facts' constraints — one region set serves both, so it
     must be fine enough for the finer of the two. *)
  let pair_domain (a, b) =
    let cs = constraints a @ constraints b in
    match int_constants cs with
    | [] ->
        {
          dfact = pair_name (a, b);
          dtype = "mgtt.pair";
          members = bare_pair_members;
          interp =
            [
              ("fewer", Vpair { left = 0; right = 1 });
              ("equal", Vpair { left = 0; right = 0 });
              ("more", Vpair { left = 1; right = 0 });
            ];
        }
    | ks ->
        let interp = joint_members (merge_regions cs (cut_regions ks)) in
        {
          dfact = pair_name (a, b);
          dtype = "mgtt.pair";
          members = List.map fst interp;
          interp;
        }
  in
  let pair_domains = List.map pair_domain pairs in

  let single_domains, more_declines =
    List.fold_left
      (fun (doms, ds) (fact, ftype) ->
        if paired fact then (doms, ds)
        else if not (List.mem fact mentioned) then
          ( doms,
            {
              Mgtt_ast.what = ty.Mgtt_ast.tname ^ "." ^ fact;
              why =
                "no predicate mentions this fact, so it has no values worth \
                 naming — it is not carried into the model";
            }
            :: ds )
        else
          let cs = constraints fact in
          let interp =
            if is_bool cs then [ ("yes", Vbool true); ("no", Vbool false) ]
            else if is_string cs then
              List.map (fun m -> (m, Vstr m)) (string_members cs)
            else
              match int_constants cs with
              | [] -> []
              | ks ->
                  List.map
                    (fun r -> (r.rname, Vint r.rep))
                    (merge_regions cs (cut_regions ks))
          in
          if interp = [] then
            ( doms,
              {
                Mgtt_ast.what = ty.Mgtt_ast.tname ^ "." ^ fact;
                why = "compared against nothing writ can name";
              }
              :: ds )
          else
            ( {
                dfact = fact;
                dtype = ftype;
                members = List.map fst interp;
                interp;
              }
              :: doms,
              ds ))
      ([], []) ty.Mgtt_ast.facts
  in
  (List.rev single_domains @ pair_domains, List.rev (more_declines @ declines))

(* ---- evaluating against an assignment ------------------------------------ *)

let value_of (doms : domain list) (key : string) (m : member) : value option =
  match List.find_opt (fun d -> d.dfact = key) doms with
  | None -> None
  | Some d -> List.assoc_opt m d.interp

(* The representative this fact takes, whether it owns a domain or shares a
   pair's. [left]/[right] follow the pair's own alphabetical order, so which
   half to read is decided by comparing the names rather than by remembering
   which way round the caller wrote them. *)
let rep_of (doms : domain list) (assign : (string * member) list)
    (fact : string) : int option =
  let own =
    match List.assoc_opt fact assign with
    | Some m -> (
        match value_of doms fact m with Some (Vint v) -> Some v | _ -> None)
    | None -> None
  in
  match own with
  | Some v -> Some v
  | None ->
      List.find_map
        (fun (d : domain) ->
          match String.index_opt d.dfact ':' with
          | None -> None
          | Some i ->
              let a = String.sub d.dfact 0 i in
              let b =
                String.sub d.dfact (i + 1) (String.length d.dfact - i - 1)
              in
              if a <> fact && b <> fact then None
              else
                Option.bind (List.assoc_opt d.dfact assign) (fun m ->
                    match List.assoc_opt m d.interp with
                    | Some (Vpair p) ->
                        Some (if a = fact then p.left else p.right)
                    | _ -> None))
        doms

(* Does [assign] — a member per domain — satisfy [e]?

   Used by the emitter to pick a representative assignment for a state, and by
   the instance builder to find a healthy starting value. Anything it cannot
   decide is false rather than true: an emitter that guessed "satisfied" would
   write a move that does not realise the state it claims to. *)
let rec satisfies (doms : domain list) (e : Mgtt_expr.t)
    (assign : (string * member) list) : bool =
  match e with
  | Mgtt_expr.And (a, b) -> satisfies doms a assign && satisfies doms b assign
  | Mgtt_expr.Or (a, b) -> satisfies doms a assign || satisfies doms b assign
  | Mgtt_expr.Cmp { fact; op; rhs = Mgtt_expr.Fact_ref other } -> (
      (* both sides are representatives of the same cell, so the ordering is a
         comparison rather than a stored field that could contradict them *)
      match (rep_of doms assign fact, rep_of doms assign other) with
      | Some l, Some r -> eval_int op l r
      | _ -> false)
  | Mgtt_expr.Cmp { fact; op; rhs } -> (
      match rhs with
      | Mgtt_expr.Lit_int k -> (
          match rep_of doms assign fact with
          | Some v -> eval_int op v k
          | None -> false)
      | Mgtt_expr.Lit_bool b -> (
          match
            Option.bind (List.assoc_opt fact assign) (value_of doms fact)
          with
          | Some (Vbool v) -> if op = Mgtt_expr.Neq then v <> b else v = b
          | _ -> false)
      | Mgtt_expr.Lit_str str -> (
          match
            Option.bind (List.assoc_opt fact assign) (value_of doms fact)
          with
          | Some (Vstr v) ->
              let same = v = sanitize str in
              if op = Mgtt_expr.Neq then not same else same
          | _ -> false)
      | Mgtt_expr.Fact_ref _ -> false)

(* The members of one domain, or [] when the fact was not carried. *)
let members_of (doms : domain list) (fact : string) : member list =
  match List.find_opt (fun d -> d.dfact = fact) doms with
  | Some d -> d.members
  | None -> []
