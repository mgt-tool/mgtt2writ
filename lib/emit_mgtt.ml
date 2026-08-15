(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Mgtt_ast.doc] -> a .writ file, as text.

   Text rather than datums, for the reason [Emit_writ] gives about SQL: the
   output is a model somebody now OWNS. They will add claims to it, read it to
   find out what their architecture actually says, and diff it across
   revisions. So it is commented, grouped, and spelled the way a person would
   spell it — and every generated block names the mgtt construct it came from,
   so a finding can be walked back to a line of YAML.

   The shape of the file is fixed:

     the vocabulary   the forms this reading needs
     the schema       fact domains, component types, the health laws
     the instance     one entity per component, every fact at a healthy value
     the moves        one transition per propagation edge

   FACTS ARE THE ONLY VARYING CELLS. There is no `state` arrow, and that is the
   central decision. mgtt's states and its `healthy:` block are both predicates
   over facts, so modelling the facts and deriving both makes their agreement a
   real writ `equation` over real cells rather than a check this emitter would
   have to perform itself. It is also what keeps the space small: the initial
   situation is every component healthy, and transitions only move facts toward
   failing values, so what gets enumerated is the set of reachable FAILURE
   CONFIGURATIONS — the same set mgtt's own chain enumerator walks. *)

open Mgtt_ast

let buf_add = Buffer.add_string

(* A component type in the emitted schema. One per distinct (mgtt type,
   effective healthy) pair, not one per mgtt type — because a law's subject
   must be a declared TYPE (kernel spec §8.6), so a component that overrides
   `healthy:` needs a type of its own for its own law to range over. That
   override is precisely the case mgtt's simulate/diagnose divergence came
   from, so collapsing it away would drop the finding worth the most. *)
type emitted_type = {
  ename : string;  (** the writ type name *)
  source : Mgtt_ast.ty;  (** the mgtt type it reads *)
  healthy : string list;  (** the effective healthy clauses *)
  members : string list;  (** component names carrying this type *)
  doms : Mgtt_domains.domain list;
}

let parse_all (clauses : string list) : Mgtt_expr.t list =
  List.filter_map
    (fun s -> match Mgtt_expr.parse s with Ok e -> Some e | Error _ -> None)
    clauses

let state_named (ty : Mgtt_ast.ty) (name : string) : Mgtt_ast.state option =
  List.find_opt (fun (s : Mgtt_ast.state) -> s.sname = name) ty.states

(* ---- deciding the types -------------------------------------------------- *)

(* Group components by their mgtt type and their effective healthy list. The
   group keeping the type's own healthy takes the type's name; any other takes
   the type's name and the component's, since it exists for that component. *)
let plan_types (d : doc) : emitted_type list * decline list =
  let declines = ref [] in
  let out = ref [] in
  List.iter
    (fun (ty : Mgtt_ast.ty) ->
      let comps = Mgtt_ast.components_of_type d ty.tname in
      let doms, ds = Mgtt_domains.of_type ty comps in
      declines := !declines @ ds;
      let groups = Hashtbl.create 4 in
      List.iter
        (fun (c : comp) ->
          let key = String.concat "\x00" c.chealthy in
          let prev = try Hashtbl.find groups key with Not_found -> [] in
          Hashtbl.replace groups key (prev @ [ c ]))
        comps;
      Hashtbl.iter
        (fun _ (cs : comp list) ->
          match cs with
          | [] -> ()
          | first :: _ ->
              let same_as_type = first.chealthy = ty.thealthy in
              let name =
                if same_as_type then Mgtt_guard.writ_name ty.tname
                else
                  Mgtt_guard.writ_name ty.tname
                  ^ "-"
                  ^ Mgtt_guard.writ_name first.cname
              in
              out :=
                {
                  ename = name;
                  source = ty;
                  healthy = first.chealthy;
                  members = List.map (fun (c : comp) -> c.cname) cs;
                  doms;
                }
                :: !out)
        groups)
    d.types;
  (List.sort (fun a b -> compare a.ename b.ename) !out, !declines)

let type_of_component (ets : emitted_type list) (name : string) :
    emitted_type option =
  List.find_opt (fun et -> List.mem name et.members) ets

(* ---- the vocabulary ------------------------------------------------------ *)

