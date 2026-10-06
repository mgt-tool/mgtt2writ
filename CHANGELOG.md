# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The model's word on a node.** Reads mgtt's state verdicts: a component's own `states:` (broken whatever the rules say) and `healthy_in:` (no failure whatever they say), and a type's `healthy_in` states. A component using them gets a type of its own; a healthy state originates and propagates nothing; and in the health law a state with a verdict counts on both sides, so a model using them verifies clean. `--rules` follows the same effective types.
- **Redundancy groups.** A dependency with `need: k` over n components is read
  as the group it is, not as n hard dependencies: a member's failure reaches
  the dependent only once at least n − k + 1 members are out of their default
  state, the line mgtt's own scenarios draw. Before, writ reported breakages the
  redundancy prevents. A group naming a member the model lacks, or needing more
  members than it has, is declined. Exports without `group`/`need` read as
  before.

- **`mgtt2writ --rules`** — generates diagnosability questions for the model it
  would otherwise emit. Answers *which failures cannot be told apart*: a
  situation reachable both by a component failing on its own and by a dependency
  pushing it over is one where every fact reads the same either way, so
  `mgtt diagnose` must guess. Ask it with
  `writ derive MODEL.writ MODEL.rules unattributable`, or per component with
  `unattributable-<component>`.

  A component nothing depends on gets no relation at all — its failures are
  always its own — and a model with no propagation says **NOTHING TO ASK**
  rather than answering empty, because an empty answer and a model whose types
  forgot `can_cause` look identical otherwise.

  The rules name concrete moves, so both they and the model are spelled by one
  pair of functions in `Mgtt_guard`. Rules naming a move the model lacks would
  match nothing, derive nothing, and report a false all-clear; a test asserts
  every named move exists in the emitted model, and it was verified to fail
  when a name is hand-written instead of shared.

### Changed

- **Propagation follows mgtt's own rule.** A failure state that lists no
  `triggered_by` labels answers to any `can_cause` label, as mgtt's scenarios
  have it; before, it answered to none, so a model on provider types that leave
  `triggered_by` out (the kubernetes and aws ones, for a start) relayed no
  failure across any edge. Neither side's default state takes part. The
  `--rules` move list follows the same rule, from one shared function. A
  `while:` guard is still read as mgtt's scenarios read it, as an edge that may
  be active; [docs/reading.md](docs/reading.md) says why.

### Fixed

- **`--rules` names only moves the model has.** It rebuilt the move list by
  matching labels alone, so a move the emitter declined (a state no assignment
  satisfies, and now a malformed redundancy group) was still named, and a rule
  naming a missing move derives nothing and reads as an all-clear. Candidates
  are now kept only if the emitted model has them.
- The *no propagation* decline no longer fires when labels do pair but each
  resulting move was declined for its own, stated reason; it blamed the labels.

## [0.1.0]

First release. The translation was extracted from
[writ](https://github.com/writ-lang/writ), where it shipped briefly as a
`writ mgtt` verb, and from
[mgtt](https://github.com/mgt-tool/mgtt), which briefly wrapped it as
`mgtt verify`. Neither project carries it now — see
[ADR 0001](https://github.com/mgt-tool/mgtt/blob/main/docs/decisions/0001-where-the-writ-bridge-lives.md).

### Added

- **`mgtt2writ`** — a filter reading the versioned JSON of
  `mgtt model export --json` and writing a kernel-only writ model on stdout.
  Declines are named on stderr; `--strict` makes one a finding. Exit 0/1/2.
- **`mgtt-contradict-check`** — a wrapper running the whole pipeline,
  `mgtt model export --json | mgtt2writ | writ check --stdin`, and returning
  writ's exit status unchanged.
- **The vendored JSON reader** (`vendor/json/`, ~311 lines from writ) rather
  than a dependency, so a writ release cannot break this tool without someone
  choosing to sync.
- **A pinned real export** at `test/fixtures/mgtt-export-v1.json`. The export's
  version field refuses a document this tool does not know; what it cannot
  catch is mgtt changing what a field *means* while shape and version stay put.
  Reading a real document end to end turns that drift into a test failure.

### Notes

- The test suite splits **72 unit checks + a 3-check pipeline script**, and the
  split is forced. Two checks read the emitted text back through writ's real
  reader, expander and parser — the strongest oracle here, since asserting on
  text passes just as happily when the text is confidently wrong. They link
  writ's front end, not the JSON reader this tool vendors, so they run against
  the real binary in `test/pipeline.sh` instead. That is strictly stronger: a
  vendored parser proves *some* parser accepts the output, the real one proves
  *the writ you have* does.
- The emitted model attributes itself to `mgtt2writ`. It previously carried
  `;; Generated by \`writ mgtt\``, naming a verb that no longer exists, from a
  tool whose whole point is that neither project names the other.
