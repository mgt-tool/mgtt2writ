# mgtt2writ

**Translate an mgtt architecture model into a writ model, and check it by
exhaustion.**

[mgtt](https://github.com/mgt-tool/mgtt) describes a system: its components,
what each depends on, and what "healthy" means for each of them.
[writ](https://github.com/writ-lang/writ) enumerates every reachable situation
of a finite model and answers by exhaustion, with a route as evidence.

This is the only thing that knows both. mgtt names writ nowhere; writ names
mgtt nowhere.

```console
$ mgtt model export --json | mgtt2writ | writ check --stdin
states: 64   edges: 268
gaps: none
dead ends: 9
equation datastore-store-health-matches-state
  can be broken by: store-fails-stopped   (acknowledge in claims)
  violated in 32 reachable situations   witness: 1. store-fails-stopped
$ echo $?
1
```

That finding is what the pipeline is for. The model's `store` says it is
healthy when `connection_count < 500`, while its type derives its state from
`available` — two definitions of the same thing, and nothing keeping them
consistent. Half the reachable configurations of that system disagree with
themselves about whether the component is healthy, and one failure reaches the
nearest. It is a property of the model rather than a wrong answer to any one
scenario, which is why testing scenarios does not find it.

Or in one command:

```console
$ mgtt-contradict-check
```

Same pipeline, same exit status. The wrapper ships here because three commands
and a pipe is more friction than a model author should carry on every run.

## Install

```sh
make install          # -> ~/.local/bin  (needs OCaml + dune, no opam)
make install PREFIX=/usr/local
opam install .        # or through opam
```

OCaml ≥ 4.14 and dune ≥ 3.0 to build, and **nothing else** — writ's JSON reader
is vendored under `vendor/` rather than depended on, so a writ release cannot
break this tool without someone choosing to sync.

You also need `mgtt` and `writ` on `PATH` to run the pipeline; this tool is the
middle of it.

## What it does

Reads the versioned JSON that `mgtt model export --json` writes, and emits a
kernel-only writ model on stdout. Declines go to stderr, always — a model
translated in silence would let "writ found nothing" be a claim about an
architecture nobody has.

It is a **filter**: stdin to stdout, no path argument. A filter that could also
read a file could be invoked a second way nobody documented.

| | |
|---|---|
| `mgtt2writ` | translate stdin to stdout |
| `mgtt2writ --strict` | exit 1 if anything was declined (the shape a CI check wants) |
| `mgtt2writ --version` | the version this binary was built from |

Exit status: **0** translated · **1** a decline under `--strict` · **2**
unreadable input.

## Why it is a separate tool

Neither project should carry a command naming the other. mgtt is not a writ
front end and writ is not an mgtt checker; an adapter between two systems
belongs to neither, which is the same reasoning that makes mgtt's providers
external plugins.

The full argument is
[ADR 0001](https://github.com/mgt-tool/mgtt/blob/main/docs/decisions/0001-where-the-writ-bridge-lives.md)
in mgtt's tree.

## How the translation works

The load-bearing claim is that facts stop being numbers **without loss**.
mgtt's expression language has six comparison operators and no arithmetic, so
the constants a model mentions cut each fact's values into finitely many
regions on which every predicate is constant. A region becomes a member of an
enumerated type, and two values in one region were already indistinguishable to
mgtt's own engine.

[`docs/reading.md`](docs/reading.md) works the whole mapping through — why the
reduction is lossless, why facts are the only varying cells, why an overriding
component gets its own type, why origination moves cannot be omitted, and what
is declined.

## Testing

Two suites, and the split is forced rather than chosen —
[`docs/testing.md`](docs/testing.md) explains why:

```sh
make test        # 72 unit checks; no writ needed
make pipeline    # 3 end-to-end checks against the real binaries
make check       # both
```

## License

Copyright (C) 2026 Alex Kunich. **GNU Affero General Public License, version 3
or later** ([LICENSE](LICENSE)) — the same terms writ ships under, since this
began as code in its tree. A model this tool emits is your own work; see
[NOTICE](NOTICE).