let emit_forms (b : Buffer.t) =
  buf_add b
    ";; ---- the mgtt vocabulary, as forms over the 26 words ----\n\
     ;;\n\
     ;; `iff` is what \"healthy exactly when the state is the active one\"\n\
     ;; needs and the kernel does not ship: a law must be a guard, and mutual\n\
     ;; implication is two of them. A form renames and pastes, so an error\n\
     ;; inside it still points at the line generated here.\n\n\
     (form (iff A B) (or (and A B) (and (not A) (not B))))\n\n"

(* ---- the schema ---------------------------------------------------------- *)

let emit_domains (b : Buffer.t) (ets : emitted_type list) =
  buf_add b "  ;; ---- fact domains ----\n";
  buf_add b
    "  ;; One member per region the model's own predicates cut out of a fact's\n\
    \  ;; values. Regions nothing separates are merged, so a single threshold\n\
    \  ;; costs two members and not three.\n";
  let seen = Hashtbl.create 8 in
  List.iter
    (fun et ->
      List.iter
        (fun (dm : Mgtt_domains.domain) ->
          let n = Mgtt_guard.domain_type_name et.source.tname dm in
          if not (Hashtbl.mem seen n) then begin
            Hashtbl.replace seen n ();
            buf_add b
              ("  (type " ^ n ^ " ("
              ^ String.concat " " dm.Mgtt_domains.members
              ^ "))\n")
          end)
        et.doms)
    ets;
  buf_add b "\n"

let emit_types (b : Buffer.t) (ets : emitted_type list) =
  buf_add b "  ;; ---- component types ----\n";
  List.iter
    (fun et ->
      buf_add b
        ("  ;; mgtt type `" ^ et.source.tname ^ "` — "
        ^ String.concat ", " et.members
        ^ "\n");
      buf_add b ("  (type " ^ et.ename ^ "\n");
      let arrows =
        List.map
          (fun (dm : Mgtt_domains.domain) ->
            "    (arrow "
            ^ Mgtt_guard.arrow_of_domain dm
            ^ " (to "
            ^ Mgtt_guard.domain_type_name et.source.tname dm
            ^ "))")
          et.doms
      in
      buf_add b (String.concat "\n" arrows);
      buf_add b ")\n\n")
    ets

(* The law the bridge exists for: a component is healthy exactly when it is in
   its default active state. mgtt derives one from `healthy:` and the other
   from the type's state `when:` rules, and nothing keeps them consistent — the
   divergence that made `simulate` and `diagnose` disagree. Here it is a claim
   the model is measured against, reported with a route to the nearest
   violating situation. *)
let emit_equations (b : Buffer.t) (ets : emitted_type list) : decline list =
  let declines = ref [] in
  buf_add b "  ;; ---- laws ----\n";
  List.iter
    (fun et ->
      let subject = et.ename in
      let healthy = parse_all et.healthy in
      match state_named et.source et.source.default_state with
      | None ->
          declines :=
            {
              what = et.source.tname;
              why =
                "default_active_state `" ^ et.source.default_state
                ^ "` is not a declared state, so health cannot be matched \
                   against it";
            }
            :: !declines
      | Some active -> (
          match Mgtt_expr.parse active.swhen with
          | Error m ->
              declines :=
                {
                  what = et.source.tname ^ "." ^ active.sname;
                  why = "state guard not readable: " ^ m;
                }
                :: !declines
          | Ok active_e -> (
              match
                ( Mgtt_guard.clauses_to_writ et.doms ~subject healthy,
                  Mgtt_guard.to_writ_opt et.doms ~subject active_e )
              with
              | Ok (Some h), Ok a ->
                  buf_add b
                    ("  ;; healthy: "
                    ^ String.concat " & " et.healthy
                    ^ "\n  ;; active:  " ^ active.swhen ^ "\n");
                  buf_add b
                    ("  (equation " ^ et.ename
                   ^ "-health-matches-state\n    (iff " ^ h ^ "\n         " ^ a
                   ^ "))\n\n")
              | Ok None, _ ->
                  declines :=
                    {
                      what = et.ename;
                      why = "no healthy predicate, so there is no law to check";
                    }
                    :: !declines
              | Error m, _ | _, Error m ->
                  declines :=
                    {
                      what = et.ename;
                      why = "health law not expressible: " ^ m;
                    }
                    :: !declines)))
    ets;
  List.rev !declines

(* ---- the instance -------------------------------------------------------- *)

