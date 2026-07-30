# nixiac

**A control plane is a configuration, not a program. nixiac declares one in
Nix — which providers, at which pinned versions, wired to which credentials
by reference — and renders plain Kubernetes objects for something else to
apply.**

**And it inverts Crossplane's two most dangerous defaults, so that converging
or destroying a resource that already exists has to be asked for, per
resource, in writing.**

`nixiac` is the declarative model of a [Crossplane](https://crossplane.io)
control plane: what runs, at what version, with what providers, pointed at
what credentials, and how much API-server memory its CRD footprint is
allowed to cost. It installs nothing, applies nothing, and reaches no
cluster. Its entire output is `nixiac.manifests` — an attribute set of
Kubernetes objects as plain Nix data, which any GitOps renderer, any client,
and any human already accepts.

It exists because the cloud layer of your infrastructure is the one part that
routinely gets written as a general-purpose program — a TypeScript file, a
Go module, a Helm values file three levels of templating deep — and a
program is opaque to anything that reads *source* rather than running it.

## Why the control plane belongs in Nix

Not for Nix's sake, and not for the module system's. For one measured
property.

A tool that renders an architecture — a documentation site, a dependency
graph, an audit — has two ways to learn what it is made of. It can
**evaluate** the configuration, or it can **parse** it. On the hosts this
family was built for, those cost ~95 s and ~0.021 s respectively for the
same fact, and evaluation additionally throws away every comment on the way.
Three orders of magnitude, and all of the prose.

Parsing only works on a declaration. A control plane described as an
imperative program is a language island: whatever renders the rest of the
setup cannot read it, so cloud infrastructure becomes the one component
that is invisible in the picture. That is the actual motivation for this
repo — not tool preference, and not Nix purity. Everything else here
follows from it:

- **Facts, never mechanism.** Nothing in this repo ships a systemd unit,
  touches a host, or produces a derivation. Proven mechanically rather than
  promised, via [nixtest](https://github.com/julian-corbet/nixtest-corbet-ch)'s
  shared `lib.mkPurityChecks` fixture — called once per module file so that
  each is proven pure *alone*, not merely as a group — and every proof there
  ships with a decoy that genuinely commits the violation, so the proof is
  shown capable of failing.
- **Plain data out, not rendered YAML.** Serialising to YAML would need a
  tool, which needs `pkgs`, which would make these facts unreadable without
  a build behind them. JSON is a strict subset of YAML 1.2, so
  `builtins.toJSON` of each object is a document every Kubernetes client
  already accepts.
- **No flake input on any sibling PRODUCT.** Where nixiac needs to know
  something another module declares, it reads the option defensively
  (`config.<x> or null`) — so the module keeps working on a consumer that
  never imported the sibling. The one flake input this repo does take,
  `nixtest`, is a different category of thing: a lib-only test fixture,
  never composed into anything this flake exports — see flake.nix's own
  `inputs` for why that does not weaken the rule.

## The three modules

- **`modules/control-plane.nix`** (`nixiac.*`) — which control plane runs, at
  which **pinned** version, with which providers, each wired to a
  ProviderConfig and a credential **reference**. Also the two inverted
  defaults every rendered resource inherits, and `nixiac.helmRelease`: the
  derived facts an installer needs, published as data rather than performed.
- **`modules/activation.nix`** (`nixiac.activation.*`) — how much API-server
  memory the CRD footprint is allowed to cost. A separate module because it
  is the *cluster's* budget rather than the control plane's composition, and
  two environments running an identical provider set can legitimately answer
  it differently.
- **`modules/manifests.nix`** (`nixiac.manifests`) — the single output
  surface both of the above write into, declared in one file so neither has
  to know whether the other is present. A consumer may contribute its own
  objects to it; every entry, whoever added it, is asserted to be an
  addressable Kubernetes object.

Plus one plain function, deliberately not a module:

- **`lib.mkManagedResource`** (`lib/managed-resource.nix`) — the rendering
  shape. One attrset in, one Crossplane managed-resource CR out, with the
  inverted defaults stamped on and the dangerous ones reachable only by
  writing down why. A function rather than a module because a GitOps
  renderer calling it has no `config.assertions` to collect, so its guards
  are `throw`s that exist wherever it is called from.

## The inverted defaults

This is the point of the repo, and the reason its option descriptions read
the way they do.

Crossplane's own defaults are:

| Field | Crossplane's default | What it means |
|---|---|---|
| `spec.managementPolicies` | `["*"]` | every action: observe, create, **update**, **delete** |
| `spec.deletionPolicy` | `Delete` | removing the CR **destroys the real cloud resource** |

Both are correct for the case Crossplane was designed around: a control
plane that *creates* what it manages, where "make reality match the spec"
and "remove the resource when its declaration goes away" are exactly what
you want.

They are exactly backwards for **adopting resources that already exist and
are already in production** — and both failures are silent.

1. **A partial spec becomes a diff, immediately.** Crossplane treats
   `spec.forProvider` as the source of truth. A freshly-applied CR with
   `managementPolicies` omitted inherits `["*"]`, which includes Update — so
   on the *first* reconcile it converges the live resource to whatever the
   spec says. The spec of a just-written adoption manifest is, by
   construction, a partial hand-transcription of what the live resource
   looks like. In `crossplane-runtime`'s own reconciler, when the
   observation is not up to date the diff is logged at DEBUG and
   `external.Update()` is called **in the same pass**. There is no
   confirmation step and no drift-detected condition to notice first.
2. **A refactor becomes a deletion.** `deletionPolicy: Delete` decides what
   happens to a real resource when its *declaration* goes away — and
   declarations go away for reasons unrelated to intent: a rename, a file
   moved between directories, a GitOps prune of a path that stopped being
   rendered.

nixiac's defaults:

| Field | nixiac's default | Consequence |
|---|---|---|
| `defaults.managementPolicies` | `[ "Observe" ]` | read the resource, populate `status.atProvider`, **never write** |
| `defaults.deletionPolicy` | `Orphan` | removing the CR leaves the real resource running and unmanaged |

Turning either one off requires **`acknowledgeDangerousDefaults`: a
sentence, not a boolean**. A boolean can be typed by reflex, reads as noise
in a diff, and answers no question a year later. A sentence has to be
composed, shows up in review as prose someone chose to write, names the
person who accepted the risk by being in their commit, and is still legible
to whoever inherits the declaration. An empty or whitespace-only string does
not count — the gate checks for content, not presence.

The same gate applies per resource in `lib.mkManagedResource`, which is the
better place for it: the module-level option makes *every* resource
dangerous at once.

**`Observe` is the only action nixiac applies without a written reason**,
because it is the only one that cannot change or destroy something that
already exists:

| Action | Why it needs a reason |
|---|---|
| `Create` | makes a **second** resource whenever the external name does not match the live one |
| `Update` | converges the live resource to `spec.forProvider` in the same pass the drift is noticed |
| `Delete` | destroys the real resource when the CR is removed |
| `LateInitialize` | rewrites **your own spec** to match reality, so a wrong declaration looks correct and the adoption evidence disappears |
| `*` | all of the above — and it is Crossplane's own default, which is why *omitting* the field is the most dangerous possible value |

Two things worth knowing next, both written into the option descriptions
where they are needed:

- **`Synced=True` does not prove an adoption is correct.** An observe-only
  resource whose spec is wildly wrong still reports it: when the policy
  forbids Update, the diff is logged at DEBUG and the reconcile is marked
  successful. The condition means "the controller ran", not "the declaration
  matches reality". Proving an adoption needs an out-of-band three-way diff
  — and it must be done *without* adding `LateInitialize`, which answers the
  question by making the evidence vanish.
- **`deletionPolicy` does not exist on modern kinds.** Crossplane v2 ships
  namespaced managed-resource kinds that have no such field at all.
  `lib.mkManagedResource` therefore omits it for `scope = "namespaced"` —
  which loses nothing, because on a modern kind orphan-on-delete comes from
  the *absence* of `Delete` in `managementPolicies`, which the default
  already gives. Asking for `Delete` there is a hard error rather than a
  quiet omission, so nobody believes a destructive request was recorded when
  it never reached the cluster.

## Boundary: what nixiac owns, and what it must not

| nixiac **owns** | nixiac **must not own** |
|---|---|
| Which control plane runs (`controlPlane`, an enum) | The cluster it runs on — that belongs to whatever declares the Kubernetes host |
| Its pinned version, and every provider's pinned version | The workloads beside it — a control plane is not an application platform |
| Which providers are installed, and their exact package references | **Credential values.** `credentialsSecret` is a name/namespace/key *reference*; a public repo that could hold a credential eventually holds one |
| ProviderConfig wiring **by reference** — which config name, which API group, which Secret | **Per-consumer resource values.** A project identifier, an account, a region — those reach the render through `providerConfigSpec`, a hole nixiac never fills |
| The Nix → Crossplane-CR rendering shape, and the defaults it stamps | Any real consumer's actual resources. Every example in this repo is a placeholder, on purpose |
| How much API-server memory the CRD footprint may cost | The GitOps mechanism that applies any of it |
| Assertions about all of the above | Anything that needs a host, a network, or a cluster to evaluate |

## What fails at build time

Every one of these is proven in `checks/` in **both** directions — it fires
on the violation, and it stays silent on the nearest thing that is not one.
A guard shown only to reject something is half a guard: an assertion with an
inverted condition passes that half and breaks every legitimate declaration.

| Refused | Because |
|---|---|
| a provider with no `credentialsSecret` | a ProviderConfig with no credentials applies cleanly and fails at *reconcile* time, in a controller log — and the symptom is not "the provider is down", it is that its resources quietly stop being observed |
| an incomplete `credentialsSecret` (blank name/namespace/key) | a partial reference renders something that looks wired up and resolves to nothing |
| two providers declaring the same `package` | two Provider objects race to install the same controller, and both declarations read as honoured |
| a `version` of `latest`, `stable`, a branch, or a bare major | an unpinned control plane upgrades itself between two reconciles, under resources already in production, with nothing recording what it upgraded *from* |
| a `package` carrying its own `:tag` or `@digest` | two places to write one version; the copy in the string is the one the cluster obeys, the one in `version` is the one a human reads |
| a missing or malformed `providerConfigApiVersion` | a ProviderConfig's API group is chosen by each provider, so a guess renders an object rejected as an unknown kind |
| `deletionPolicy = "Delete"`, or any non-`Observe` action, with no written reason | see [The inverted defaults](#the-inverted-defaults) |
| an illegal management action (`Orphan`, `MustCreate`, `FullControl`, …) | rejected by the API server at apply time, in a controller log, while whoever wrote it believes they asked for the behaviour the name suggests |
| `activate = [ "*" ]` with no written reason | reproduces the full CRD footprint the mechanism exists to avoid, while reading as though it were managed |
| `activation.enable` with an empty `activate` | with the chart's permissive policy disabled, *no* type gets a CRD, and every CR is rejected as unknown while the control plane looks healthy |
| an object in `nixiac.manifests` lacking `apiVersion`/`kind`/`metadata.name` | it renders, commits and syncs cleanly, then fails in a controller log |

Validation is **not** gated on `enable`. Anything declared is checked,
enabled or not — a declaration that gets the data and none of the safety is
the wrong thing to teach.

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixiac.url = "github:julian-corbet/nixiac-corbet-ch";

  outputs = { self, nixpkgs, nixiac, ... }: {
    # nixiac's modules touch no host surface, so any evaluator works --
    # NixOS's own eval-config.nix, a GitOps renderer, or a bare
    # lib.evalModules. `nixosModules.*` and `modules.*` are the same files.
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixiac.nixosModules.default   # controlPlane + activation
        ./control-plane.nix
      ];
    };
  };
}
```

```nix
# control-plane.nix -- every value below is a placeholder
nixiac = {
  enable = true;
  controlPlane = "crossplane";
  version = "v2.3.4";

  providers.example-cloud = {
    package = "xpkg.crossplane.io/example-org/provider-family-example-cloud";
    version = "v2.6.0";

    # Read this off the installed provider, never guessed:
    #   kubectl get crd -o name | grep providerconfig
    providerConfigApiVersion = "example-cloud.crossplane.io/v1beta1";

    # Provider-specific scoping. A consumer value: nixiac renders it and
    # keeps none of it.
    providerConfigSpec.projectID = "a-consumer-specific-identifier";

    # A REFERENCE. Never a value.
    credentialsSecret = {
      name = "example-cloud-credentials";
      namespace = "crossplane-system";
      key = "credentials";
    };
  };

  # Safe by default. Stated explicitly here because this is the part a
  # reader most needs to see.
  defaults = {
    managementPolicies = [ "Observe" ];
    deletionPolicy = "Orphan";
  };

  # Only the resource types actually composed get a real CRD.
  activation = {
    enable = true;
    activate = [ "examples.example-cloud.crossplane.io" ];
  };
};
```

Rendering one adopted resource:

```nix
let
  adopted = nixiac.lib.mkManagedResource {
    inherit lib;
    apiVersion = "example.example-cloud.crossplane.io/v1beta1";
    kind = "Example";
    name = "an-example";               # the CR's own name, chosen for readability
    namespace = "example";
    externalName = "the-id-the-cloud-already-uses";  # required, never defaulted from `name`
    providerConfigRef = "example-cloud";
    forProvider = { region = "somewhere"; };
    # managementPolicies defaults to [ "Observe" ]; deletionPolicy to "Orphan".
    # Anything else needs `acknowledgeDangerous = "a sentence".`
  };
