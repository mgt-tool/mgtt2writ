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
# Input is the pinned exports under fixtures/, so this needs no mgtt checkout —
# only writ and this tool. GROUP_FIXTURE= swaps in a fresh export of
# fixtures/mgtt-export-group.yaml, which is how mgtt's downstream harness runs
# the group checks against the mgtt under test.
#
# Exit: 0 all checks passed, 1 a check failed, 77 skipped (writ not installed).

set -eu

here=$(dirname "$0")
fixture="$here/fixtures/mgtt-export-v1.json"
group_fixture=${GROUP_FIXTURE:-$here/fixtures/mgtt-export-group.json}
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
tmp_claims=$(mktemp)
trap 'rm -f "$tmp_rules" "$tmp_model" "$tmp_claims"' EXIT

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

# ---- a redundancy group holds while enough of its members do ---------------
#
# The second fixture is minishop with its store doubled: api needs one of
# store-a and store-b. Flattened into two hard dependencies, one store's
# failure could take api down; honoured, that move exists only once both are
# down. Moves are not something a property can name, so each situation is
# found by a holding `possible`, whose witness route ends at its index, and
# the moves out of it are read with `writ show`.

"$m2w" < "$group_fixture" > "$tmp_model" 2>/dev/null ||
  fail "could not translate the grouped export"

# situation GUARD: the index of a reachable situation satisfying GUARD with api
# still up.
situation() {
  printf '(property here "the situation asked for" (possible (and %s (is api.reachable yes))))\n' "$1" > "$tmp_claims"
  "$writ" check "$tmp_model" --claims "$tmp_claims" --no-certificate 2>&1 |
    sed -n 's/.*→ #\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

# moves_out N: the moves writ offers out of situation N.
moves_out() {
  "$writ" show "$tmp_model" --at "$1" 2>&1 | sed -n '/moves:/,$p'
}

one=$(situation "(is store-a.available no) (is store-b.available yes) (is store-b.connection-count below-500)")
[ -n "$one" ] || fail "no reachable situation with only store-a down"
if moves_out "$one" | grep -q store-a-stopped-triggers-api-down; then
  fail "store-a alone down takes api down: the group was read as hard dependencies"
fi

both=$(situation "(is store-a.available no) (is store-b.available no)")
[ -n "$both" ] || fail "no reachable situation with both stores down"
moves_out "$both" | grep -q store-a-stopped-triggers-api-down ||
  fail "both stores down cannot take api down: the group never breaks"

# ---- the model's word on a node: verdicts keep the law ----------------------
#
# A state that decides health whatever the rules say decides it on both sides
# of the health law, so a model using healthy_in and its own states still
# verifies clean.

verdicts_fixture="$here/fixtures/mgtt-export-verdicts.json"
"$m2w" < "$verdicts_fixture" > "$tmp_model" 2>/dev/null ||
  fail "could not translate the verdicts export"
out=$("$writ" check "$tmp_model" --no-certificate 2>&1) || {
  echo "$out"
  fail "a model with healthy_in and its own states should verify clean"
}

# ---- the same translation as an MCP tool -------------------------------------
#
# An agent without a shell composes mgtt's model_export, this tool's
# mgtt_to_writ and writ's writ_check. The tool writes the model to a file and
# answers with its path, since writ reads models from paths.

mcp_dir=$(mktemp -d)
trap 'rm -f "$tmp_rules" "$tmp_model" "$tmp_claims"; rm -rf "$mcp_dir"' EXIT
answer=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"mgtt_to_writ\",\"arguments\":{\"export_path\":\"$group_fixture\",\"out_dir\":\"$mcp_dir\"}}}" |
  "$m2w" mcp)
model_path=$(echo "$answer" | grep '"id":2' | sed -n 's/.*\\"model_path\\":\\"\([^\\]*\)\\".*/\1/p')
[ -n "$model_path" ] && [ -f "$model_path" ] ||
  fail "mgtt2writ mcp wrote no model; answered: $answer"
"$writ" check "$model_path" --no-certificate >/dev/null 2>&1 ||
  fail "real writ rejected the model mgtt2writ mcp wrote"

echo "pipeline: 8 checks passed (real $writ, $states situations)"
