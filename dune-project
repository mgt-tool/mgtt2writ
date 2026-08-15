(lang dune 3.0)

; mgtt2writ translates an mgtt model export into a writ model. It is a real
; opam package so `opam install .` puts the binary on PATH as `mgtt2writ`.
;
; OCaml stdlib only, exactly as writ is: the JSON reader is vendored under
; vendor/ rather than depended on, so this tool stands alone and a writ
; release cannot break it without someone choosing to sync.

(name mgtt2writ)

(version 0.1.0)

(generate_opam_files true)

(authors "Alex Kunich")

(maintainers "alex.kunich@gmail.com")

(license AGPL-3.0-or-later)

(source
 (github mgt-tool/mgtt2writ))

(homepage "https://github.com/mgt-tool/mgtt2writ")

(bug_reports "https://github.com/mgt-tool/mgtt2writ/issues")

(package
 (name mgtt2writ)
 ; Nothing is attached to the package yet — the executable arrives with
 ; bin/dune — and dune refuses to build an install file for an empty package
 ; without being told it is deliberate. Removed once bin/ exists.
 (allow_empty)
 (synopsis
  "Translate an mgtt architecture model into a writ model, for checking by exhaustion")
 (description
  "Reads the versioned JSON that `mgtt model export --json` emits and writes a Writ model on stdout. mgtt describes a system's components, their dependencies, and what healthy means for each; Writ enumerates every reachable failure configuration and answers by exhaustion. This tool is the only thing that knows both formats — mgtt names Writ nowhere, and Writ names mgtt nowhere. OCaml stdlib only; the JSON reader is vendored.")
 (depends
  (ocaml
   (>= 4.14))
  (dune
   (>= 3.0))))