in
  builtins.toJSON adopted   # JSON is valid YAML 1.2 -- hand it to any renderer
```

Handing everything to a GitOps renderer:

```nix
# Whatever already turns declarations into Argo CD Applications reads this
# one attrset. nixiac takes no input on any particular renderer.
map builtins.toJSON (lib.attrValues config.nixiac.manifests)
```

## Options reference

`nixiac.*` (`modules/control-plane.nix`):

- `enable` — render manifests. Most pure-data modules in this family have no
  `enable` at all; this one earns one, because a non-empty
  `nixiac.manifests` is the difference between a validated declaration and a
  control plane being installed on the next sync. It does **not** gate
  validation.
- `controlPlane` — `"crossplane"`. An enum with one member on purpose: a
  second control plane is then an *addition*, and every consumer branching
  on `controlPlane == "crossplane"` keeps saying what it already said. A
  boolean would make the second one a rewrite of every condition. Adding a
  member without a renderer fails the build with a message naming what is
  missing.
- `version` — the pinned control-plane release. No default. Asserted to be a
  concrete three-component version.
- `chartVersion` (default `null` = same as `version`) — exists because that
  lockstep is a convention rather than a guarantee, and when it breaks the
  chart installs one application version while the declaration says another.
- `chartRepository` — override for a mirror or a vendored chart. Must not be
  repointed at a rolling channel: that reintroduces the unpinned upgrade
  `version` exists to prevent, through a field nobody thinks of as a version.
- `namespace` (default `"crossplane-system"`) — defaulted, unusually for
  this family, because every third-party doc and every pasted `kubectl`
  example assumes it. Not a default for where credentials live.
- `providers.<name>.package` — the package reference **without** a tag or
  digest.
- `providers.<name>.version` — the exact release. A well-shaped version
  string is not a version that *exists*: no registry can be consulted at
  eval time.
- `providers.<name>.providerConfigApiVersion` — `group/version` of that
  provider's own ProviderConfig kind. The one field nixiac genuinely cannot
  derive.
- `providers.<name>.providerConfigName` (default: the attribute name) — the
  exact string a resource's `spec.providerConfigRef.name` must match. Wrong
  means the resource never reconciles: no apply error, no status.
- `providers.<name>.providerConfigNamespace` (default `null`) — for the
  namespaced ProviderConfig form, where a provider serves one.
- `providers.<name>.providerConfigSpec` — extra `spec` keys for
  provider-specific scoping. A deliberate hole: nixiac knows no provider's
  schema, and every value that belongs here is a consumer value.
- `providers.<name>.credentialsSecret.{name,namespace,key}` — a reference,
  all three required, none defaulted.
- `defaults.managementPolicies`, `defaults.deletionPolicy`,
  `defaults.acknowledgeDangerousDefaults` — see
  [The inverted defaults](#the-inverted-defaults).
- `helmRelease` — read-only, derived: `chart`, `repository`, `version`,
  `namespace`, `values`. It exists rather than leaving a consumer to retype
  four strings because of `values`: enabling `activation` **must** disable
  the chart's own permissive default activations, and a footprint discipline
  that depends on two independently maintained declarations agreeing is one
  that will stop being true.

`nixiac.activation.*` (`modules/activation.nix`):

- `enable` (default `false`) — the default is not a judgement that footprint
  does not matter; it is that the mechanism is **alpha** upstream, and a
  repo cannot sign a consumer up for that.
- `policyName` (default `"nixiac"`) — deliberately not `"default"`: that
  name belongs to the chart's own permissive policy, and colliding with it
  makes sync order decide which one wins.
- `apiVersion` — an option rather than a constant, because an alpha group
  moving is the expected course of events, not a surprise.
- `activate` — the resource types allowed to materialise real CRDs.
- `acknowledgeWildcardActivation` — the written reason `[ "*" ]` requires.

`nixiac.manifests` (`modules/manifests.nix`) — the output attrset. Writable,
so a consumer can add its own objects and hand one attrset to one renderer;
every entry is asserted addressable regardless of who added it.

`lib.mkManagedResource` (`lib/managed-resource.nix`) — `apiVersion`, `kind`,
`name`, `scope` (`"namespaced"` | `"cluster"`), `namespace`, `externalName`
(required, never defaulted), `forProvider`, `initProvider`,
`providerConfigRef`, `managementPolicies`, `deletionPolicy`,
`acknowledgeDangerous`, `labels`, `annotations`.

`lib.managementActions` — the vocabulary table: the accepted enum, the
intent-required subset, and the plausible-but-rejected names with what to
write instead.

## Checking upstream before you pin

nixiac accepts any well-shaped version string; no registry can be consulted
at eval time. Two things are worth confirming by hand, and the second one is
not hypothetical:

1. **Monolithic provider packages are gone**, not merely discouraged.
   Support for them ended 2024-06-12. For the large clouds the installable
   form is a `provider-family-<cloud>` base package (which owns the shared
   ProviderConfig type) plus one package per service group. That split
   exists because a single monolithic provider installed more than 900 CRDs
   by itself.
2. **A named successor is not a published one.** Verified 2026-07-30: a
   provider repository that an *archived* provider's own README names as its
   official replacement had, five months on, zero git tags, zero releases,
   and no package published under any registry — while still taking
   dependency-bump commits. A populated source tree is not a version you can
   pin. `gh api repos/<org>/<repo>/releases` settles it in one call.

A vocabulary note worth getting right in a declaration that outlives its
author: since early 2025, **"Official Provider"** refers specifically to a
paid-subscription build under one vendor's registry namespace. The freely
published build of the *same source* under the community organisation's
namespace is, in that vendor's current wording, a **"Community Provider"** —
same maintainers, same quality bar, no subscription. Do not call either one
"official" in a comment; the word now means something specific and something
else.

## Repository layout

| Path | What |
|---|---|
| `flake.nix` | `nixosModules.{controlPlane,activation,manifests,default}`, the same three under `modules.*`, `lib.mkManagedResource`, `lib.managementActions` |
| `modules/control-plane.nix` | which control plane, which version, which providers, which credential references, and the inverted defaults |
| `modules/activation.nix` | the CRD footprint budget (alpha upstream), and the Helm values that make it take effect |
| `modules/manifests.nix` | the single plain-data output surface both modules write into |
| `lib/managed-resource.nix` | the Nix → Crossplane-CR rendering shape, with the inverted defaults stamped on |
| `lib/management-actions.nix` | the vocabulary table: accepted enum, intent-required subset, rejected names with reasons |
| `examples/control-plane/` | a minimal composed system exercising every implemented option, used by `nix flake check` |
| `checks/` | every assertion proven in both directions, plus a mechanical purity proof (via nixtest's shared fixture) with meta-tests |
| `docs/design.md` | the reasoning settled well enough to state as a decision |
| `experiments/` | open questions and unmeasured defaults |
| `studies/` | write-ups, including the CRD-footprint measurements |
| `LICENSE` | MIT |

## Status

**Pre-alpha, and honest about which parts have run.** All three modules and
both lib functions are real and checked in: schema, eval-time assertions,
and plain-data rendering, with 169 eval-time checks covering every assertion
in both directions plus a mechanical purity proof.

What has **not** happened yet, stated plainly rather than glossed over:

- **No manifest this repo rendered has been applied to a real cluster.**
  Every claim about what the API server accepts comes from upstream source,
  upstream documentation, or a survey — not from this repo having run.
- **`spec.initProvider` on an adopted resource is UNVERIFIED.** It is the
  only `ignore_changes` analogue available, and its own generated
  documentation says those values merge "when the resource is created" — but
  a resource nixiac adopts is never created by Crossplane. `mkManagedResource`
  renders it as given and does not pretend to a guard it has not measured.
  See `experiments/README.md` #002.
- **Credentials are Secret-sourced only.** Providers on some clouds can take
  an injected workload identity and need no Secret at all, which
  `credentialsSecret`'s shape cannot express. Tracked as
  `experiments/README.md` #001 rather than papered over with a nullable
  field that would also weaken the "a provider must say where its
  credentials come from" assertion.
- **The activation mechanism is alpha upstream.** Its API group is expected
  to move; `nixiac.activation.apiVersion` exists so a consumer can correct
  that in one place without waiting on this repo.

- [x] `nixosModules.controlPlane`
- [x] `nixosModules.activation`
- [x] `nixosModules.manifests`
- [x] `lib.mkManagedResource`
- [x] `lib.managementActions`
- [ ] a rendered manifest applied to a real cluster, and the round trip written up in `studies/`
- [ ] `initProvider` on an adopted resource, measured either way

## Related projects

`nixiac` is one of several small, independently-usable open-source projects
sharing a common design system. It takes **no flake input on any product
repo in the family** — a control plane is something a consumer composes
*alongside* its cluster and its workloads, not something that depends on
them, and an input here would make the composition order a fact about this
repo rather than about the consumer. (It does take `nixtest` as an input —
a lib-only test fixture, not a product; see "Why the control plane belongs
in Nix" above.)

- [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) — the cluster
  this control plane runs *on*: bare-metal k3s on NixOS with a declarative
  GitOps spine, nixidy rendering and Argo CD reconciling. nixiac assumes a
  Kubernetes API server exists and has no opinion on how it got there; the
  seam between them is that a renderer of the kind nixk3s already runs is
  exactly what `nixiac.manifests` is shaped for.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — the
  workloads *beside* it: a cookbook of ordinary self-hosted applications as
  typed Nix, rendered to Argo CD manifests. A control plane is not an
  application platform, and neither repo needs to know the other exists.
- [nixstorage](https://github.com/julian-corbet/nixstorage-corbet-ch) — a
  sibling in shape rather than in subject: the same "hard-won rules as
  enforced modules, not documentation to remember" discipline, applied to a
  ZFS storage substrate. Its disk table is where this repo's
  duplicate-package check (and the `deepSeq` forcing gotcha underneath it)
  comes from.

Use any of them together or standalone.

## License

MIT.