let emit_instance (b : Buffer.t) (d : doc) (ets : emitted_type list) :
    decline list =
  let declines = ref [] in
  buf_add b
    ";; Every component starts in its default active state, and healthy where\n\
     ;; the two agree. Where they cannot, the model starts in a situation its\n\
     ;; own health law reports — which is the finding, not a defect here.\n";
  buf_add b ("(instance start " ^ Mgtt_guard.writ_name d.name ^ "\n");
  List.iter
    (fun (c : comp) ->
      match type_of_component ets c.cname with
      | None -> ()
      | Some et -> (
          let healthy = parse_all c.chealthy in
          let healthy_e =
            match healthy with
            | [] -> None
            | f :: rest ->
                Some (List.fold_left (fun a e -> Mgtt_expr.And (a, e)) f rest)
          in
          match state_named et.source et.source.default_state with
          | None -> ()
          | Some active -> (
              match Mgtt_expr.parse active.swhen with
              | Error _ -> ()
              | Ok active_e -> (
                  match
                    Mgtt_guard.witness_preferring et.doms active_e healthy_e
                  with
                  | None ->
                      declines :=
                        {
                          what = c.cname;
                          why =
                            "no assignment of its facts satisfies its own \
                             default state, so it has no starting situation";
                        }
                        :: !declines
                  | Some assign ->
                      let slots =
                        List.map
                          (fun (dm : Mgtt_domains.domain) ->
                            let m =
                              match
                                List.assoc_opt dm.Mgtt_domains.dfact assign
                              with
                              | Some m -> m
                              | None -> List.hd dm.Mgtt_domains.members
                            in
                            "(" ^ Mgtt_guard.arrow_of_domain dm ^ " " ^ m ^ ")")
                          et.doms
                      in
                      buf_add b
                        ("  (" ^ et.ename ^ " "
                        ^ Mgtt_guard.writ_name c.cname
                        ^ " " ^ String.concat " " slots ^ ")\n")))))
    d.components;
  buf_add b ")\n\n";
  List.rev !declines

(* ---- the moves ----------------------------------------------------------- *)

(* Every component can fail on its own.

   Without this the model has no dynamics at all: propagation only RELAYS a
   failure from a dependency, so with nothing to originate one the initial
   situation is the only reachable situation and every question answers
   vacuously. mgtt gets its origin from outside — an injected fact in a
   scenario, a probe result at 3am — and its own scenario enumerator supplies
   it the same way, by picking each component in turn as the root cause.

   So each component gets one move per non-default state: from healthy into
   that state, guarded on being healthy now. Enumerating from there gives
   exactly the set of reachable failure configurations, which is the set mgtt
   enumerates as chains. *)
let emit_originations (b : Buffer.t) (d : doc) (ets : emitted_type list) :
    decline list =
  let declines = ref [] in
  buf_add b ";; ---- origination ----\n";
  buf_add b
    ";; one move per component per non-default state: the component fails on \
     its own.\n\
     ;; mgtt injects this from a scenario or a probe; here it has to be a \
     move, or\n\
     ;; nothing would ever leave the initial situation.\n\n";
  List.iter
    (fun (c : comp) ->
      match type_of_component ets c.cname with
      | None -> ()
      | Some et -> (
          match state_named et.source et.source.default_state with
          | None -> ()
          | Some active -> (
              match Mgtt_expr.parse active.swhen with
              | Error _ -> ()
              | Ok active_e ->
                  let subject = Mgtt_guard.writ_name c.cname in
                  List.iter
                    (fun (s : Mgtt_ast.state) ->
                      if s.sname <> et.source.default_state then
                        let name =
                          subject ^ "-fails-" ^ Mgtt_guard.writ_name s.sname
                        in
                        match Mgtt_expr.parse s.swhen with
                        | Error m ->
                            declines :=
                              {
                                what = name;
                                why = "state guard not readable: " ^ m;
                              }
                              :: !declines
                        | Ok target_e -> (
                            match
                              ( Mgtt_guard.to_writ_opt et.doms ~subject active_e,
                                Mgtt_guard.witness et.doms target_e,
                                Mgtt_guard.witness et.doms active_e )
                            with
                            | Ok active_g, Some target_a, Some active_a ->
                                let changed =
                                  List.filter
                                    (fun (k, v) ->
                                      List.assoc_opt k active_a <> Some v)
                                    target_a
                                in
                                if changed = [] then
                                  declines :=
                                    {
                                      what = name;
                                      why =
                                        "state `" ^ s.sname
                                        ^ "` is realised by the same facts as \
                                           the default state";
                                    }
                                    :: !declines
                                else begin
                                  buf_add b
                                    (";; " ^ c.cname ^ " -> " ^ s.sname ^ "\n");
                                  buf_add b ("(transition " ^ name ^ "\n");
                                  buf_add b ("  (when " ^ active_g ^ ")\n");
                                  let effects =
                                    List.map
                                      (fun (k, v) ->
                                        let dm =
                                          List.find
                                            (fun (x : Mgtt_domains.domain) ->
                                              x.Mgtt_domains.dfact = k)
                                            et.doms
                                        in
                                        "(set " ^ subject ^ "."
                                        ^ Mgtt_guard.arrow_of_domain dm
                                        ^ " " ^ v ^ ")")
                                      changed
                                  in
                                  buf_add b
                                    ("  (do  " ^ String.concat " " effects
                                   ^ "))\n\n")
                                end
                            | Error m, _, _ ->
                                declines :=
                                  { what = name; why = m } :: !declines
                            | _, None, _ ->
                                declines :=
                                  {
                                    what = name;
                                    why =
                                      "no assignment of facts satisfies state `"
                                      ^ s.sname ^ "`";
                                  }
                                  :: !declines
                            | _, _, None -> ()))
                    et.source.states)))
    d.components;
  List.rev !declines

