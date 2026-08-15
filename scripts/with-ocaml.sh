#!/usr/bin/env bash
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
# Run a command with an OCaml toolchain on PATH.
#
#   tools/with-ocaml.sh dune build
#
# Resolution order, first that yields a working `dune` wins:
#   1. dune already on PATH          — a normal opam setup, nothing to do
#   2. $SWITCH                       — set it to force a particular switch
#   3. ./_opam                       — a switch local to this checkout
#   4. the global `writ` switch       — the central switch writ uses; shared here on purpose;
#                                      also what the VS Code OCaml extension finds
#   5. ../tryocaml, and the absolute path to it
#                                    — the sibling switch this repo was first
#                                      developed against, kept as a fallback
#
# Exists because the Makefile and editor/vscode/install.sh both need it, and a
# hardcoded switch path in the Makefile only ever worked on one machine.
set -euo pipefail

if ! command -v dune >/dev/null 2>&1; then
  for switch in "${SWITCH:-}" ./_opam writ mgtt2writ; do
    # A path switch must exist as a dir; a named switch (e.g. `writ`) has no path,
    # so let opam env be the arbiter — it fails silently for an unknown switch.
    [ -n "$switch" ] || continue
    case "$switch" in */*|.*) [ -d "$switch" ] || continue ;; esac
    eval "$(opam env --switch="$switch" --set-switch 2>/dev/null)" || continue
    command -v dune >/dev/null 2>&1 && break
  done
fi

if ! command -v dune >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: no OCaml toolchain found — this project needs `dune`.

Either put dune on your PATH, or create a switch in this checkout:

    opam switch create . --deps-only    # or: opam switch create . 5.2.0
    opam install dune ocamlformat

If you already have a switch elsewhere, point at it:

    SWITCH=/path/to/switch make build
EOF
  exit 1
fi

exec "$@"
