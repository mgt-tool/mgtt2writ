(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* mgtt2writ — an mgtt model export, read as a writ model.

   A FILTER, and only a filter: stdin to stdout, no path argument. The pipeline
   it lives in is `mgtt model export --json | mgtt2writ | writ check --stdin`,
   each command naming its own step, and a filter that cannot also read a file
   cannot be invoked in a second way nobody documented.

   ONE direction. An mgtt model is a description of a system; writing one BACK
   from a writ model would be synthesis rather than a reading, and a different
   tool. The door is left open; this binary is not.

   The input is JSON rather than YAML, and that is the seam's whole design.
   Everything here is OCaml stdlib only, so a YAML parser would be a serious
   thing to hand-write and keep correct; mgtt already parses its own model and
   can hand over the RESOLVED one — provider types merged, overrides applied —
   which is both easier to read and the only form that does not require this
   side to understand mgtt's provider registry, install layout or credentials.

   What the export says and the model cannot hold goes to STDERR, always, and
   mgtt's own declines are forwarded rather than dropped: a model imported in
   silence would let "writ found nothing" be a claim about an architecture
   nobody has.

   Exit status: 0 answered, 2 unreadable. A decline is NOT a finding by default
   — a large model usually has some — so it costs 1 only under --strict, the
   shape a CI check wants. *)

open Mgtt2writ

let die code msg =
  prerr_endline ("mgtt2writ: " ^ msg);
  exit code

(* Read to EOF rather than [in_channel_length], which asks the OS for a file
   size and fails on a pipe — and a pipe is the only way this program is meant
   to be run. *)
let read_stdin () : string =
  let buf = Buffer.create 65536 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    let n = input stdin chunk 0 65536 in
    if n > 0 then (
      Buffer.add_subbytes buf chunk 0 n;
      loop ())
  in
  (try loop () with End_of_file -> ());
  Buffer.contents buf

(* Declines sharing a reason are one line, with a count and the first subject,
   so that forty components resolving to the generic fallback do not bury the
   one decline that mattered. The count is kept: nothing is hidden, only
   repeated. *)
let report_declines (ds : Mgtt_ast.decline list) =
  let rec group acc = function
    | [] -> List.rev acc
    | (d : Mgtt_ast.decline) :: rest ->
        let same, other =
          List.partition (fun (x : Mgtt_ast.decline) -> x.why = d.why) rest
        in
        group ((d, 1 + List.length same) :: acc) other
  in
  match ds with
  | [] -> ()
  | _ ->
      prerr_endline "declined:";
      List.iter
        (fun ((d : Mgtt_ast.decline), n) ->
          prerr_endline
            ("  " ^ d.why
            ^ (if n > 1 then "  (" ^ string_of_int n ^ " occurrences)" else "")
            ^ "\n      first at: " ^ d.what))
        (group [] ds)

let usage =
  "usage:\n\
  \  mgtt model export --json | mgtt2writ [--strict] | writ check --stdin\n\n\
   Reads an mgtt model export (JSON, on stdin) and writes a writ model on\n\
   stdout. Declines go to stderr.\n\n\
   options:\n\
  \  --strict      a decline costs exit 1 (the shape a CI check wants)\n\
  \  --version     print the version and exit\n\
  \  --help        print this and exit\n\n\
   exit status:\n\
  \  0  translated\n\
  \  1  translated, but something declined, under --strict\n\
  \  2  the export could not be read"

let version () =
  print_endline ("mgtt2writ " ^ Version.v);
  print_endline "Copyright (C) 2026 Alex Kunich.  License AGPL-3.0-or-later.";
  exit 0

let run ~(strict : bool) =
  let src = read_stdin () in
  let j =
    match Json_parse.parse src with
    | Ok j -> j
    | Error e -> die 2 ("stdin: " ^ e)
  in
  let doc =
    match Mgtt_read.of_json j with Ok d -> d | Error e -> die 2 ("stdin: " ^ e)
  in
  (* The model's name comes from the export, not from a filename: it is the
     name mgtt itself gave the model, and a filter has no filename to fall
     back on. *)
  let text, ds = Emit_mgtt.file ~name:doc.Mgtt_ast.name doc in
  print_string text;
  flush stdout;
  report_declines ds;
  exit (if strict && ds <> [] then 1 else 0)

let () =
  match Array.to_list Sys.argv with
  | [ _ ] -> run ~strict:false
  | [ _; "--strict" ] -> run ~strict:true
  | [ _; ("-h" | "--help") ] ->
      print_endline usage;
      exit 0
  | [ _; ("-V" | "-v" | "--version") ] -> version ()
  | _ -> die 2 usage