(* mgtt's propagation protocol, as transitions. A failing state of a dependency
   emits `can_cause` labels; a state of the dependent declaring any of them in
   `triggered_by` becomes reachable from it. One transition per matching
   triple, named so that a witness route reads as a failure chain. *)
let rec emit_transitions (b : Buffer.t) (d : doc) (ets : emitted_type list) :
    decline list =
  let declines = ref [] in
  let emitted = ref 0 in
  buf_add b ";; ---- propagation ----\n";
  buf_add b
    ";; from `failure_modes.<state>.can_cause` on a dependency, matched against\n\
     ;; `states.<state>.triggered_by` on the component that depends on it.\n\n";
  List.iter
    (fun (dependent : comp) ->
      match type_of_component ets dependent.cname with
      | None -> ()
      | Some det ->
          List.iter
            (fun (dep_name, _while_guard) ->
              match
                ( Mgtt_ast.component_of d dep_name,
                  type_of_component ets dep_name )
              with
              | Some dep, Some aet ->
                  List.iter
                    (fun (failing : Mgtt_ast.state) ->
                      let labels = Mgtt_ast.can_cause dep failing.sname in
                      if labels <> [] then
                        List.iter
                          (fun (target : Mgtt_ast.state) ->
                            if
                              List.exists
                                (fun l -> List.mem l target.striggered)
                                labels
                            then
                              emit_one_transition b declines emitted aet det dep
                                dependent failing target)
                          det.source.states)
                    aet.source.states
              | _ -> ())
            dependent.depends)
    d.components;
  (* A model with dependency edges but no propagation enumerates exactly one
     situation, and would then report no findings — the most misleading answer
     this bridge could give. mgtt's protocol needs BOTH halves: a dependency
     declaring `can_cause` and the dependent declaring `triggered_by` for one
     of those labels. Providers commonly ship the first and omit the second. *)
  let edges =
    List.fold_left
      (fun n (c : comp) -> n + List.length c.depends)
      0 d.components
  in
  if !emitted = 0 && edges > 0 then
    declines :=
      {
        what = string_of_int edges ^ " dependency edges";
        why =
          "no propagation: nothing pairs a dependency's \
           `failure_modes.<state>.can_cause` label with a \
           `states.<state>.triggered_by` on the component that depends on it, \
           so the model has no moves and enumerates one situation";
      }
      :: !declines;
  List.rev !declines

(* One propagation move: the dependency is failing, the dependent is still in
   its default active state, and the effect writes the dependent's facts to a
   representative assignment of the triggered state — only the cells that
   actually change, so that `can be broken by` stays truthful about what each
   move touches. *)
