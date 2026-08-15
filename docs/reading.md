# The reading — an architecture translated into a model

`mgtt2writ` reads a model written for
[mgtt](https://github.com/mgt-tool/mgtt) — a tool that makes a system's
architecture executable — and writes a [writ](https://github.com/writ-lang/writ)
model on stdout. It is a **reading**, in the sense `writ sql` is: the output is
kernel-only, a person owns it afterwards, and everything the input says that
the model cannot hold is named on stderr rather than dropped.

This document is the kitchen. It explains *why* the mapping is shaped the way
it is, which is the part a user does not need and a person changing it cannot
do without. The tool's own reference is `mgtt2writ --help`.

*(This file was `docs/mgtt-bridge.md` in writ's tree, when the translation
lived there as a `mgtt2writ` verb. It moved with the code — see
[ADR 0001](https://github.com/mgt-tool/mgtt/blob/main/docs/decisions/0001-where-the-writ-bridge-lives.md)
for why neither project carries it now.)*

## 1. Why this domain

An mgtt model names a system's components, the dependencies between them, what
each component's *facts* are, which *states* those facts put it in, and how a
failing state propagates to whatever depends on it.

That is [Appendix G](https://github.com/writ-lang/writ/blob/main/docs/kernel-spec.md#appendix-g--problems-tractable-with-writ)'s
"incident-response runbooks" with the furniture already assembled — down to the
question the appendix asks first: *from every reachable incident state, is
recovery still reachable?* The fit is not a coincidence to be pleased about but
a constraint to be checked, and §G states the terms: finitely many kinds of
piece, rules that read as "only if … then this changes", laws that read as "two
routes must agree", questions about reachability and silence. An mgtt model
meets all four, and the one place it appears not to — its facts are integers —
is §3.

What the domain supplies that writ's corpus lacks is a model **somebody already
wrote**. Authoring is the cost writ asks a new user to pay before it can say
anything at all; here it is already paid, by someone who paid it for their own
reasons.

## 2. The seam is JSON, and the input is the resolved model

`mgtt2writ` does not read mgtt's YAML. mgtt emits a resolved document —
`mgtt model export --json` — and this tool reads that.

Two reasons, and only the first is about effort. Writ is OCaml-stdlib-only by
policy; a YAML parser is a large thing to hand-write and a larger thing to keep
correct, while `tooling/json/` already exists because the LSP and MCP servers
needed it. The second reason is the one that would stand even if YAML were
free: *resolved* means mgtt has already merged each provider's type definitions
into the components using them and applied every component-level override. So
this side never implements mgtt's precedence rules, and cannot drift from them.
A bridge that re-decided whether a component's `healthy:` replaces or extends
its type's would be a second implementation of a rule that already exists.

The document carries mgtt's own declines too — a component whose type fell back
to mgtt's generic placeholder, say — and they are forwarded rather than
absorbed. Silence about what the *other* side could not do would be the same
failure as silence about what this side could not do.

## 3. The reduction — how facts stop being numbers

Writ has no numbers ([§2.4](https://github.com/writ-lang/writ/blob/main/docs/kernel-spec.md#24-the-language-stops-short-of-computation)),
and that absence is what buys the negative answer: `never` is a census rather
than a search that came back empty. mgtt's facts are `mgtt.int`, `mgtt.float`,
`mgtt.bytes`, `mgtt.duration`. So this section is where the crossing is either
honest or it is nothing.

It is honest, and for a reason about mgtt rather than a cleverness here.
**mgtt's expression language has six comparison operators and no arithmetic.**
Its grammar is

```
or      = and ("|" and)*
and     = primary ("&" primary)*
primary = cmp | "(" or ")"
cmp     = ref cmpop value
```

with `cmpop` one of `== != < > <= >=`. There is no `+`. Every predicate in an
mgtt model is therefore a comparison of one fact against a constant, or against
a sibling fact.

From which the reduction follows. The constants a model mentions cut a fact's
value line into finitely many regions, and **every predicate in that model is
constant on each region**. So a region becomes a member of an enumerated type,
and two concrete values lying in one region were already indistinguishable to
mgtt's own engine. Nothing is approximated. This is the kernel spec's own move
— *counting becomes naming, calculating becomes writing down* — applied to a
fact rather than to a payment.

### Cutting, then merging

Cutting alone is not enough, and the reason is a state-space argument rather
than a tidiness one. Cut `connection_count` at 500 and you get three regions:
below it, exactly it, above it. But if `< 500` is the only predicate the model
applies, nothing distinguishes 500 from 501, and carrying three members would
put a distinction in the model that no rule can make — doubling that fact's
contribution to the product to represent a difference the engine could never
observe.

So the regions are cut by every constant and then **collapsed wherever no
gathered predicate separates two neighbours**. Whether a fact's domain ends up
coarse or fine is decided by what the model asks of it, not by its type. Two
facts from the same worked model, both integers, both compared against zero:

```lisp
(type gateway-upstream-count (below-0 exactly-0 above-0))
(type workload-endpoints     (below-0 above-0))
```

The gateway's states use both `upstream_count > 0` and `upstream_count == 0`,
and those two predicates disagree about zero, so zero must be a member of its
own. The workload only ever asks `endpoints > 0`, so nothing tells zero apart
from anything else below one, and the two regions merge. Same type, same
constant, different domains — because the models ask different questions.

### Where it stops

A fact compared with a *sibling* fact needs a joint domain rather than an
independent one, since the predicate reads the pair: `ready_replicas ==
desired_replicas` constrains two cells at once. Those become one cell with
three members, which is exactly what six operators can distinguish about two
values with no arithmetic between them:

```lisp
(type workload-desired-replicas-vs-ready-replicas (fewer equal more))
```

The pair is named from the alphabetically-first fact, so one pair spells one
way however the author wrote it.

**A fact compared both with a sibling and against a constant** needs more than
either shape alone. `ready_replicas == desired_replicas` alongside
`desired_replicas == 0` constrains the same two cells: an ordering cannot say
the second, and two independent region domains cannot say the first, because
independent regions cannot decide `ready == desired` when both values land
inside one region.

So the shared cell carries **a region for each fact**, cut by the constants
applied to either of them, and the ordering falls out of comparing the two
representatives rather than being stored beside them — a stored ordering is a
third fact that can contradict the first two. Combinations that cannot occur
are not members: where the two regions differ, which one is lower already
settles the ordering, so there is one member and not three.

This is why a region carries **bounds** and not only a representative. One
representative answers "does this region satisfy `< 500`", which is all a
single-fact domain ever asks. It cannot produce a *second distinct value inside
the same region*, which is exactly what "both facts here, the left one larger"
requires — and the first cut of this, representing that as `(rep, rep+1)`, let
the left value escape into the region above, so a member named `below-0-more`
satisfied `desired == 0`. It passed every coherence check and was still a lie
about what it named.

A non-integer constant is refused outright. Writ has no floats to name a member
after and no ordering worth inventing for one, and refusing loudly is what
`writ sql` does with arithmetic in a `CHECK`, for the same reason.

## 4. What a state is here

The decision that shapes everything downstream: **facts are the only varying
cells. There is no `state` arrow.**

The alternative is obvious enough to be worth refuting. mgtt names states —
`live`, `degraded`, `draining` — and an arrow into an enumerated type of those
names would be the direct translation. It fails on the question the bridge
exists to answer. A component's state and its health are *both* predicates over
its facts; carry the state as a cell and their agreement becomes something this
emitter computes and reports, rather than something the model states and writ
decides. A law you evaluate yourself is not a law, it is a lint.

Carrying the facts and deriving both makes the agreement an `equation` over
real cells — §5 — and it is also what keeps the space small, §7.

## 5. The law, and why a type per override

The law is: **a component is healthy exactly when it is in its default active
state.**

```lisp
;; healthy: available == true & connection_count < 500
;; active:  available == true
(equation datastore-health-matches-state
  (iff (and (is datastore.available yes) (is datastore.connection-count below-500))
       (is datastore.available yes)))
```

`iff` is generated into the file rather than shipped: a law must be a guard,
mutual implication is two of them, and a form renames and pastes so an error
inside it still points at a line that exists. Every emitted block carries the
mgtt text it came from as a comment, so a finding walks back to a line of YAML.

Now the constraint that shapes the schema.
[§8.6](https://github.com/writ-lang/writ/blob/main/docs/kernel-spec.md#86-equation) requires a law's subject to be a **declared
type** — *"chains are written from the type, not an entity"* — so that the law
ranges over every entity of it. But mgtt lets a single component override
`healthy:` while keeping its type, and that override is precisely the case
worth catching: it is where a component's own definition of health drifts from
the state rules it is judged by.

A law rooted at the shared type could not see it. So the emitter groups
components by **(mgtt type, effective healthy)** and emits one writ type per
group: components agreeing with their type keep its name, and any component
overriding gets a type of its own, named for both. Its law then ranges over
exactly one entity — that component — which is what per-component checking
requires, obtained without adding a construct.

## 6. The moves

### Origination, and why it cannot be omitted

Each component gets one move per non-default state: from healthy into that
state, guarded on being healthy now.

```lisp
(transition store-fails-stopped
  (when (is store.available yes))
  (do  (set store.available no)))
```

This looks like an addition and is a necessity. Propagation only *relays* a
failure from a dependency; with nothing to originate one, no move is ever
enabled at the initial situation, and the model enumerates exactly one
situation with no edges — every question answering vacuously, every law holding
because nothing can reach a counterexample. That is not a small model, it is a
model that says nothing while appearing to pass.

mgtt supplies the origin from outside: an injected fact in a scenario, a probe
result at 3am. Its own scenario enumerator supplies it the same way, by taking
each component in turn as the root cause. Measured on the four-component
worked model: **1 situation and 0 edges without these moves, 64 and 268 with.**

### Propagation, from mgtt's own label protocol

mgtt declares propagation in two halves: a failing state emits `can_cause`
labels, and a state of a dependent declares `triggered_by` labels it answers
to. One transition per matching (dependency edge × emitted label × triggered
state):

```lisp
(transition store-stopped-triggers-api-degraded
  (when (and (is store.available no) (is api.desired-replicas-vs-ready-replicas equal)))
  (do  (set api.restart-count above-5) (set api.desired-replicas-vs-ready-replicas more)))
```

The effect writes a **representative assignment** of the target state — the
first, in domain-declaration order, that satisfies its guard. First rather than
any, because the choice must be reproducible: two runs of the emitter that
picked differently would produce two models from one input, and `writ compare`
would report a change nobody made. Only the cells that actually differ from the
default state are written, so `can be broken by` stays truthful about what each
move touches.

Note the guard's second half. A propagation move requires the dependent to be
*healthy now*, which is what keeps the moves monotone — §7 — and keeps a
witness route reading as a chain of distinct events rather than a component
degrading twice.

Moves are named, always. A witness route prints move names, and an unnamed move
makes the route unreadable, which is most of what a route is for.

## 7. What an answer costs

The standing worry about the direct translation is the product: twenty
components at four states each is 4²⁰, and no enumeration survives that.

It does not form, and the reason is structural rather than lucky. The initial
situation is every component healthy; origination moves lead away from health;
propagation moves lead away from health. **No move restores it.** So the
reachable set is not the product of the state domains but the set of *consistent
failure configurations* — which is the set mgtt's own enumerator walks when it
writes `scenarios.yaml`.

Measured, on the same four-component model: writ reports 64 situations and 268
edges; mgtt's enumerator writes 76 chains. The two count different objects — a
chain is a route from a root cause, a situation is a whole-system configuration
— so neither number bounds the other, and the point is not that one is smaller.
The point is that both are in the tens, from a model whose naive product is in
the hundreds.

[§14](https://github.com/writ-lang/writ/blob/main/docs/kernel-spec.md#14-conformance) permits an implementation limit no lower
than 200 000 situations. A deployment large enough to exceed it is one whose
answer set was too big to have wanted, which is the README's reading of when a
model is too big, and it applies unchanged here.

**What would cost.** Adding repair moves — a component recovering — makes
states mutually reachable, the product forms, and the argument above is gone.
That is not an oversight: it is the price of asking whether recovery is always
still reachable, and it should be asked deliberately and scoped, not switched on
by default.

## 8. What is declined

Named on stderr, grouped by reason with a count and a first subject, never
dropped. Aggregation is not tidying: forty components resolving to a generic
placeholder would otherwise bury the one decline that mattered.

| Declined | Why |
|---|---|
| a non-integer constant | no member name, and no ordering worth inventing |
| a fact no predicate mentions | no regions to name, so no arrow to make |
| a state no assignment satisfies | it is unreachable, which is a finding in itself |
| a model whose dependencies pair no `can_cause` with a `triggered_by` | it has no moves at all, and would report clean |
| mgtt's own declines | forwarded unchanged |

The last two deserve their standing. A model with dependencies but no
propagation enumerates one situation and reports no findings — the most
misleading answer this bridge could give, and the shape a provider ships when
it declares `can_cause` and omits the other half. And a `state` nothing can
satisfy is the same finding mgtt's own validation reports for a `triggered_by`
label with no producer, arrived at independently.

Two things are **out of scope by design** rather than declined, and the
distinction is the one writ already draws between a `gap` and a dead end. Probe
cost and ranking stay with mgtt: writ has no numbers, and *can these be told
apart at all* is the question upstream of *which to check first*. TTL and
staleness stay with mgtt: writ has no clock.

## 9. End to end

```console
$ mgtt model export --json | mgtt2writ | writ check --stdin
states: 64   edges: 268
gaps: none
dead ends: 9
  reached by: api-fails-degraded, edge-fails-draining, frontend-fails-degraded, store-fails-stopped
equation datastore-store-health-matches-state
  can be broken by: store-fails-stopped   (acknowledge in claims)
  violated in 32 reachable situations   witness: 1. store-fails-stopped
$ echo $?
1
```

That finding is the whole argument in one line. The model's `store` overrides
`healthy:` to check `connection_count` and forget `available`, while its type
derives its state from `available`. Half of the reachable configurations of
that system disagree with themselves about whether the component is healthy,
and one failure is enough to reach the nearest one. It is not a wrong
conclusion about any particular scenario, so no scenario finds it; it is a
property of the model, and properties of the model are what exhaustion is for.

## 10. Deliberately absent

- **The other direction.** `writ sql` reads both ways because a relational
  schema and an olog are two spellings of one object. An mgtt model is a
  description of a system; writing one back from a writ model would be
  synthesis, and a different feature. The door is open; the verb is not.
- **Live probing.** The bridge is design-time. `diagnose` is mgtt's.
- **Repair moves**, §7 — until the question that needs them is asked
  deliberately.
- **Diagnosability** — whether two distinct root causes produce identical
  observable facts, which caps how well any engine can diagnose the system.
  It is a rules query over the derived state category
  ([interrogator.md §2](https://github.com/writ-lang/writ/blob/main/docs/interrogator.md)) rather than a change to this reading,
  and it is the next thing worth building.
