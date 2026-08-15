(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* mgtt2writ unit tests.

   Three layers, tested apart because they fail differently: reading the export
   document, reducing mgtt's facts to finite domains, and emitting a model.

   The reduction is the one carrying the argument. mgtt's expression language
   has six comparison operators and no arithmetic, so the constants a model
   mentions cut each fact's value line into finitely many regions on which
   every predicate is constant — which is what makes the crossing lossless
   rather than approximate. These tests pin the two places that claim could
   quietly stop being true: the parser's treatment of a bare right-hand side,
   and the merging of regions nothing separates. *)

open Mgtt2writ

let passed = ref 0

let check name cond =
  if cond then incr passed
  else (
    print_string ("FAIL: " ^ name ^ "\n");
    exit 1)

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then false
    else if String.sub s i lsub = sub then true
    else go (i + 1)
  in
  go 0

let doc_of_string (s : string) : Mgtt_ast.doc =
  match Json_parse.parse s with
  | Error e -> failwith ("json: " ^ e)
  | Ok j -> (
      match Mgtt_read.of_json j with
      | Error e -> failwith ("read: " ^ e)
      | Ok d -> d)

(* A two-component export: a datastore whose facts are a bool and a
   single-threshold int, and a workload whose healthy clause compares two facts
   with each other. Between them they exercise every domain shape. *)
let minimal =
  {|{"mgtt_export_version":1,"name":"storefront",
     "components":[
       {"name":"api","type":"workload","depends":[{"on":"store","while":""}],
        "healthy":["ready_replicas == desired_replicas"],
        "failure_modes":{"degraded":["upstream_failure"]}},
       {"name":"store","type":"datastore","depends":[],
        "healthy":["available == true","connection_count < 500"],
        "failure_modes":{"stopped":["upstream_failure"]}}],
     "types":[
       {"name":"datastore","provider":"datalayer",
        "facts":[{"name":"available","type":"mgtt.bool"},
                 {"name":"connection_count","type":"mgtt.int"}],
        "healthy":["available == true","connection_count < 500"],
        "states":[{"name":"live","when":"available == true","triggered_by":[]},
                  {"name":"stopped","when":"available == false","triggered_by":[]}],
        "default_active_state":"live",
        "failure_modes":{"stopped":["upstream_failure"]}},
       {"name":"workload","provider":"compute",
        "facts":[{"name":"desired_replicas","type":"mgtt.int"},
                 {"name":"ready_replicas","type":"mgtt.int"}],
        "healthy":["ready_replicas == desired_replicas"],
        "states":[{"name":"live","when":"ready_replicas == desired_replicas","triggered_by":[]},
                  {"name":"degraded","when":"ready_replicas < desired_replicas","triggered_by":["upstream_failure"]}],
        "default_active_state":"live",
        "failure_modes":{"degraded":["upstream_failure"]}}],
     "declines":[]}|}

(* ---- the document ------------------------------------------------------- *)

let test_read () =
  let d = doc_of_string minimal in
  check "read: name" (d.Mgtt_ast.name = "storefront");
  check "read: two components" (List.length d.Mgtt_ast.components = 2);
  check "read: two types" (List.length d.Mgtt_ast.types = 2);
  let store =
    match Mgtt_ast.component_of d "store" with
    | Some c -> c
    | None -> failwith "no store"
  in
  check "read: store healthy carries both clauses"
    (List.length store.Mgtt_ast.chealthy = 2);
  check "read: store can_cause"
    (Mgtt_ast.can_cause store "stopped" = [ "upstream_failure" ]);
  let api =
    match Mgtt_ast.component_of d "api" with
    | Some c -> c
    | None -> failwith "no api"
  in
  check "read: api depends on store" (api.Mgtt_ast.depends = [ ("store", "") ])

let test_read_type_lookup () =
  let d = doc_of_string minimal in
  match Mgtt_ast.type_of d "datastore" with
  | None -> check "read: datastore type present" false
  | Some t ->
      check "read: two facts" (List.length t.Mgtt_ast.facts = 2);
      check "read: default state" (t.Mgtt_ast.default_state = "live");
      (* declared order, not sorted — the emitter depends on it *)
      check "read: states keep declared order"
        (List.map (fun (s : Mgtt_ast.state) -> s.sname) t.Mgtt_ast.states
        = [ "live"; "stopped" ])

