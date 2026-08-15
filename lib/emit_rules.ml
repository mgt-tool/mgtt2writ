(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* [Mgtt_ast.doc] -> a .rules file asking which failures cannot be told apart.

   THE QUESTION. mgtt's `diagnose` looks at a failing system and names the
   component responsible. Sometimes it cannot be right, and not because the
   engine is weak: the system is in a configuration that TWO different failure
   stories both produce, and no probe distinguishes them because the facts are
   identical either way.

   Take a store and an api in front of it. The api is unreachable and the store
   is saturated. Two histories end exactly there:

     - the store saturated, and took the api down with it — ONE root cause;
     - the api failed on its own, and the store saturated separately — TWO.

   Every fact reads the same. `diagnose` must pick one, and Occam picks the
   single cause, so it is wrong every time the second story is what happened.
   This is not a bug to fix in the engine — it is a property of the MODEL, and
   the only honest response is to know about it in advance.

   WHAT THIS EMITS. One relation per component, over the model's own move
   names: was this situation reached after the component failed by itself, and
   was it also reached after a dependency pushed it over? Where both hold, the
   component's failure is unattributable in that situation.

     writ derive MODEL.writ MODEL.rules unattributable

   WHY IT IS GENERATED, NOT SHIPPED. The rules name concrete moves —
   `store-saturated-triggers-api-down` — which exist only in the model this
   tool just emitted. A shipped rules file could not know them. And it is the
   same reason the naming lives in [Mgtt_guard] rather than here: rules that
   name a move the model does not have match nothing, derive nothing, and
   report NO AMBIGUITY. A false all-clear is the worst answer this tool could
   give, so the two spellings come from one function. *)

open Mgtt_ast

let buf_add = Buffer.add_string

(* A component can only be pushed over by something it depends on, so the
   question is only interesting where BOTH stories exist: the component has at
   least one non-default state it can fail into on its own, and at least one
   move by which a dependency puts it into one. A leaf nothing depends on, or a
   component with no propagation into it, is never ambiguous — its failures are
   always its own — and emitting empty relations for it would suggest the tool
   had looked and found nothing rather than that there was nothing to look
   for. *)
type component_moves = {
  cm_name : string;  (** the writ-spelled component name *)
  cm_self : string list;  (** its own origination moves *)
  cm_dep : string list;  (** moves by which a dependency pushes it over *)
}

let state_named (ty : ty) (name : string) : state option =
  List.find_opt (fun (s : state) -> s.sname = name) ty.states

(* Rebuilds exactly what the emitter emitted, from the same document and the
   same naming functions. Anything the emitter declined is absent here too,
   because the conditions are the same ones. *)
let moves_of (d : doc) (c : comp) : component_moves option =
  match Mgtt_ast.type_of d c.ctype with
  | None -> None
  | Some ty ->
      let self =
        List.filter_map
          (fun (s : state) ->
            if s.sname = ty.default_state then None
            else
              Some
                (Mgtt_guard.origination_move ~component:c.cname ~state:s.sname))
          ty.states
      in
      let dep =
        List.concat_map
          (fun (dep_name, _while_guard) ->
            match
              (Mgtt_ast.component_of d dep_name, Mgtt_ast.type_of d c.ctype)
            with
            | Some dep_c, Some _ -> (
                match Mgtt_ast.type_of d dep_c.ctype with
                | None -> []
                | Some dep_ty ->
                    List.concat_map
                      (fun (failing : state) ->
                        let labels = Mgtt_ast.can_cause dep_c failing.sname in
                        if labels = [] then []
                        else
                          List.filter_map
                            (fun (target : state) ->
                              if
                                List.exists
                                  (fun l -> List.mem l target.striggered)
                                  labels
                              then
                                Some
                                  (Mgtt_guard.propagation_move ~dep:dep_c.cname
                                     ~dep_state:failing.sname ~component:c.cname
                                     ~state:target.sname)
                              else None)
                            ty.states)
                      dep_ty.states)
            | _ -> [])
          c.depends
      in
      let dedup = List.sort_uniq compare in
      if self = [] || dep = [] then None
      else
        Some
          {
            cm_name = Mgtt_guard.writ_name c.cname;
            cm_self = dedup self;
            cm_dep = dedup dep;
          }

