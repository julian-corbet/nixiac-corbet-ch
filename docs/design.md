# Design notes

The reasoning already settled well enough to state as a decision rather than
an open question. Open questions live in
[`../experiments/README.md`](../experiments/README.md); measured write-ups
live in [`../studies/`](../studies/README.md).

## Why a module-system module, for something that never touches a host

Nothing in this repo runs on a machine. A control plane runs on a Kubernetes
cluster, and these files only ever produce data describing one. So the
obvious question is why they use the NixOS module system at all, rather than
being plain functions the way `lib/managed-resource.nix` is.

The answer is that three of the four things this repo does are things the
module system is uniquely good at and a plain function is bad at:

- **A typed option surface with descriptions attached to the values.** The
  descriptions are not documentation *about* the code; they are the reason
  the repo exists in the readable form it does. A plain function's argument
  set cannot carry them anywhere a consumer will see.
- **Assertions that accumulate across a composition.** Ten providers
  declared across three files produce one report naming every problem, not
  the first `throw` that happens to be forced.
- **Merging.** Two modules contribute to one `nixiac.manifests`, and a
  consumer contributes its own objects to the same attrset, without anything
  coordinating.

What the module system is *not* used for here is `config` in the NixOS sense.
These modules write no host option, which is why `flake.nix` also exports
them as `modules.*` — the same three files under a name that does not claim a
host — and why `checks/purity.nix` proves the claim mechanically instead of
asserting it in prose. A GitOps renderer, or a bare `lib.evalModules`, is an
equally valid evaluator.

`lib.mkManagedResource` is the one thing that is deliberately *not* a module,
for the mirror-image reason: it is called from inside somebody else's render
loop, where there is no `config.assertions` for a guard to live in. Its
guards are `throw`s, so they exist wherever it is called from.

## Why plain data out, and no renderer integration

`nixiac.manifests` is an attribute set of Kubernetes objects as Nix data.
Not YAML, not a Helm chart, not an Argo CD `Application`, and not an
integration with any particular GitOps tool.

Serialising to YAML needs a tool (`yq`, `remarshal`, `kubectl`), which needs
`pkgs`, which would mean these facts could no longer be read without a build
behind them — and "readable without a build" is the whole property this repo
is organised around. JSON is a strict subset of YAML 1.2, so
`builtins.toJSON` of each object is a document every Kubernetes client and
every renderer already accepts, with no tool, no derivation and no store path
anywhere between the declaration and the manifest.

Integrating with a specific renderer would be worse than unnecessary: it
would make the *delivery mechanism* a fact about this repo instead of a fact
about the consumer, and it would put a second flake input in a repo whose
dependency discipline is the reason it composes freely.

## Why three modules and not one

`nixiac.providers` answers "which controllers run" — a property of the
control plane's composition. `nixiac.activation` answers "how much
API-server memory may the CRD footprint cost" — a property of the
*cluster's* budget, decided by whoever owns that cluster's headroom, and
legitimately different between two environments running an identical
provider set.

Lumping them into one toggle forces one answer for both. That is the same
reason nothing in this family ships a single `tools.enable`: one option per
tool, never a bundle.

`modules/manifests.nix` is a third file for a narrower, mechanical reason.
Both of the other two write into `nixiac.manifests`, and both are exported
standalone, so either may be the only nixiac module a consumer imports. An
option declared independently in two modules is a merge that depends on the
two declarations agreeing about type, default and `readOnly` forever — so the
declaration lives in one file that both import instead. Importing the same
path twice is idempotent in the module system, which is what makes this work
without either module knowing whether the other is present.

## Why `enable` exists here, when the pure-data modules in this family have none

Most schema-only modules in this family have no `enable` at all: there is
nothing running to turn on, so the act of importing the file *is* the toggle.

This one earns one. The attrset it produces is handed to a GitOps renderer,
so a non-empty `nixiac.manifests` is the difference between a validated
declaration and a control plane being installed into a live cluster on the
next sync. That is a genuine on/off, not a schema.

What `enable` deliberately does *not* gate is validation. Everything declared
is checked, enabled or not. A declaration that gets the data and none of the
safety is precisely the wrong thing to teach — and an example or a
half-finished branch is exactly where a bad declaration is written.