let test_read_components_of_type () =
  let d = doc_of_string minimal in
  check "read: one component per type"
    (List.length (Mgtt_ast.components_of_type d "workload") = 1)

let test_read_rejects_unknown_version () =
  let j =
    match
      Json_parse.parse
        {|{"mgtt_export_version":99,"name":"x","components":[],"types":[]}|}
    with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses a future schema version"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_rejects_non_export () =
  let j =
    match Json_parse.parse {|{"hello":"world"}|} with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses a document that is not an export"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_rejects_empty_roster () =
  let j =
    match
      Json_parse.parse
        {|{"mgtt_export_version":1,"name":"x","components":[],"types":[]}|}
    with
    | Ok j -> j
    | Error e -> failwith e
  in
  check "read: refuses an export with no components"
    (match Mgtt_read.of_json j with Error _ -> true | Ok _ -> false)

let test_read_carries_mgtt_declines () =
  let d =
    doc_of_string
      {|{"mgtt_export_version":1,"name":"x",
         "components":[{"name":"c","type":"t","depends":[],"healthy":[],"failure_modes":{}}],
         "types":[],
         "declines":[{"what":"c","why":"type \"t\" resolved to the generic fallback"}]}|}
  in
  check "read: mgtt's own declines survive the crossing"
    (List.length d.Mgtt_ast.declines = 1)

(* ---- the expression language -------------------------------------------- *)

let parse_ok what s =
  match Mgtt_expr.parse s with
  | Ok e -> e
  | Error m -> failwith (what ^ ": " ^ s ^ ": " ^ m)

let test_expr_comparison () =
  match parse_ok "cmp" "connection_count < 500" with
  | Mgtt_expr.Cmp c ->
      check "expr: fact" (c.Mgtt_expr.fact = "connection_count");
      check "expr: op" (c.Mgtt_expr.op = Mgtt_expr.Lt);
      check "expr: rhs" (c.Mgtt_expr.rhs = Mgtt_expr.Lit_int 500)
  | _ -> check "expr: parses a comparison" false

let test_expr_bool () =
  match parse_ok "bool" "available == true" with
  | Mgtt_expr.Cmp c ->
      check "expr: bool rhs" (c.Mgtt_expr.rhs = Mgtt_expr.Lit_bool true)
  | _ -> check "expr: parses a bool comparison" false

(* The subtlety that decides whether the whole reduction is correct: mgtt's
   compareFactValue re-interprets a non-numeric right-hand side as a reference
   to a sibling fact. Reading it as a string literal would silently turn this
   into a comparison against the word "desired_replicas", which is never true. *)
let test_expr_bare_word_is_a_fact_reference () =
  match parse_ok "ref" "ready_replicas == desired_replicas" with
  | Mgtt_expr.Cmp c ->
      check "expr: bare word rhs is a fact reference"
        (c.Mgtt_expr.rhs = Mgtt_expr.Fact_ref "desired_replicas")
  | _ -> check "expr: parses a fact-to-fact comparison" false

(* ...and quoting is how an author says they meant the word itself. *)
let test_expr_quoted_is_a_literal () =
  match parse_ok "lit" {|status == "running"|} with
  | Mgtt_expr.Cmp c ->
      check "expr: quoted rhs is a string literal"
        (c.Mgtt_expr.rhs = Mgtt_expr.Lit_str "running")
  | _ -> check "expr: parses a quoted comparison" false

let test_expr_connectives () =
  (match parse_ok "and" "a < 1 & b > 2" with
  | Mgtt_expr.And _ -> check "expr: & is conjunction" true
  | _ -> check "expr: parses a conjunction" false);
  (match parse_ok "or" "a < 1 | b > 2" with
  | Mgtt_expr.Or _ -> check "expr: | is disjunction" true
  | _ -> check "expr: parses a disjunction" false);
  match parse_ok "paren" "(a < 1 | b > 2) & c == true" with
  | Mgtt_expr.And _ -> check "expr: parentheses group" true
  | _ -> check "expr: parses a parenthesised expression" false

