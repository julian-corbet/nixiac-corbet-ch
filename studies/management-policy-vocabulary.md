# Two surveys disagreed about an enum, and the docs were wrong about a third thing

**Provenance: a survey of upstream source and documentation, 2026-07-30. Not
a measurement against a running cluster.** Nothing in this repo has applied a
manifest to a real API server; what follows is what the source says, and how
the disagreement between two readings of it was settled.

## The question

`spec.managementPolicies` on a Crossplane managed resource takes a list of
action strings. nixiac needs the exact accepted set for two reasons: to
validate `nixiac.defaults.managementPolicies` at build time, and because
`lib.mkManagedResource` has no module system to lean on and must check the
vocabulary itself.

## What the two readings said

**Survey A** reported the accepted values as:

    Observe, Create, Update, Delete, LateInitialize, MustCreate, Orphan, *

citing a `crossplane-runtime` pull request that added an `Orphan` convenience
action described as equivalent to "everything except Delete", and noting that
the published documentation page did not mention `Orphan` at all — concluding
that the docs were simply stale and the source should be trusted.

**Survey B** read the kubebuilder `Enum` annotation in `crossplane/crossplane`'s
own `apis/core/v2/policies.go` and reported:

    Observe, Create, Update, Delete, LateInitialize, *

with two supporting observations: `Orphan` had **zero** hits anywhere in
`crossplane-runtime` as a management action, and the `MustCreate` hits were
an unrelated test helper (`resource.MustCreateObject()`) rather than an API
value.

## How it was settled

The kubebuilder annotation *is* the enum. It is what generates the CRD's
`enum:` list, which is what the API server validates against. A pull request
title, a docs page, and a survey's summary are all downstream of it, and only
one of them is what the cluster actually enforces. Survey B's reading is
what nixiac implements.

The half of Survey A that was right is worth keeping: the documentation page
genuinely is unreliable here, and "trust the source over the docs" was the
correct instinct. It was applied to the wrong artifact — a PR is not the
source either.

`Orphan` is not invented from nothing, which is exactly why it is the most
likely wrong answer somebody writes: it **is** a legal value — of
`spec.deletionPolicy`, the older, deprecated field that does the adjacent
job. Two generations of the same idea, two fields, two vocabularies that do
not overlap.

## Why the distinction is load-bearing rather than pedantic

An unknown enum member is rejected by the API server **at apply time**. In a
GitOps loop that means a manifest which renders cleanly, commits cleanly,
syncs, and then fails inside a controller log nobody is reading — while the
person who wrote `Orphan` believes they asked for "manage everything except
deletion" and got it.

That is the same failure shape as almost everything else this repo guards
against: not a loud error, but a declaration that reads as though it took
effect.

## What it changed here

1. **`lib/management-actions.nix` exists as a table** rather than the enum
   being written out inline in the two places that need it. Three consumers
   need the identical list — the module's assertion, the rendering function's
   `throw`, and the checks that prove both — and three transcriptions of one
   enum is the drift this family removes everywhere else.

2. **A `rejected` table, keyed by the wrong name.** `Orphan`, `MustCreate`,
   `FullControl` and `Ignore` each get an explanation of what they actually
   are and what to write instead. A build failure that says "not a member of
   the enum" is correct and unhelpful; one that says "`Orphan` is a legal
   `deletionPolicy` value, not a management action — if you meant *manage
   everything except deletion*, write the set out" is the difference between
   a five-minute fix and a search.

3. **`nixiac.defaults.managementPolicies` is typed `listOf str`, not
   `listOf (enum …)`.** An enum type would reject an illegal member first,
   which makes the assertion unreachable — and the assertion is the better
   guard precisely because it can consult the `rejected` table. Two guards
   for one condition, one of them unreachable, is worse than one guard with a
   message that teaches.

4. **A separate, non-negotiable observation about `*`.** It is Crossplane's
   own default, which means *omitting* `managementPolicies` is the most
   dangerous possible value of it. Every part of this repo's inverted-defaults
   design follows from that one sentence.

## The other thing the source settled

While reading the same area: the modern (v2, namespaced) managed-resource
kinds have **no `deletionPolicy` field at all** — the modern policy resolver
in `crossplane-runtime` is constructed without one, while only the legacy,
cluster-scoped resolver takes it. That is why `lib.mkManagedResource` has a
`scope` argument, why it omits `deletionPolicy` for namespaced resources, and
why asking for `deletionPolicy = "Delete"` there is a hard error rather than
a quiet omission: the field would not reach the cluster while the operator
had every reason to believe a destructive request had been recorded.

## What is still unverified

Everything above is what the source says. None of it has been confirmed by
applying a manifest with a rejected value and observing the API server
refuse it. That is the honest gap, and it is the same gap the whole repo
carries until something it renders reaches a real cluster — see the main
[README](../README.md)'s Status section.
