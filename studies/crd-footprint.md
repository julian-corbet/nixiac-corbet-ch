# A control plane's CRD count is a memory budget, not tidiness

**Provenance: a survey of upstream documentation and announcements,
2026-07-30. Not a measurement against a running cluster here.** The numbers
below are upstream's own, quoted with their context; nothing in this repo has
installed a provider and measured an API server.

## Why this needed writing up at all

"Install only what you use" reads like hygiene advice, and hygiene advice does
not earn a module. The reason `modules/activation.nix` exists as a separate,
independently toggleable module — rather than a sentence in the README saying
*keep your provider list short* — is that there are two distinct mechanisms
from two eras of the project, both still current, and the second one has a
large number attached and a default that silently cancels it.

## Era 1 — provider families (2023, and mandatory since 2024-06-12)

The problem, in upstream's own framing: one monolithic cloud provider
installed **more than 900 CRDs by itself**, and the resulting CRD-driven
scale-up could leave a control plane's API **unresponsive for up to an
hour**.

The fix was splitting each monolithic provider into a `provider-family-<cloud>`
base package — which owns the shared ProviderConfig type — plus one package
per service group, each its own controller, so an installation carries only
the service packages it uses.

The part that matters for a declaration written today: **support for
monolithic providers ended 2024-06-12.** For the large clouds there is no
longer a monolithic package to install even if you wanted one. This is a hard
constraint, not a recommendation, and a `nixiac.providers` entry naming a
monolithic package is naming something that does not exist.

## Era 2 — per-type activation (Crossplane v2+, alpha)

Family packaging is necessary and **no longer sufficient**, because a single
service package of a large cloud provider still installs far more types than
any one installation composes.

Upstream's own numbers, from the guide on disabling unused managed resources:

| Quantity | Value |
|---|---|
| API server memory per CRD | ~3 MiB |
| CRDs installed by one service package of a large cloud provider | ~200 |
| API server memory that costs | ~600 MiB |
| CRDs left after selective activation, in the documented case | 3 |
| Reduction | ~99% |

The mechanism: since v2, a provider's CRDs arrive as **inactive**
`ManagedResourceDefinition`s — no real CRD, near-zero cost — and a real CRD
materialises only when a `ManagedResourceActivationPolicy` names that type.
The inactive-to-active transition is one-way.

## The trap that made this a module instead of a paragraph

**The default installation cancels the mechanism entirely, silently.**

The chart's own install creates a permissive activation policy that activates
everything. Activation policies are **additive**, so with that policy present
a narrow one adds nothing and changes nothing: full CRD count, full memory
cost, and a declaration that reads as though the footprint were under
control. Getting the documented reduction requires deliberately disabling the
chart's default activations at install time.

That is two independently maintained declarations — the activation policy and
the chart's values — that must agree, or the whole thing is theatre. Which is
exactly the kind of coupling this family refuses to leave to memory.

## What it changed here

1. **`modules/activation.nix` is a separate module, not a field on a
   provider.** Provider composition answers "which controllers run"; this
   answers "how much API-server memory may the type definitions cost". The
   second is the cluster's budget, decided by whoever owns that cluster's
   headroom, and two environments running an identical provider set can
   legitimately answer it differently. One toggle would force one answer.

2. **Enabling it changes `nixiac.helmRelease.values`.** Specifically it sets
   `provider.defaultActivations = [ ]`. That is the whole reason
   `helmRelease` is a derived, published fact rather than four strings a
   consumer retypes: a footprint discipline that depends on two separately
   maintained declarations agreeing is one that will eventually stop being
   true, and `checks/activation.nix` proves the wiring in all three states of
   the defensive sibling read (module absent, present-and-disabled,
   present-and-enabled).

3. **`policyName` defaults to `"nixiac"`, deliberately not `"default"`.**
   That name belongs to the chart's own permissive policy. Colliding with it
   would make the two objects the same object, so which one won would depend
   on sync ordering rather than on anything declared. Disable the chart's
   policy explicitly; never by collision.

4. **An empty `activate` with `enable = true` is a build error.** With the
   chart's permissive policy disabled and nothing activated, *no* managed
   resource type has a real CRD, so every CR the consumer applies is rejected
   as an unknown kind — while the control plane looks installed and healthy.
   The failure is loud and same-day, which is the right direction for this
   trade to fail in, but it should not require a cluster to discover.

5. **`[ "*" ]` requires a written reason.** It is the one value that produces
   the full pre-2023 footprint while reading like a configured one. A
   throwaway cluster where API-server memory is not a constraint is a
   legitimate case; it is just a case worth one sentence.

6. **It is off by default, and gated by documentation rather than by an
   acknowledgement.** The mechanism is alpha upstream: it may change or be
   dropped, and its API group is expected to move — which is why
   `nixiac.activation.apiVersion` is an option at all. Depending on an alpha
   API can cost a migration; it cannot cost a resource, and this repo reserves
   its written-reason gates for things that can overwrite or destroy something
   that already exists.

## What is still unverified

The reduction has not been reproduced here. No provider has been installed by
anything this repo rendered, no API server's memory has been measured before
and after, and the exact accepted form of an `activate` selector has not been
read off a live installation — see [`../experiments/README.md`](../experiments/README.md)
#004 for why nothing asserts that shape rather than guessing it.