let test_expr_facts_of () =
  let e =
    parse_ok "facts" "ready_replicas < desired_replicas & endpoints > 0"
  in
  let fs = List.sort compare (Mgtt_expr.facts_of e) in
  check "expr: facts_of finds both sides of a reference"
    (fs = [ "desired_replicas"; "endpoints"; "ready_replicas" ])

(* Writ has no numbers to name a member after, and inventing an ordering for
   a float would be a guess. Refusing loudly is what `writ sql` does with
   arithmetic in a CHECK, and it is what keeps the crossing honest. *)
let test_expr_refuses_non_integer_constant () =
  check "expr: refuses a float constant"
    (match Mgtt_expr.parse "ratio < 0.75" with
    | Error _ -> true
    | Ok _ -> false)

let test_expr_refuses_malformed () =
  check "expr: refuses a bare word"
    (match Mgtt_expr.parse "available" with Error _ -> true | Ok _ -> false);
  check "expr: refuses a dangling operator"
    (match Mgtt_expr.parse "a <" with Error _ -> true | Ok _ -> false)

(* ---- the reduction ------------------------------------------------------ *)

let domains_for tyname =
  let d = doc_of_string minimal in
  let ty =
    match Mgtt_ast.type_of d tyname with Some t -> t | None -> failwith tyname
  in
  fst (Mgtt_domains.of_type ty (Mgtt_ast.components_of_type d tyname))

let members_of doms fact =
  match
    List.find_opt
      (fun (d : Mgtt_domains.domain) -> d.Mgtt_domains.dfact = fact)
      doms
  with
  | Some d -> d.Mgtt_domains.members
  | None -> []

let test_domains_bool () =
  check "domains: a bool fact becomes yes/no"
    (members_of (domains_for "datastore") "available" = [ "yes"; "no" ])

(* `connection_count < 500` is the only predicate on it, so two members are
   enough — nothing in the model distinguishes 500 from 501, and emitting a
   third member would double the state space to represent a distinction the
   engine could never have made. *)
let test_domains_single_threshold () =
  check "domains: one threshold, two members"
    (members_of (domains_for "datastore") "connection_count"
    = [ "below-500"; "at-or-above-500" ])