and emit_one_transition b declines emitted (aet : emitted_type)
    (det : emitted_type) (dep : comp) (dependent : comp)
    (failing : Mgtt_ast.state) (target : Mgtt_ast.state) =
  let name =
    Mgtt_guard.writ_name dep.cname
    ^ "-"
    ^ Mgtt_guard.writ_name failing.sname
    ^ "-triggers-"
    ^ Mgtt_guard.writ_name dependent.cname
    ^ "-"
    ^ Mgtt_guard.writ_name target.sname
  in
  let fail why = declines := { what = name; why } :: !declines in
  match
    ( Mgtt_expr.parse failing.swhen,
      Mgtt_expr.parse target.swhen,
      state_named det.source det.source.default_state )
  with
  | Ok fail_e, Ok target_e, Some active -> (
      match Mgtt_expr.parse active.swhen with
      | Error m -> fail ("default state guard not readable: " ^ m)
      | Ok active_e -> (
          match
            ( Mgtt_guard.to_writ_opt aet.doms
                ~subject:(Mgtt_guard.writ_name dep.cname)
                fail_e,
              Mgtt_guard.to_writ_opt det.doms
                ~subject:(Mgtt_guard.writ_name dependent.cname)
                active_e,
              Mgtt_guard.witness det.doms target_e,
              Mgtt_guard.witness det.doms active_e )
          with
          | Ok fail_g, Ok active_g, Some target_a, Some active_a ->
              let changed =
                List.filter
                  (fun (k, v) -> List.assoc_opt k active_a <> Some v)
                  target_a
              in
              if changed = [] then
                fail
                  ("state `" ^ target.sname
                 ^ "` is realised by the same facts as the default state, so \
                    the move would change nothing")
              else begin
                buf_add b
                  (";; " ^ dep.cname ^ "." ^ failing.sname ^ " -> "
                 ^ dependent.cname ^ "." ^ target.sname ^ "\n");
                buf_add b ("(transition " ^ name ^ "\n");
                buf_add b ("  (when (and " ^ fail_g ^ " " ^ active_g ^ "))\n");
                let effects =
                  List.map
                    (fun (k, v) ->
                      let dm =
                        List.find
                          (fun (x : Mgtt_domains.domain) ->
                            x.Mgtt_domains.dfact = k)
                          det.doms
                      in
                      "(set "
                      ^ Mgtt_guard.writ_name dependent.cname
                      ^ "."
                      ^ Mgtt_guard.arrow_of_domain dm
                      ^ " " ^ v ^ ")")
                    changed
                in
                buf_add b ("  (do  " ^ String.concat " " effects ^ "))\n\n");
                incr emitted
              end
          | Error m, _, _, _ | _, Error m, _, _ -> fail m
          | _, _, None, _ ->
              fail
                ("no assignment of facts satisfies state `" ^ target.sname
               ^ "`, so nothing can trigger it")
          | _, _, _, None ->
              fail
                ("no assignment of facts satisfies the default state `"
               ^ det.source.default_state ^ "`")))
  | Error m, _, _ | _, Error m, _ -> fail ("state guard not readable: " ^ m)
  | _, _, None ->
      fail
        ("default_active_state `" ^ det.source.default_state
       ^ "` is not a declared state")

(* ---- the file ------------------------------------------------------------ *)

let file ~(name : string) (d : doc) : string * decline list =
  let b = Buffer.create 4096 in
  let schema = Mgtt_guard.writ_name (if d.name = "" then name else d.name) in
  let ets, plan_declines = plan_types d in

  buf_add b
    (";; Generated by `writ mgtt` from the mgtt model `" ^ d.name
   ^ "`.\n\
      ;;\n\
      ;; Facts are the cells that vary; a component's states and its `healthy:`\n\
      ;; block are both predicates over them, so their agreement is a law here\n\
      ;; rather than an assumption. Edit freely — this file is yours now.\n\
      ;;\n\
      ;; KERNEL-ONLY, as `writ sql` emits: nothing is loaded, nothing from the\n\
      ;; standard library. `iff` below is declared here, in the 26 words.\n\n");
  emit_forms b;

  (* The schema is built in its own buffer so that closing it is a matter of
     appending a paren rather than of trimming whatever the last block left
     behind. *)
  let sb = Buffer.create 2048 in
  emit_domains sb ets;
  emit_types sb ets;
  let eq_declines = emit_equations sb ets in
  buf_add b ("(schema " ^ schema ^ "\n");
  buf_add b (String.trim (Buffer.contents sb));
  buf_add b ")\n\n";

  let inst_declines = emit_instance b d ets in
  buf_add b ("(use " ^ schema ^ ")\n(initial start)\n\n");
  let or_declines = emit_originations b d ets in
  let tr_declines = emit_transitions b d ets in

  ( Buffer.contents b,
    d.declines @ plan_declines @ eq_declines @ inst_declines @ or_declines
    @ tr_declines )