## Why the intent gate is a sentence and not a boolean

Every place this repo lets a caller turn off a safe default, it demands a
non-blank string rather than `= true`.

A boolean can be typed by reflex. It reads as noise in a diff. It answers no
question a year later, and it names nobody. A sentence has to be composed; it
shows up in review as prose someone chose to write; it names the person who
accepted the risk by being in their commit; and it is still legible to
whoever inherits the declaration long after the reason has stopped being
obvious. The gate checks for *content*, not presence, so a single space does
not count — otherwise the field becomes a boolean with extra steps.

The rule the gate encodes is deliberately memorable and deliberately narrow:
**`Observe` is the only action nixiac applies without a written reason.**
Not "destructive actions", which invites arguing about which ones those are.
Everything that can change or destroy something that already exists needs a
reason — including `LateInitialize`, which changes nothing in the cloud and
destroys the *evidence* an adoption depends on.

The same rule sets the boundary for what is gated and what is merely
documented. Enabling an alpha upstream feature (`nixiac.activation`) can cost
a migration; it cannot cost a resource. So that one carries a loud warning
and no gate.

## Where the boundary sits between this repo and its consumer

nixiac renders the *shape* of a control plane. It never holds a value that
identifies a particular one.

- **Credentials** are a name/namespace/key reference. Never a value. A public
  repo that could hold a credential eventually holds one, and a credential in
  a Nix store path is world-readable on every machine that evaluated it.
- **Provider-specific scoping** — a project identifier, an account, a region —
  reaches the render through `providerConfigSpec`, a deliberate hole. nixiac
  knows no provider's ProviderConfig schema, so typing those fields would be
  re-deriving one provider's CRD one field at a time and would be wrong for
  the next one; and every value that belongs there is a value about somebody's
  infrastructure rather than about the mechanism.
- **The ProviderConfig API group** is asked for rather than derived, and this
  is the sharpest case of the same boundary. `Provider` is a core Crossplane
  type, so its group follows from the pinned core version and this repo can
  know it. `ProviderConfig` is defined by each provider's own CRDs and its
  group is chosen by that provider — there is no registry to consult at eval
  time, and a guess renders an object rejected as an unknown kind, at apply
  time, after the manifest has committed and synced cleanly. Asking is the
  only honest option.
- **Actual resources** belong to whatever private configuration imports this.
  Every example in this repo is a placeholder, including the ones that look
  like they could be real.

## Testing philosophy

Every assertion is proven in **both** directions: it fires on the violation,
and it stays silent on the nearest thing that is not one. A guard shown only
to reject something is half a guard — an assertion with an inverted condition
passes that half and breaks every legitimate declaration, and nothing would
notice until someone tried to declare something correct.

Three consequences that shaped the check files:

- **Base fixtures are checked first.** Each group's "the valid declaration
  builds fine" check is listed at the top, because if the base fixture is
  itself broken then every negative check in that group is proving nothing,
  and that should be the first line of the report.
- **Meta-tests, wherever a comparison could be vacuous.** `checks/purity.nix`
  composes a decoy module that genuinely binds `pkgs`, genuinely adds a
  systemd unit and genuinely installs a package, so each comparison is shown
  capable of failing rather than merely observed not to fail today.
- **Fixtures are built, not merged, when a field must be ABSENT.**
  `lib.recursiveUpdate` merges, so `removeAttrs` on a provider hands back an
  attrset whose missing field is then re-supplied by the merge. Both mistakes
  were made writing `checks/control-plane.nix`, and both produced checks that
  *passed* while testing something other than what they claimed — the
  duplicate-package fixture passed because the merge had silently created a
  third provider. `withProviders` exists because of that.

Nothing here builds or boots anything, and that is a property of the repo
rather than a shortcut: nixiac renders plain data, so "did it validate" and
"did it render the right object" are both properties of an evaluation.

What is **not** proven here, stated as plainly as what is: no manifest this
repo renders has been applied to a real cluster. Every claim about what the
API server accepts comes from upstream source, upstream documentation, or a
survey. See the main [README](../README.md)'s Status section for the full
list of what has and has not run.