(* A fact compared with a sibling gets ONE joint domain, because the predicate
   reads the pair. Same-component only, which mgtt's evaluator guarantees. *)
let test_domains_fact_pair () =
  let doms = domains_for "workload" in
  check "domains: a fact pair is one joint domain"
    (members_of doms "desired_replicas:ready_replicas"
    = [ "fewer"; "equal"; "more" ]);
  check "domains: the paired facts get no independent domains"
    (members_of doms "ready_replicas" = []
    && members_of doms "desired_replicas" = [])

let test_domains_equality_threshold () =
  (* `== 5` and `< 5` together DO separate 5 from 6, so three members. *)
  let ty =
    {
      Mgtt_ast.tname = "t";
      facts = [ ("n", "mgtt.int") ];
      thealthy = [ "n < 5" ];
      states =
        [
          { Mgtt_ast.sname = "exact"; swhen = "n == 5"; striggered = [] };
          { Mgtt_ast.sname = "low"; swhen = "n < 5"; striggered = [] };
        ];
      default_state = "low";
      tmodes = [];
    }
  in
  let doms, _ = Mgtt_domains.of_type ty [] in
  check "domains: == and < separate the point from what is above it"
    (members_of doms "n" = [ "below-5"; "exactly-5"; "above-5" ])

let test_domains_satisfies () =
  let doms = domains_for "datastore" in
  let e = parse_ok "sat" "available == true & connection_count < 500" in
  check "domains: healthy assignment satisfies"
    (Mgtt_domains.satisfies doms e
       [ ("available", "yes"); ("connection_count", "below-500") ]);
  check "domains: a failing assignment does not"
    (not
       (Mgtt_domains.satisfies doms e
          [ ("available", "no"); ("connection_count", "below-500") ]))

(* A pair of facts compared with each other AND against constants needs a JOINT
   domain: the ordering alone cannot say `desired_replicas == 0`, and two
   independent region domains cannot say `ready == desired` when both land in
   the same region. The members are the consistent combinations of the two
   facts' regions, carrying the ordering where the regions coincide. *)
let paired_with_constant_ty =
  {
    Mgtt_ast.tname = "workload";
    facts = [ ("desired", "mgtt.int"); ("ready", "mgtt.int") ];
    thealthy = [ "ready == desired" ];
    states =
      [
        { Mgtt_ast.sname = "live"; swhen = "ready == desired"; striggered = [] };
        { Mgtt_ast.sname = "draining"; swhen = "desired == 0"; striggered = [] };
      ];
    default_state = "live";
    tmodes = [];
  }

let test_domains_pair_with_constant_is_joint () =
  let doms, declines = Mgtt_domains.of_type paired_with_constant_ty [] in
  check "domains: a pair carrying a constant is no longer declined"
    (not
       (List.exists
          (fun (d : Mgtt_ast.decline) -> contains ~sub:"sibling" d.Mgtt_ast.why)
          declines));
  let ms = members_of doms "desired:ready" in
  check "domains: the joint domain exists" (ms <> []);
  check "domains: it is richer than a bare ordering" (List.length ms > 3);
  check "domains: the paired facts get no independent domains"
    (members_of doms "desired" = [] && members_of doms "ready" = [])

(* The point of the joint domain: both kinds of question are decidable on it. *)
let test_domains_pair_with_constant_satisfies () =
  let doms, _ = Mgtt_domains.of_type paired_with_constant_ty [] in
  let ms = members_of doms "desired:ready" in
  let sat src m =
    Mgtt_domains.satisfies doms (parse_ok "joint" src) [ ("desired:ready", m) ]
  in
  (* every member answers both questions, and the answers are consistent *)
  check "domains: some member is draining (desired == 0)"
    (List.exists (fun m -> sat "desired == 0" m) ms);
  check "domains: some member is live (ready == desired)"
    (List.exists (fun m -> sat "ready == desired" m) ms);
  check "domains: some member is both at once"
    (List.exists (fun m -> sat "desired == 0" m && sat "ready == desired" m) ms);
  check "domains: some member is neither"
    (List.exists
       (fun m -> (not (sat "desired == 0" m)) && not (sat "ready == desired" m))
       ms);
  (* the ordering stays coherent: nothing is both fewer and more *)
  check "domains: the ordering is coherent"
    (List.for_all
       (fun m -> not (sat "ready < desired" m && sat "ready > desired" m))
       ms);
  (* and a value below zero cannot also equal zero *)
  check "domains: regions are coherent"
    (List.for_all
       (fun m -> not (sat "desired < 0" m && sat "desired == 0" m))
       ms)

(* A member says which region EACH fact is in, and the ordering between them.
   Those two claims have to agree: a member naming a region must not hold values
   outside it. The first cut of this got it wrong — representing "both in this
   region, left larger" as (rep, rep+1) let the left value escape into the next
   region up, so a member named `below-0-more` satisfied `desired == 0`. It
   passed every coherence check and was still a lie about what it named. *)
let test_domains_pair_members_stay_inside_their_regions () =
  let doms, _ = Mgtt_domains.of_type paired_with_constant_ty [] in
  let ms = members_of doms "desired:ready" in
  let sat src m =
    Mgtt_domains.satisfies doms (parse_ok "region" src) [ ("desired:ready", m) ]
  in
  (* `desired == 0` may hold ONLY where the member names desired's region as
     exactly-0 — that is, a same-region `exactly-0-*` or a `exactly-0-vs-*` *)
  List.iter
    (fun m ->
      let names_exactly_0 =
        String.length m >= 9 && String.sub m 0 9 = "exactly-0"
      in
      if sat "desired == 0" m && not names_exactly_0 then
        check
          ("domains: member `" ^ m
         ^ "` satisfies desired == 0 but does not name that region")
          false)
    ms;
  check "domains: at least one member does name it"
    (List.exists (fun m -> sat "desired == 0" m) ms);
  (* and the mirror: a member naming exactly-0 on the left must agree *)
  List.iter
    (fun m ->
      let names_exactly_0 =
        String.length m >= 9 && String.sub m 0 9 = "exactly-0"
      in
      if names_exactly_0 && not (sat "desired == 0" m) then
        check
          ("domains: member `" ^ m ^ "` names exactly-0 but does not satisfy it")
          false)
    ms;
  check "domains: regions and members agree in both directions" true

let test_domains_pair_without_constant_stays_small () =
  (* the common case must not get more expensive *)
  let doms = domains_for "workload" in
  check "domains: a bare pair is still three members"
    (members_of doms "desired_replicas:ready_replicas"
    = [ "fewer"; "equal"; "more" ])

let test_domains_declines_unbounded_fact () =
  (* a fact no predicate ever mentions has no regions to name, so it cannot
     become an arrow — say so rather than invent a domain for it *)
  let ty =
    {
      Mgtt_ast.tname = "t";
      facts = [ ("mentioned", "mgtt.bool"); ("unmentioned", "mgtt.int") ];
      thealthy = [ "mentioned == true" ];
      states =
        [
          {
            Mgtt_ast.sname = "live";
            swhen = "mentioned == true";
            striggered = [];
          };
        ];
      default_state = "live";
      tmodes = [];
    }
  in
  let doms, declines = Mgtt_domains.of_type ty [] in
  check "domains: an unmentioned fact gets no domain"
    (members_of doms "unmentioned" = []);
  check "domains: and is declined rather than dropped" (declines <> [])

(* ---- the emitter -------------------------------------------------------- *)

let emit_minimal () = Emit_mgtt.file ~name:"storefront" (doc_of_string minimal)

(* The two checks that read the emitted text back through writ's REAL front
   end do not live here. They cannot: this tool vendors writ's JSON reader and
   nothing else, and vendoring its parser to test against would mean testing
   against a COPY that ages out of step with the writ anyone actually runs —
   an oracle that keeps passing as it stops meaning anything.

   They are re-homed as the end-to-end pipeline check (test/pipeline.sh), which
   runs the real binaries. That is a strictly stronger oracle: a vendored parser
   proves "some parser accepts this", the real one proves "the writ you have
   accepts this", which is the claim a user cares about.

   What stays here is everything decidable from the translation alone. *)

let test_emit_shape () =
  let text, _ = emit_minimal () in
  check "emit: is kernel-only, loading nothing"
    (not (contains ~sub:"(load " text));
  check "emit: declares the schema" (contains ~sub:"(schema storefront" text);
  check "emit: declares an instance"
    (contains ~sub:"(instance start storefront" text);
  check "emit: names the initial situation"
    (contains ~sub:"(initial start)" text);
  (* underscores survive in the traceability comments on purpose — what must
     be hyphenated is every identifier the language reads *)
  check "emit: arrows are hyphenated"
    (contains ~sub:"(arrow connection-count" text);
  check "emit: no chain carries an underscore"
    (not (contains ~sub:".connection_count" text))

let test_emit_domains_as_types () =
  let text, _ = emit_minimal () in
  check "emit: a bool domain"
    (contains ~sub:"(type datastore-available (yes no))" text);
  check "emit: a merged threshold domain"
    (contains
       ~sub:"(type datastore-connection-count (below-500 at-or-above-500))" text)

(* The law the bridge exists for. *)
let test_emit_health_equation () =
  let text, _ = emit_minimal () in
  check "emit: the health law is present"
    (contains ~sub:"-health-matches-state" text);
  check "emit: written with iff" (contains ~sub:"(iff " text)

let test_emit_names_transitions () =
  let text, _ = emit_minimal () in
  (* store.stopped can_cause upstream_failure; workload.degraded is
     triggered_by it — so exactly one propagation move, and it is named. *)
  check "emit: the propagation move is named"
    (contains ~sub:"(transition store-stopped-triggers-api-degraded" text)

(* A state no assignment satisfies cannot be triggered, and saying so is the
   same finding mgtt's own validate reports for an unreachable state. *)
let test_emit_declines_unsatisfiable_state () =
  let unsat =
    {|{"mgtt_export_version":1,"name":"x",
       "components":[
         {"name":"a","type":"t","depends":[],"healthy":["up == true"],
          "failure_modes":{"broken":["upstream_failure"]}},
         {"name":"b","type":"t","depends":[{"on":"a","while":""}],
          "healthy":["up == true"],"failure_modes":{}}],
       "types":[
         {"name":"t","provider":"p",
          "facts":[{"name":"up","type":"mgtt.bool"}],
          "healthy":["up == true"],
          "states":[{"name":"live","when":"up == true","triggered_by":[]},
                    {"name":"broken","when":"up == false","triggered_by":[]},
                    {"name":"impossible","when":"up == true & up == false",
                     "triggered_by":["upstream_failure"]}],
          "default_active_state":"live","failure_modes":{"broken":["upstream_failure"]}}],
       "declines":[]}|}
  in
  let _, declines = Emit_mgtt.file ~name:"x" (doc_of_string unsat) in
  check "emit: an unsatisfiable triggered state is declined"
    (List.exists
       (fun (dc : Mgtt_ast.decline) ->
         contains ~sub:"impossible" dc.Mgtt_ast.what)
       declines)

(* Every component must be able to fail on its own, or the model has no
   dynamics: propagation only relays a failure, so with nothing to originate
   one the initial situation is the only reachable situation and every question
   answers vacuously. *)
let test_emit_originations () =
  let text, _ = emit_minimal () in
  check "emit: a component can fail on its own"
    (contains ~sub:"(transition store-fails-stopped" text)

(* The finding the bridge exists for, end to end.

   This is the shape recorded in mgtt's own divergence note: a component whose
   `healthy:` override ignores the fact its type's state guard reads. mgtt's
   simulate and diagnose then consult different facts and disagree. Here the
   two routes are an `iff`, so a situation where they part is a violation of a
   law rather than a difference nobody notices. *)
let test_emit_catches_health_state_divergence () =
  let diverging =
    {|{"mgtt_export_version":1,"name":"d",
       "components":[
         {"name":"store","type":"datastore","depends":[],
          "healthy":["connection_count < 500"],
          "failure_modes":{"stopped":["upstream_failure"]}}],
       "types":[
         {"name":"datastore","provider":"p",
          "facts":[{"name":"available","type":"mgtt.bool"},
                   {"name":"connection_count","type":"mgtt.int"}],
          "healthy":["available == true","connection_count < 500"],
          "states":[{"name":"live","when":"available == true","triggered_by":[]},
                    {"name":"stopped","when":"available == false","triggered_by":[]}],
          "default_active_state":"live",
          "failure_modes":{"stopped":["upstream_failure"]}}],
       "declines":[]}|}
  in
  let text, _ = Emit_mgtt.file ~name:"d" (doc_of_string diverging) in
  (* the override earns its own type, so the law ranges over that one component *)
  check "emit: an overriding component gets its own type"
    (contains ~sub:"(type datastore-store" text);
  check "emit: and its own law"
    (contains ~sub:"(equation datastore-store-health-matches-state" text);
  (* the law compares the overridden health against the type's active state,
     which is what makes the disagreement visible *)
  check "emit: the law reads health against the active state"
    (contains ~sub:"(is datastore-store.connection-count below-500)" text
    && contains ~sub:"(is datastore-store.available yes)" text);
  (* and the move that reaches the disagreement exists *)
  check "emit: the move reaching the violation is present"
    (contains ~sub:"(transition store-fails-stopped" text)

(* mgtt's own declines travel through rather than being dropped at the seam. *)
let test_emit_forwards_mgtt_declines () =
  let d =
    doc_of_string
      {|{"mgtt_export_version":1,"name":"x",
         "components":[{"name":"c","type":"t","depends":[],"healthy":[],"failure_modes":{}}],
         "types":[],
         "declines":[{"what":"c","why":"resolved to the generic fallback"}]}|}
  in
  let _, declines = Emit_mgtt.file ~name:"x" d in
  check "emit: mgtt's declines are forwarded"
    (List.exists
       (fun (dc : Mgtt_ast.decline) -> contains ~sub:"generic" dc.Mgtt_ast.why)
       declines)

(* A REAL export, produced by `mgtt model export --json` and committed here.

   The hand-written documents above pin the reading; this one pins the
   CONTRACT. mgtt and writ release separately, so the risk this guards is not a
   version bump — writ refuses a version it does not know — but mgtt quietly
   changing what a field MEANS while its shape and version stay put. Reading a
   real document end to end, and asserting on what it should produce, turns
   that drift into a failure in this suite rather than in a user's terminal.

   Refresh it deliberately, from a real run, when the schema version changes.
   See mgtt's docs/decisions/0001-where-the-writ-bridge-lives.md. *)
let test_pinned_export_contract () =
  let path = "fixtures/mgtt-export-v1.json" in
  let src =
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  in
  let d =
    match Json_parse.parse src with
    | Error e -> failwith (path ^ ": " ^ e)
    | Ok j -> (
        match Mgtt_read.of_json j with
        | Error e -> failwith (path ^ ": " ^ e)
        | Ok d -> d)
  in
  check "contract: the pinned export still reads"
    (List.length d.Mgtt_ast.components = 4 && List.length d.Mgtt_ast.types = 3);
  (* the fields the reading actually depends on are all populated *)
  check "contract: components carry an effective healthy list"
    (List.for_all
       (fun (c : Mgtt_ast.comp) -> c.Mgtt_ast.chealthy <> [])
       d.Mgtt_ast.components);
  check "contract: types carry facts, states and a default state"
    (List.for_all
       (fun (t : Mgtt_ast.ty) ->
         t.Mgtt_ast.facts <> [] && t.Mgtt_ast.states <> []
         && t.Mgtt_ast.default_state <> "")
       d.Mgtt_ast.types);
  check "contract: the propagation protocol is present on both halves"
    (List.exists
       (fun (t : Mgtt_ast.ty) -> t.Mgtt_ast.tmodes <> [])
       d.Mgtt_ast.types
    && List.exists
         (fun (t : Mgtt_ast.ty) ->
           List.exists
             (fun (s : Mgtt_ast.state) -> s.Mgtt_ast.striggered <> [])
             t.Mgtt_ast.states)
         d.Mgtt_ast.types);
  (* the model it yields is checked by the pipeline test, which runs real writ *)
  let _, declines = Emit_mgtt.file ~name:"pinned" d in
  check "contract: the pinned export declines nothing" (declines = [])


(* The emitted model is the deliverable, and it is the one artifact a user
   opens. It must not name a verb of the tool that reads it: `writ mgtt` was
   deleted, and this tool exists precisely so that neither project names the
   other. A stale attribution here would undo that decision in the most visible
   place there is — the first line of the file.

   `writ sql` may still be mentioned: that is a comparison explaining a real
   property of this output (kernel-only, nothing loaded), not a claim about who
   generated it. *)
let test_emit_attributes_itself () =
  let text, _ = emit_minimal () in
  check "emit: does not claim to be a writ verb"
    (not (contains ~sub:"writ mgtt" text));
  check "emit: attributes itself" (contains ~sub:"Generated by mgtt2writ" text)

let () =
  test_read ();
  test_read_type_lookup ();
  test_read_components_of_type ();
  test_read_rejects_unknown_version ();
  test_read_rejects_non_export ();
  test_read_rejects_empty_roster ();
  test_read_carries_mgtt_declines ();
  test_expr_comparison ();
  test_expr_bool ();
  test_expr_bare_word_is_a_fact_reference ();
  test_expr_quoted_is_a_literal ();
  test_expr_connectives ();
  test_expr_facts_of ();
  test_expr_refuses_non_integer_constant ();
  test_expr_refuses_malformed ();
  test_domains_bool ();
  test_domains_single_threshold ();
  test_domains_fact_pair ();
  test_domains_equality_threshold ();
  test_domains_satisfies ();
  test_domains_pair_with_constant_is_joint ();
  test_domains_pair_with_constant_satisfies ();
  test_domains_pair_members_stay_inside_their_regions ();
  test_domains_pair_without_constant_stays_small ();
  test_domains_declines_unbounded_fact ();
  test_emit_attributes_itself ();
  test_emit_shape ();
  test_emit_domains_as_types ();
  test_emit_health_equation ();
  test_emit_names_transitions ();
  test_emit_originations ();
  test_emit_catches_health_state_divergence ();
  test_emit_declines_unsatisfiable_state ();
  test_emit_forwards_mgtt_declines ();
  test_pinned_export_contract ();
  print_string ("test_mgtt2writ: " ^ string_of_int !passed ^ " passed\n")
