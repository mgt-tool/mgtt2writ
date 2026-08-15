#!/bin/sh
# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The end-to-end check: a real mgtt export, through this translator, into the
# real writ.
#
# It exists because of an oracle problem the unit suite cannot solve. This tool
# emits TEXT, and asserting on text passes just as happily when the text is
# confidently wrong — `contains "(schema "` proves nothing about whether a
# model came out. The only sound check is to hand the output to a parser and
# see whether it is accepted.
#
# The unit suite cannot do that. It vendors writ's JSON reader and nothing
# else, and vendoring writ's PARSER to test against would mean testing against
# a copy that ages out of step with the writ anyone actually runs — an oracle
# that keeps passing as it stops meaning anything. So the check moved here,
# where it can use the real binary, and it is stronger for the move: a vendored
# parser proves "some parser accepts this", the real one proves "the writ you
# have accepts this", which is the claim a user cares about.
#
# Input is the pinned export under fixtures/, so this needs no mgtt checkout —
# only writ and this tool.
#
# Exit: 0 all checks passed, 1 a check failed, 77 skipped (writ not installed).

set -eu

here=$(dirname "$0")
fixture="$here/fixtures/mgtt-export-v1.json"
m2w=${MGTT2WRIT:-mgtt2writ}
writ=${WRIT:-writ}

if ! command -v "$writ" >/dev/null 2>&1; then
  echo "pipeline: SKIP — $writ not on PATH (set WRIT= to point at one)"
  exit 77
fi
if ! command -v "$m2w" >/dev/null 2>&1 && [ ! -x "$m2w" ]; then
  echo "pipeline: SKIP — $m2w not found (set MGTT2WRIT= to point at one)"
  exit 77
fi

tmp_rules=$(mktemp)
tmp_model=$(mktemp)
trap 'rm -f "$tmp_rules" "$tmp_model"' EXIT

fail() {
  echo "pipeline: FAIL — $1"
  exit 1
}

# ---- the re-homed check: does the output parse as a model? ------------------
#
# `writ check` reads, expands and parses before it enumerates, so a zero exit
# here is the whole front end accepting the text. This is what
# `test_emit_is_a_model` asserted against a linked parser.

out=$("$m2w" < "$fixture" | "$writ" check --stdin 2>&1) || {
  echo "$out"
  fail "real writ rejected the emitted model"
}

echo "$out" | grep -q '^states:' ||
  fail "writ produced no size line; got: $out"

# It must be a model with content — a translator that emitted an empty schema
# would parse cleanly and mean nothing.
states=$(echo "$out" | sed -n 's/^states: *\([0-9]*\).*/\1/p')
[ -n "$states" ] && [ "$states" -gt 1 ] ||
  fail "expected more than one reachable situation, got '$states'"

# ---- and the translation declined nothing on a known-good export ------------

declines=$("$m2w" < "$fixture" 2>&1 >/dev/null) || true
[ -z "$declines" ] || fail "the pinned export should decline nothing; got: $declines"

# ---- the diagnosability rules run against the same model --------------------
#
# `writ derive` answering at all is the check: rules naming a move the model
# does not have would derive nothing and read as an all-clear, so an empty
# answer here is indistinguishable from a broken rules file. The unit suite
# asserts the names line up; this asserts the pair actually runs together.

"$m2w" --rules < "$fixture" > "$tmp_rules" 2>/dev/null ||
  fail "could not generate the diagnosability rules"

grep -q "(relation unattributable 1)" "$tmp_rules" ||
  fail "the generated rules declare no unattributable relation"

"$m2w" < "$fixture" > "$tmp_model" 2>/dev/null
"$writ" derive "$tmp_model" "$tmp_rules" unattributable >/dev/null 2>&1 ||
  fail "real writ could not answer the generated rules"

echo "pipeline: 4 checks passed (real $writ, $states situations)"
