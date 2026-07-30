# checks/control-plane.nix
#
# The `nixiac` control-plane check group: every assertion in modules/control-plane.nix proven in
# BOTH directions -- it fires on the violation, and it stays silent on the nearest thing that is not
# one. A guard that has only ever been shown to reject something is half a guard: an assertion with
# an inverted condition, or one that rejects everything, passes the first half of that pair and
# breaks every legitimate declaration.
#
# Every check is eval-time. There is nothing to build here and nothing to boot: these modules render
# plain data, so "did it validate" and "did it render the right object" are both properties of an
# evaluation. Wired into checks/default.nix as one `results` list, the same shape the other check
# groups in this directory use.
#
# ⚠ WHY EVERY FIXTURE COMPOSES THROUGH NixOS's OWN eval-config.nix, when nixiac needs no host.
# NixOS enforces `config.assertions` when `system.build.toplevel` is forced; a bare read of
# `config.assertions` is a passive list that no evaluator has to act on. Composing through
# eval-config.nix is therefore the cheapest way to get an assertion to actually FAIL, which is the
# thing under test. It is not a claim that nixiac needs a host -- see checks/purity.nix, which
# proves the opposite about the same modules.
{ lib, nixpkgs, system, controlPlaneModule, bareStubs }:

let
  evalCP = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [ controlPlaneModule extraConfig bareStubs ];
    }).config;

  # `seq` reaches the assertion-wrapping throw without deep-forcing the whole system closure --
  # same reasoning as every sibling project's own `buildFails` in this family.
  buildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalCP extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # ── The base valid declaration every "and one thing about it is wrong" fixture mutates ────────
  # One provider, complete and pinned, safe defaults untouched. Placeholder values throughout: a
  # real package reference in a public repo's own test fixtures is the same leak as one in an
  # example.
  validProvider = {
    package = "xpkg.crossplane.io/example-org/provider-example";
    version = "v1.0.0";
    providerConfigApiVersion = "example.crossplane.io/v1beta1";
    credentialsSecret = { name = "example-credentials"; namespace = "crossplane-system"; key = "credentials"; };
  };

  # A whole provider table, built from scratch. ⚠ NOT expressible with `with'` below: `recursiveUpdate`
  # MERGES, so `with' [ "nixiac" "providers" ] { ... }` keeps the base fixture's own provider
  # alongside the new ones, and `removeAttrs` on a provider hands back an attrset whose missing field
  # is then re-supplied by the merge. Both mistakes were made writing this file, and both produced
  # checks that PASSED while testing something other than what they claimed -- the duplicate-package
  # fixture passed because the merge had silently created a third provider.
  withProviders = providers: {
    nixiac = { enable = true; version = "v2.3.4"; inherit providers; };
  };

  valid = withProviders { example = validProvider; };

  # Mutate exactly one SCALAR field of the base fixture, so a failing check isolates one cause. Only
  # safe for overwriting a leaf; use `withProviders` for anything that needs a field to be ABSENT.
  with' = path: value: lib.recursiveUpdate valid (lib.setAttrByPath path value);

  cfg-valid = evalCP valid;
  cfg-disabled = evalCP (with' [ "nixiac" "enable" ] false);

in
{
  results = [
    # ── The base fixture itself must be clean, or every negative check below is meaningless ─────
    (check "cp/valid-declaration-builds-fine"
      (!(buildFails valid))
      "the base valid control-plane declaration should never fail the build on its own -- if it does, every negative check in this group is proving nothing")

    # ── version: required, and pinned ───────────────────────────────────────────────────────────
    (check "cp/version-unset-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] null))
      "expected an unset nixiac.version to fail the build, but it succeeded")

    (check "cp/version-latest-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] "latest"))
      "expected nixiac.version = \"latest\" to fail the build, but it succeeded -- an unpinned control plane upgrades itself between two reconciles, under resources already in production")

    (check "cp/version-branch-name-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] "main"))
      "expected a branch name as nixiac.version to fail the build, but it succeeded")

    (check "cp/version-bare-major-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] "v2"))
      "expected a bare major version to fail the build, but it succeeded -- \"v2\" resolves to a different artifact every release")

    (check "cp/version-bare-major-minor-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] "v2.3"))
      "expected a bare major.minor version to fail the build, but it succeeded")

    (check "cp/version-empty-string-fails-the-build"
      (buildFails (with' [ "nixiac" "version" ] ""))
      "expected an empty nixiac.version to fail the build, but it succeeded")

    # The other direction, three shapes wide: a pin must not be rejected for being spelled
    # differently. A guard that only accepts one cosmetic form of a correct answer is a guard that
    # will be worked around.
    (check "cp/version-v-prefixed-semver-builds-fine"
      (!(buildFails (with' [ "nixiac" "version" ] "v2.3.4")))
      "\"v2.3.4\" is a pinned release and must not fail the build")

    (check "cp/version-bare-semver-builds-fine"
      (!(buildFails (with' [ "nixiac" "version" ] "2.3.4")))
      "\"2.3.4\" is a pinned release and must not fail the build")

    (check "cp/version-prerelease-semver-builds-fine"
      (!(buildFails (with' [ "nixiac" "version" ] "v2.3.4-rc.1")))
      "\"v2.3.4-rc.1\" is a pinned release and must not fail the build")

    # ── chartVersion: same rule, separate field ─────────────────────────────────────────────────
    (check "cp/chartVersion-latest-fails-the-build"
      (buildFails (with' [ "nixiac" "chartVersion" ] "latest"))
      "expected nixiac.chartVersion = \"latest\" to fail the build, but it succeeded -- a moving chart version installs a moving application version")

    (check "cp/chartVersion-null-builds-fine"
      (!(buildFails (with' [ "nixiac" "chartVersion" ] null)))
      "chartVersion = null means \"same as version\" and must not fail the build")

    (check "cp/chartVersion-pinned-builds-fine"
      (!(buildFails (with' [ "nixiac" "chartVersion" ] "v2.3.5")))
      "a pinned chartVersion that differs from version is legitimate and must not fail the build")

    (check "cp/chartVersion-null-derives-version-in-helmRelease"
      (cfg-valid.nixiac.helmRelease.version == "v2.3.4")
      "helmRelease.version should fall back to nixiac.version when chartVersion is null, got \"${toString cfg-valid.nixiac.helmRelease.version}\"")

    (check "cp/explicit-chartVersion-wins-in-helmRelease"
      ((evalCP (with' [ "nixiac" "chartVersion" ] "v2.3.5")).nixiac.helmRelease.version == "v2.3.5")
      "an explicit chartVersion must override the derived default -- changing a DEFAULT must never remove the ability to state the value directly")

    # ── providers.<name>.credentialsSecret: required, and complete ───────────────────────────────
    (check "cp/provider-without-credentialsSecret-fails-the-build"
      (buildFails (withProviders { example = removeAttrs validProvider [ "credentialsSecret" ]; }))
      "expected a provider with no credentialsSecret to fail the build, but it succeeded -- a ProviderConfig with no credentials applies cleanly and fails at reconcile time, in a controller log nobody is reading")

    (check "cp/provider-with-credentialsSecret-builds-fine"
      (!(buildFails valid))
      "a provider with a complete credentialsSecret must not fail the build")

    (check "cp/credentialsSecret-blank-name-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "credentialsSecret" "name" ] ""))
      "expected a blank Secret name to fail the build, but it succeeded -- a partial reference renders a ProviderConfig that looks wired up and resolves to nothing")

    (check "cp/credentialsSecret-blank-namespace-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "credentialsSecret" "namespace" ] "   "))
      "expected a whitespace-only Secret namespace to fail the build, but it succeeded")

    (check "cp/credentialsSecret-missing-key-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "credentialsSecret" "key" ] null))
      "expected an unset Secret key to fail the build, but it succeeded -- Secrets routinely hold several keys and the wrong one is a silent auth failure")

    # ── providers: one package, one name ─────────────────────────────────────────────────────────
    (check "cp/duplicate-package-fails-the-build"
      (buildFails (withProviders {
        a = validProvider;
        b = validProvider // { version = "v1.0.1"; };
      }))
      "expected two providers declaring the same package to fail the build, but it succeeded -- two Provider objects race to install the same controller, and both declarations read as though they were honoured")

    (check "cp/distinct-packages-build-fine"
      (
        !(buildFails (withProviders {
          a = validProvider;
          b = validProvider // { package = "xpkg.crossplane.io/example-org/provider-example-other"; };
        }))
      )
      "two providers naming two different packages should never fail the build -- a family base package and its service packages are exactly this shape")

    # The single-entry forcing gotcha, made a check rather than left as a comment: with one
    # provider, `lib.unique`'s fold never compares the only element against anything, so without
    # `deepSeq` the duplicate check would never force `package` at all. This fixture has ONE
    # provider whose package is malformed -- if the type/assertion is only reached via the
    # duplicate comparison, this passes silently.
    (check "cp/single-provider-package-is-still-checked"
      (buildFails (withProviders {
        only = validProvider // { package = "xpkg.crossplane.io/example-org/provider-example:v1.0.0"; };
      }))
      "a LONE provider's package must still be validated -- if this passed, the duplicate-package fold is silently never forcing the only element it has")

    # ── providers.<name>.package: no embedded tag ────────────────────────────────────────────────
    (check "cp/package-with-tag-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "package" ] "xpkg.crossplane.io/example-org/provider-example:v1.0.0"))
      "expected a package carrying its own :tag to fail the build, but it succeeded -- the copy inside the string is the one the cluster obeys, the one in `version` is the one a human reads")

    (check "cp/package-with-digest-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "package" ] "xpkg.crossplane.io/example-org/provider-example@sha256:0123456789abcdef"))
      "expected a package carrying its own @digest to fail the build, but it succeeded")

    (check "cp/package-unset-fails-the-build"
      (buildFails (withProviders { example = removeAttrs validProvider [ "package" ]; }))
      "expected a provider with no package to fail the build, but it succeeded -- a Provider object with nothing to install applies cleanly and then does nothing, which looks like \"still starting\"")

    # The other direction, and specifically the case a naive tag check gets wrong: a registry host
    # with a port. `registry.example:5000/org/pkg` has a colon and no tag.
    (check "cp/registry-host-with-port-builds-fine"
      (!(buildFails (with' [ "nixiac" "providers" "example" "package" ] "registry.example:5000/example-org/provider-example")))
      "a registry host with a port is not a tag -- rejecting it would make a private/mirrored registry undeclarable")

    # ── providers.<name>.version ─────────────────────────────────────────────────────────────────
    (check "cp/provider-version-latest-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "version" ] "latest"))
      "expected a provider version of \"latest\" to fail the build, but it succeeded")

    (check "cp/provider-version-unset-fails-the-build"
      (buildFails (withProviders { example = removeAttrs validProvider [ "version" ]; }))
      "expected a provider with no version to fail the build, but it succeeded")

    (check "cp/provider-version-pinned-builds-fine"
      (!(buildFails (with' [ "nixiac" "providers" "example" "version" ] "v2.6.0")))
      "a pinned provider version must not fail the build")

    # ── providers.<name>.providerConfigApiVersion ────────────────────────────────────────────────
    (check "cp/providerConfigApiVersion-unset-fails-the-build"
      (buildFails (withProviders { example = removeAttrs validProvider [ "providerConfigApiVersion" ]; }))
      "expected an unset providerConfigApiVersion to fail the build, but it succeeded -- nixiac cannot derive a group each provider chooses for itself, and a guess renders an unknown kind")

    (check "cp/providerConfigApiVersion-without-version-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "providerConfigApiVersion" ] "example.crossplane.io"))
      "expected a group with no version to fail the build, but it succeeded")

    (check "cp/providerConfigApiVersion-with-empty-half-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "providerConfigApiVersion" ] "example.crossplane.io/"))
      "expected a trailing-slash apiVersion to fail the build, but it succeeded")

    (check "cp/providerConfigApiVersion-group-slash-version-builds-fine"
      (!(buildFails (with' [ "nixiac" "providers" "example" "providerConfigApiVersion" ] "example.crossplane.io/v1alpha1")))
      "a well-formed group/version must not fail the build")

    # ── providerConfigSpec must not shadow the credentials nixiac renders ───────────────────────
    (check "cp/providerConfigSpec-credentials-fails-the-build"
      (buildFails (with' [ "nixiac" "providers" "example" "providerConfigSpec" ] { credentials = { source = "InjectedIdentity"; }; }))
      "expected providerConfigSpec.credentials to fail the build, but it succeeded -- one of the two definitions would win silently, and the guarantee that credentials are references is checked against the other one")

    (check "cp/providerConfigSpec-other-keys-build-fine"
      (!(buildFails (with' [ "nixiac" "providers" "example" "providerConfigSpec" ] { projectID = "a-consumer-specific-identifier"; })))
      "provider-specific scoping fields are exactly what providerConfigSpec is for and must not fail the build")

    # ── defaults.managementPolicies: the load-bearing inversion ──────────────────────────────────
    (check "cp/safe-default-managementPolicies-needs-no-acknowledgement"
      (!(buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ "Observe" ])))
      "the safe default [ \"Observe\" ] must never require an acknowledgement -- if it does, the gate is inverted")

    (check "cp/default-managementPolicies-is-observe-only"
      (cfg-valid.nixiac.defaults.managementPolicies == [ "Observe" ])
      "nixiac's default managementPolicies must be [ \"Observe\" ], not Crossplane's own [ \"*\" ] -- got ${builtins.toJSON cfg-valid.nixiac.defaults.managementPolicies}")

    (check "cp/empty-managementPolicies-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ ]))
      "expected an empty managementPolicies to fail the build, but it succeeded -- not even Observe applies, so the resource reads nothing and is indistinguishable from a typo")

    (check "cp/wildcard-without-acknowledgement-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ "*" ]))
      "expected [ \"*\" ] without an acknowledgement to fail the build, but it succeeded -- \"*\" is Crossplane's own default and converges live resources to a hand-transcribed spec on the next reconcile")

    (check "cp/update-without-acknowledgement-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ "Observe" "Update" ]))
      "expected Update without an acknowledgement to fail the build, but it succeeded")

    (check "cp/lateInitialize-without-acknowledgement-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ "Observe" "LateInitialize" ]))
      "expected LateInitialize without an acknowledgement to fail the build, but it succeeded -- it changes nothing in the cloud and destroys the evidence an adoption gate depends on, which is why it is gated alongside Delete")

    (check "cp/dangerous-managementPolicies-with-acknowledgement-builds-fine"
      (
        !(buildFails (lib.recursiveUpdate valid {
          nixiac.defaults = {
            managementPolicies = [ "Observe" "Create" "Update" ];
            acknowledgeDangerousDefaults = "This control plane created every resource it renders; nothing here pre-existed it.";
          };
        }))
      )
      "a written reason must actually unlock the dangerous default -- a gate that cannot be opened is not a gate, it is a prohibition wearing one's clothes")

    (check "cp/blank-acknowledgement-does-not-unlock"
      (buildFails (lib.recursiveUpdate valid {
        nixiac.defaults = {
          managementPolicies = [ "Observe" "Delete" ];
          acknowledgeDangerousDefaults = "   ";
        };
      }))
      "expected a whitespace-only acknowledgement to still fail the build, but it succeeded -- the gate checks for CONTENT, not for presence, or it becomes a field people put a space in")

    (check "cp/illegal-managementPolicy-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "managementPolicies" ] [ "Orphan" ]))
      "expected \"Orphan\" -- a legal deletionPolicy value that is NOT a management action -- to fail the build, but it succeeded. The API server rejects it at apply time, in a controller log, while whoever wrote it believes they asked for \"manage everything except deletion\"")

    (check "cp/illegal-managementPolicy-fails-even-when-acknowledged"
      (buildFails (lib.recursiveUpdate valid {
        nixiac.defaults = {
          managementPolicies = [ "MustCreate" ];
          acknowledgeDangerousDefaults = "A reason cannot make an invalid enum member valid.";
        };
      }))
      "an acknowledgement must not launder an illegal action name -- the intent gate and the vocabulary check are separate guards and must stay separate")

    # ── defaults.deletionPolicy ───────────────────────────────────────────────────────────────────
    (check "cp/default-deletionPolicy-is-orphan"
      (cfg-valid.nixiac.defaults.deletionPolicy == "Orphan")
      "nixiac's default deletionPolicy must be \"Orphan\", not Crossplane's own \"Delete\" -- got \"${cfg-valid.nixiac.defaults.deletionPolicy}\"")

    (check "cp/safe-deletionPolicy-needs-no-acknowledgement"
      (!(buildFails (with' [ "nixiac" "defaults" "deletionPolicy" ] "Orphan")))
      "the safe default \"Orphan\" must never require an acknowledgement")

    (check "cp/deletionPolicy-delete-without-acknowledgement-fails-the-build"
      (buildFails (with' [ "nixiac" "defaults" "deletionPolicy" ] "Delete"))
      "expected deletionPolicy = \"Delete\" without an acknowledgement to fail the build, but it succeeded -- a rename, a refactor, a moved file or a GitOps prune then destroys production infrastructure")

    (check "cp/deletionPolicy-delete-with-acknowledgement-builds-fine"
      (
        !(buildFails (lib.recursiveUpdate valid {
          nixiac.defaults = {
            deletionPolicy = "Delete";
            acknowledgeDangerousDefaults = "Every resource this control plane renders is ephemeral and owned end to end by it.";
          };
        }))
      )
      "a written reason must actually unlock deletionPolicy = \"Delete\"")

    # ── enable: gates RENDERING, never VALIDATION ────────────────────────────────────────────────
    (check "cp/disabled-renders-nothing"
      (cfg-disabled.nixiac.manifests == { })
      "nixiac.enable = false must render no manifests at all, got ${toString (lib.length (lib.attrNames cfg-disabled.nixiac.manifests))} object(s)")

    (check "cp/disabled-still-validates"
      (buildFails (lib.recursiveUpdate valid { nixiac = { enable = false; version = "latest"; }; }))
      "an unpinned version must fail the build even with nixiac.enable = false -- a declaration that gets the data and none of the safety is the wrong thing to teach")

    (check "cp/nothing-declared-fails-nothing"
      (!(buildFails { }))
      "importing the module and declaring nothing at all must never fail a build -- otherwise nixiac cannot be composed into a system that has not adopted it yet")

    # ── Rendering: the objects, and the joins that are easy to get wrong ────────────────────────
    (check "cp/renders-one-provider-and-one-providerconfig-per-provider"
      (lib.sort (a: b: a < b) (lib.attrNames cfg-valid.nixiac.manifests)
        == [ "provider-example" "providerconfig-example" ])
      "expected exactly a Provider and a ProviderConfig for the one declared provider, got ${builtins.toJSON (lib.attrNames cfg-valid.nixiac.manifests)}")

    (check "cp/provider-package-carries-the-pinned-version"
      (cfg-valid.nixiac.manifests.provider-example.spec.package
        == "xpkg.crossplane.io/example-org/provider-example:v1.0.0")
      "the rendered Provider must join package and version as package:version, got \"${cfg-valid.nixiac.manifests.provider-example.spec.package}\"")

    (check "cp/provider-uses-the-core-crossplane-api-group"
      (cfg-valid.nixiac.manifests.provider-example.apiVersion == "pkg.crossplane.io/v1")
      "Provider is a CORE Crossplane type, so its group follows from the pinned core version and is hardcoded -- got \"${cfg-valid.nixiac.manifests.provider-example.apiVersion}\"")

    (check "cp/providerconfig-uses-the-declared-api-group"
      (cfg-valid.nixiac.manifests.providerconfig-example.apiVersion == "example.crossplane.io/v1beta1")
      "a ProviderConfig's group is the provider's own and must come from the declaration, never from a guess")

    (check "cp/providerconfig-renders-a-secret-reference-not-a-value"
      (cfg-valid.nixiac.manifests.providerconfig-example.spec.credentials == {
        source = "Secret";
        secretRef = { name = "example-credentials"; namespace = "crossplane-system"; key = "credentials"; };
      })
      "the rendered ProviderConfig must carry a name/namespace/key REFERENCE and nothing else, got ${builtins.toJSON cfg-valid.nixiac.manifests.providerconfig-example.spec.credentials}")

    (check "cp/providerConfigName-defaults-to-the-attribute-name"
      (cfg-valid.nixiac.manifests.providerconfig-example.metadata.name == "example")
      "providerConfigName should default to the provider's attribute name -- the one default here that is derived rather than guessed")

    (check "cp/explicit-providerConfigName-wins"
      ((evalCP (with' [ "nixiac" "providers" "example" "providerConfigName" ] "adopted-config")).nixiac.manifests.providerconfig-example.metadata.name == "adopted-config")
      "an explicit providerConfigName must override the derived default")

    (check "cp/providerconfig-is-cluster-scoped-by-default"
      (!(cfg-valid.nixiac.manifests.providerconfig-example.metadata ? namespace))
      "a ProviderConfig must carry no namespace unless one was declared -- a namespace on a cluster-scoped object records an intent that never takes effect")

    (check "cp/providerConfigNamespace-renders-when-declared"
      ((evalCP (with' [ "nixiac" "providers" "example" "providerConfigNamespace" ] "example-ns")).nixiac.manifests.providerconfig-example.metadata.namespace == "example-ns")
      "a declared providerConfigNamespace must reach the rendered object")

    (check "cp/providerConfigSpec-is-merged-into-the-rendered-spec"
      ((evalCP (with' [ "nixiac" "providers" "example" "providerConfigSpec" ] { projectID = "a-consumer-specific-identifier"; })).nixiac.manifests.providerconfig-example.spec.projectID == "a-consumer-specific-identifier")
      "provider-specific scoping fields must reach spec -- this is the hole nixiac renders and never fills")

    # ── manifests: the addressability assertion, from modules/manifests.nix ─────────────────────
    (check "cp/hand-added-object-without-kind-fails-the-build"
      (buildFails (lib.recursiveUpdate valid {
        nixiac.manifests.hand-written = { apiVersion = "example.crossplane.io/v1beta1"; metadata.name = "x"; };
      }))
      "expected a consumer-contributed object with no kind to fail the build, but it succeeded -- it would render, commit and sync cleanly and fail in a controller log")

    (check "cp/hand-added-object-without-metadata-name-fails-the-build"
      (buildFails (lib.recursiveUpdate valid {
        nixiac.manifests.hand-written = { apiVersion = "example.crossplane.io/v1beta1"; kind = "Example"; };
      }))
      "expected a consumer-contributed object with no metadata.name to fail the build, but it succeeded")

    (check "cp/hand-added-addressable-object-builds-fine"
      (
        !(buildFails (lib.recursiveUpdate valid {
          nixiac.manifests.hand-written = {
            apiVersion = "example.crossplane.io/v1beta1";
            kind = "Example";
            metadata.name = "an-example";
          };
        }))
      )
      "contributing a well-formed object to nixiac.manifests is a supported use and must not fail the build")

    # ── controlPlane: an enum, and only one member today ────────────────────────────────────────
    (check "cp/controlPlane-defaults-to-crossplane"
      (cfg-valid.nixiac.controlPlane == "crossplane")
      "nixiac.controlPlane should default to \"crossplane\", got \"${cfg-valid.nixiac.controlPlane}\"")

    (check "cp/unknown-controlPlane-fails-the-build"
      (buildFails (with' [ "nixiac" "controlPlane" ] "something-else"))
      "expected an unknown controlPlane value to fail the build, but it succeeded -- the enum is what makes a second control plane an addition rather than a rewrite of every consumer's condition")
  ];
}