(* "Reached after E fired" — a one-pass walk forward from every edge named E,
   which is what makes the question linear rather than a closure over pairs.
   The second rule carries the mark onward through any later move: once a
   component has failed by itself, every situation downstream of that is still
   downstream of it. *)
let emit_reached (b : Buffer.t) ~(rel : string) ~(moves : string list) =
  buf_add b ("(relation " ^ rel ^ " 1)\n");
  List.iter
    (fun m -> buf_add b ("(rule (" ^ rel ^ " S) (edge " ^ m ^ " T S))\n"))
    moves;
  buf_add b ("(rule (" ^ rel ^ " S) (" ^ rel ^ " T) (edge E T S))\n\n")

let file ~(name : string) (d : doc) : string =
  let b = Buffer.create 2048 in
  let per = List.filter_map (moves_of d) d.components in

  buf_add b
    (";; Diagnosability rules for the mgtt model `"
    ^ (if d.name = "" then name else d.name)
    ^ "`, generated by mgtt2writ.\n\
       ;;\n\
       ;; Ask them of the model this tool emitted from the same export:\n\
       ;;\n\
       ;;   writ derive MODEL.writ THIS.rules unattributable\n\
       ;;\n\
       ;; A situation listed there is one your probes cannot explain. Two\n\
       ;; different failure stories both produce it, every fact reads the same\n\
       ;; in each, and so `mgtt diagnose` must guess which happened.\n\
       ;;\n\
       ;; This is a property of the MODEL, not a defect in any engine. The fix\n\
       ;; is a fact that tells the two stories apart — one a probe can read.\n\n"
    );

  if per = [] then begin
    buf_add b
      ";; NOTHING TO ASK. No component of this model can be reached BOTH by\n\
       ;; failing on its own and by a dependency pushing it over, so no failure\n\
       ;; here is ambiguous in that way. A model whose types declare no\n\
       ;; `triggered_by` has no propagation at all and will always land here —\n\
       ;; which is worth checking before reading this as an all-clear.\n\n\
       (relation unattributable 1)\n";
    Buffer.contents b
  end
  else begin
    List.iter
      (fun cm ->
        buf_add b (";; ---- " ^ cm.cm_name ^ " ----\n");
        buf_add b ";; reached after it failed on its own:\n";
        emit_reached b ~rel:("self-failed-" ^ cm.cm_name) ~moves:cm.cm_self;
        buf_add b ";; reached after a dependency pushed it over:\n";
        emit_reached b ~rel:("dep-failed-" ^ cm.cm_name) ~moves:cm.cm_dep;
        buf_add b ";; both stories end here, and no fact separates them:\n";
        buf_add b ("(relation unattributable-" ^ cm.cm_name ^ " 1)\n");
        buf_add b
          ("(rule (unattributable-" ^ cm.cm_name ^ " S) (self-failed-"
         ^ cm.cm_name ^ " S) (dep-failed-" ^ cm.cm_name ^ " S))\n\n"))
      per;

    buf_add b ";; ---- any component ----\n";
    buf_add b "(relation unattributable 1)\n";
    List.iter
      (fun cm ->
        buf_add b
          ("(rule (unattributable S) (unattributable-" ^ cm.cm_name ^ " S))\n"))
      per;
    Buffer.contents b
  end

(* Every move name the rules mention. The emitter's own output must contain all
   of them; a test asserts it, because the failure it guards against is silent
   — rules naming a move that does not exist derive nothing and read as an
   all-clear. *)
let moves_named (d : doc) : string list =
  List.concat_map
    (fun cm -> cm.cm_self @ cm.cm_dep)
    (List.filter_map (moves_of d) d.components)
