# Testing

Two suites, and the split is forced by an oracle problem rather than chosen for
tidiness.

## `dune runtest` — 72 unit checks

Everything decidable from the translation alone: reading the export document,
reducing facts to finite domains, and the shape of the emitted text. No
filesystem, no binaries, no writ.

```sh
dune runtest        # test_mgtt2writ: 72 passed
```

Among them is a **pinned real export** at `test/fixtures/mgtt-export-v1.json`,
produced by an actual `mgtt model export --json`. The version field already
refuses a document this tool does not know; what it cannot catch is mgtt
changing what a field *means* while shape and version stay put. Reading a real
document end to end turns that drift into a failure here rather than in a
user's terminal. Refresh it deliberately, from a real run, when the schema
version changes.

## `test/pipeline.sh` — 3 end-to-end checks

This tool emits **text**. Asserting on text passes just as happily when the
text is confidently wrong: `contains "(schema "` proves nothing about whether a
model came out. The only sound check is to hand the output to a parser and see
whether it is accepted.

The unit suite cannot do that. It vendors writ's JSON reader and nothing else,
and vendoring writ's *parser* to test against would mean testing against a copy
that ages out of step with the writ anyone actually runs — an oracle that keeps
passing as it stops meaning anything.

So that check runs the real binaries:

```sh
sh test/pipeline.sh                     # uses `mgtt2writ` and `writ` from PATH
MGTT2WRIT=./_build/default/bin/main.exe WRIT=../writ/writ/_build/default/tooling/cli/writ.exe \
  sh test/pipeline.sh                   # or point it at builds
```

It takes the pinned export as input, so it needs no mgtt checkout — only writ
and this tool. Exit `0` passed, `1` a check failed, `77` skipped because writ
is not installed.

This is a strictly stronger oracle than the linked-parser version it replaces:
a vendored parser proves *some* parser accepts the output, the real binary
proves *the writ you have* accepts it, which is the claim a user cares about.

## Both, before a release

```sh
dune runtest && sh test/pipeline.sh
```

A green pipeline script means little unless it can go red. Check that it does:

```sh
MGTT2WRIT=/bin/true sh test/pipeline.sh   # a translator emitting nothing
# → pipeline: FAIL — real writ rejected the emitted model
```
