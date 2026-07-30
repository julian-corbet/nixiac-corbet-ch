# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for this project's own judgment calls —
every entry below corresponds to a default, a gap, or a design choice that is
reasoned but not yet measured against a real control plane. Reasoning already
settled well enough to state as a decision lives in
[`../docs/design.md`](../docs/design.md) instead.

## 001 — credentials that are not a Secret at all

**Question:** `nixiac.providers.<name>.credentialsSecret` is required, and
`modules/control-plane.nix` renders `spec.credentials.source = "Secret"`
unconditionally. Providers on some clouds can instead take an injected
workload identity — the pod's own service account is the credential, and
there is no Secret to reference. That declaration is currently
unexpressible: the required field has nothing to point at.

**Why it was left this way rather than made nullable.** A nullable
`credentialsSecret` weakens the assertion that catches the failure this repo
most wants to catch — a provider declared with no credentials at all, which
applies cleanly and then fails at reconcile time in a controller log nobody
is reading, with the symptom being "these resources stopped being observed"
rather than "the provider is down". Trading a real guard for an
unimplemented case is the wrong direction.

**What the fix probably looks like:** a `credentialsSource` enum
(`"Secret"` | `"InjectedIdentity"` | …) with `credentialsSecret` required
*iff* the source is `Secret`. That keeps the guard sharp and makes the
identity case a declaration rather than an omission. Not done yet because
the exact set of accepted `source` values, and their exact spelling, differ
per provider family and none of them has been read off a live installation
here.

**Status:** open. No injected-identity provider has been declared against
this repo.

## 002 — does `initProvider` apply to a resource Crossplane never created?

**Question:** `spec.initProvider` is the only analogue of Terraform's
`ignore_changes` available, and it is the lever that stops a converging
resource from fighting an out-of-band change to a field. Its own generated
documentation says those values are merged **"when the resource is
created"** — and a resource nixiac adopts is, by construction, never created
by Crossplane. Does the merge happen at all on an adopted resource, or is the
field silently inert there?

**Why this is the sharpest open question in the repo.** It is the difference
between "a converging adoption can be told to leave one field alone" and "it
cannot". On a resource whose spec is a partial hand-transcription of
reality, an inert `initProvider` means a field somebody believed was
protected is the next thing to be converged.

**How it is handled meanwhile:** `lib/managed-resource.nix` renders the field
as given and does **not** pretend to a guard it has not measured. Shipping a
check for behaviour that has not been observed would be shipping a guess as
a rule, which is worse than the honest gap.

**What would settle it:** an adopted resource with a deliberately mismatched
`spec.forProvider` field listed in `initProvider`, `managementPolicies`
including Update, and an out-of-band change to that field on the live
resource. Either the next reconcile leaves it alone or it does not.

**Status:** open, and blocked on the same thing everything else here is:
nothing this repo renders has been applied to a real cluster yet.

## 003 — is a per-object `apiVersion` option the right shape for an alpha API?

**Question:** `nixiac.activation.apiVersion` exists because the activation
mechanism is alpha upstream and its API group is expected to move — so a
consumer can correct it in one place without waiting on this repo. But an
option that exists purely to absorb upstream churn is also an option that can
be set to something wrong, and nixiac cannot validate it against anything.
Is that the right trade, or should this repo simply track the group and
require a bump?

**Reasoning as it stands:** the option wins while the feature is alpha,
because "the group moved and the manifests are rejected as an unknown kind"
is a same-day problem for a consumer and a next-release problem for this
repo. It should probably become a plain constant the moment the API
stabilises, at which point an override is a foot-gun with no upside.

**Status:** open, and self-resolving — revisit when the upstream feature
leaves alpha.

## 004 — should `activate` selectors be validated for shape?

**Question:** `nixiac.activation.activate` currently asserts only that
entries are non-blank and that a wildcard is deliberate. A selector naming a
type as `<plural>.<group>` is the form the API server uses elsewhere, but the
exact accepted form for this alpha field has not been read off a live
installation, so nothing here checks it. A malformed selector activates
nothing, and the symptom is a CR rejected as an unknown kind — the same
symptom as forgetting the entry entirely.

**Why nothing was asserted:** guessing a format and enforcing it would turn a
correct declaration into a build failure the day the guess is wrong, which is
the failure mode this repo has the least tolerance for. Asserting the shape
of something unverified is not a stricter check, it is a fabricated one.

**What would settle it:** `kubectl explain
managedresourceactivationpolicy.spec.activate` against a live installation,
plus one deliberately malformed selector to confirm what the API server does
with it (reject at apply, or accept and match nothing — those are very
different, and only one of them is worth a client-side check).

**Status:** open.

## 005 — should the module-level intent gate exist at all?

**Question:** the intent gate exists twice: on
`nixiac.defaults.acknowledgeDangerousDefaults`, which unlocks the dangerous
behaviour for *every* resource at once, and on `lib.mkManagedResource`'s own
`acknowledgeDangerous`, which unlocks it for one. The per-resource one is
plainly the better place for it. Is the global one a convenience worth
having, or a loaded footgun with a sentence taped to it?

**Reasoning as it stands:** keep it, because a control plane that genuinely
created everything it manages is a real and legitimate configuration, and
forcing that consumer to repeat an acknowledgement on every single resource
would train them to paste the same sentence a hundred times — which converts
the sentence back into a boolean, the exact thing the gate exists to avoid.
The option's own description says outright that it makes every resource
dangerous at once and points at the narrower alternative.

**What would settle it:** a real consumer with a genuinely
create-everything control plane, and whether they end up using the
global gate or per-resource acknowledgements in practice.

**Status:** open, and deliberately decided-for-now rather than left
unimplemented.
