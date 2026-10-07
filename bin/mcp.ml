(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* `mgtt2writ mcp`: the translation as an MCP tool over stdio, so an agent
   with no shell can compose the three tools the way a shell pipes them:

     mgtt's model_export  ->  mgtt_to_writ  ->  writ's writ_check

   writ's tools read a model from a path, so the tool writes the model (and,
   asked, its diagnosability rules) to files and answers with their paths.
   Like the command line, it knows mgtt's export and writ's syntax and
   nothing else: neither of the other two servers learns about it. *)

open Mgtt2writ

let instructions =
  "mgtt2writ translates an mgtt model, as mgtt's model_export returns it, into \
   a writ model. Call mgtt_to_writ with the export document, then hand the \
   model_path it returns to writ_check (and rules_path to writ_derive with the \
   relation unattributable). Declines name what the translation could not \
   carry; read them before trusting a clean check."

let str s = Json.String s
let obj kvs = Json.Assoc kvs

let tool_schema =
  obj
    [
      ("name", str "mgtt_to_writ");
      ( "description",
        str
          "Translate an mgtt model export (the JSON document mgtt's \
           model_export returns) into a writ model, written to a file. Returns \
           model_path for writ_check, rules_path for writ_derive when rules is \
           true, and the declines: what the translation could not carry." );
      ( "inputSchema",
        obj
          [
            ("type", str "object");
            ( "properties",
              obj
                [
                  ( "export",
                    obj
                      [
                        ("type", Json.List [ str "object"; str "string" ]);
                        ( "description",
                          str
                            "the export document itself, as model_export \
                             returns it or as JSON text" );
                      ] );
                  ( "export_path",
                    obj
                      [
                        ("type", str "string");
                        ("description", str "a file holding the export document");
                      ] );
                  ( "out_dir",
                    obj
                      [
                        ("type", str "string");
                        ( "description",
                          str
                            "where to write the files; a temporary directory \
                             by default" );
                      ] );
                  ( "rules",
                    obj
                      [
                        ("type", str "boolean");
                        ( "description",
                          str "also write the diagnosability rules" );
                      ] );
                ] );
          ] );
    ]

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path text =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc text)

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end

(* A file-name-safe form of the model's name. *)
let safe name =
  let s =
    String.map
      (fun c ->
        match c with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> c
        | _ -> '-')
      name
  in
  if s = "" then "model" else s

let translate args : (Json.t, string) result =
  let field k = Json.member k args in
  let parse src =
    Result.map_error (fun e -> "export: " ^ e) (Json_parse.parse src)
  in
  (* The document as model_export returns it, as text, or in a file. *)
  let document =
    match (field "export", field "export_path") with
    | Some (Json.Assoc _ as j), None -> Ok j
    | Some (Json.String s), None -> parse s
    | None, Some (Json.String p) -> (
        try parse (read_file p) with Sys_error e -> Error e)
    | Some _, Some _ -> Error "give export or export_path, not both"
    | _ -> Error "export or export_path is required"
  in
  match document with
  | Error e -> Error e
  | Ok j -> (
      match Mgtt_read.of_json j with
      | Error e -> Error ("export: " ^ e)
      | Ok doc -> (
          let dir =
            match field "out_dir" with
            | Some (Json.String d) -> d
            | _ ->
                Filename.concat
                  (Filename.get_temp_dir_name ())
                  ("mgtt2writ-" ^ safe doc.Mgtt_ast.name)
          in
          let base = Filename.concat dir (safe doc.Mgtt_ast.name) in
          let text, declines = Emit_mgtt.file ~name:doc.Mgtt_ast.name doc in
          try
            mkdir_p dir;
            write_file (base ^ ".writ") text;
            let rules =
              match field "rules" with
              | Some (Json.Bool true) ->
                  write_file (base ^ ".rules")
                    (Emit_rules.file ~name:doc.Mgtt_ast.name doc);
                  [ ("rules_path", str (base ^ ".rules")) ]
              | _ -> []
            in
            Ok
              (obj
                 ([ ("model_path", str (base ^ ".writ")) ]
                 @ rules
                 @ [
                     ( "declines",
                       Json.List
                         (List.map
                            (fun (d : Mgtt_ast.decline) ->
                              obj
                                [
                                  ("what", str d.Mgtt_ast.what);
                                  ("why", str d.Mgtt_ast.why);
                                ])
                            declines) );
                   ]))
          with Sys_error e -> Error e))

let reply id result =
  Json.to_string
    (obj [ ("jsonrpc", str "2.0"); ("id", id); ("result", result) ])

let error id code msg =
  Json.to_string
    (obj
       [
         ("jsonrpc", str "2.0");
         ("id", id);
         ("error", obj [ ("code", Json.Int code); ("message", str msg) ]);
       ])

let tool_result ~is_error text =
  obj
    [
      ("content", Json.List [ obj [ ("type", str "text"); ("text", str text) ] ]);
      ("isError", Json.Bool is_error);
    ]

(* One message in, at most one line out. *)
let handle (msg : Json.t) : string option =
  let id = Json.member "id" msg in
  let params = Option.value ~default:(obj []) (Json.member "params" msg) in
  match (Json.member "method" msg, id) with
  | Some (Json.String "initialize"), Some id ->
      let version =
        match Json.member "protocolVersion" params with
        | Some (Json.String v) -> v
        | _ -> "2025-06-18"
      in
      Some
        (reply id
           (obj
              [
                ("protocolVersion", str version);
                ("capabilities", obj [ ("tools", obj []) ]);
                ( "serverInfo",
                  obj [ ("name", str "mgtt2writ"); ("version", str Version.v) ]
                );
                ("instructions", str instructions);
              ]))
  | Some (Json.String "ping"), Some id -> Some (reply id (obj []))
  | Some (Json.String "tools/list"), Some id ->
      Some (reply id (obj [ ("tools", Json.List [ tool_schema ]) ]))
  | Some (Json.String "tools/call"), Some id -> (
      match Json.member "name" params with
      | Some (Json.String "mgtt_to_writ") -> (
          let args =
            Option.value ~default:(obj []) (Json.member "arguments" params)
          in
          match translate args with
          | Ok r ->
              Some (reply id (tool_result ~is_error:false (Json.to_string r)))
          | Error e -> Some (reply id (tool_result ~is_error:true e)))
      | _ -> Some (error id (-32602) "unknown tool"))
  | Some (Json.String _), Some id -> Some (error id (-32601) "method not found")
  | _ -> None (* a notification: nothing to answer *)

let serve () =
  let rec loop () =
    match input_line stdin with
    | exception End_of_file -> ()
    | "" -> loop ()
    | line ->
        (match Json_parse.parse line with
        | Error e ->
            print_endline (error Json.Null (-32700) ("parse error: " ^ e))
        | Ok msg -> (
            match handle msg with Some out -> print_endline out | None -> ()));
        flush stdout;
        loop ()
  in
  loop ()
