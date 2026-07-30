# checks/activation.nix
#
# The `nixiac.activation` check group -- every assertion in modules/activation.nix proven in both
# directions, plus the one cross-module invariant this repo has: enabling the footprint budget must
# change `nixiac.helmRelease.values`, because a narrow activation policy applied alongside the
# chart's own permissive one is additive and silently does nothing.
#
# ⚠ THE THREE-STATE PROOF IS THE POINT OF THIS FILE, not the assertions. `modules/control-plane.nix`
# reads `config.nixiac.activation.enable or false` -- the family's house rule for reading a sibling
# option, and the family's known hazard, because `or false` cannot distinguish "the module was never
# imported" from "the module is imported and disabled". nixstorage paid for exactly that gap once:
# consumers reading `config.nixstorage.layout.images or { }` across an option-path rename resolved to
# `{ }` silently for the entire life of the rename, because a defensive read cannot fail loudly. So
# the Helm values are checked in all three states -- module absent, module present and disabled,
# module present and enabled -- rather than in the one state that happens to be convenient.
{ lib, nixpkgs, system, controlPlaneModule, activationModule, bareStubs }:

let
  evalWith = modules: extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = modules ++ [ extraConfig bareStubs ];
    }).config;

  evalBoth = evalWith [ controlPlaneModule activationModule ];
  evalActivationOnly = evalWith [ activationModule ];
  evalControlPlaneOnly = evalWith [ controlPlaneModule ];

  bothBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalBoth extraConfig).system.build.toplevel true)).success;

  activationOnlyBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalActivationOnly extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A complete, valid control plane, so that the activation fixtures below are exercised in the
  # composition a consumer actually uses rather than in isolation only.
  validControlPlane = {
    nixiac = {
      enable = true;
      version = "v2.3.4";
      providers.example = {
        package = "xpkg.crossplane.io/example-org/provider-example";
        version = "v1.0.0";
        providerConfigApiVersion = "example.crossplane.io/v1beta1";
        credentialsSecret = { name = "example-credentials"; namespace = "crossplane-system"; key = "credentials"; };
      };
    };
  };

  narrowActivation = {
    nixiac.activation = {
      enable = true;
      activate = [ "examples.example.crossplane.io" ];
    };
  };

  valid = lib.recursiveUpdate validControlPlane narrowActivation;

  cfg-valid = evalBoth valid;
  cfg-activation-disabled = evalBoth validControlPlane;
  cfg-activation-module-absent = evalControlPlaneOnly validControlPlane;

in
{
  results = [
    (check "act/valid-declaration-builds-fine"
      (!(bothBuildFails valid))
      "the base valid control-plane-plus-activation declaration should never fail the build on its own")

    # ── activate must not be empty when the mechanism is on ─────────────────────────────────────
    (check "act/enabled-with-empty-activate-fails-the-build"
      (bothBuildFails (lib.recursiveUpdate validControlPlane { nixiac.activation.enable = true; }))
      "expected activation.enable = true with an empty activate list to fail the build, but it succeeded -- with the chart's permissive policy disabled, NO managed resource type gets a CRD and every CR is rejected as an unknown kind while the control plane looks healthy")

    (check "act/enabled-with-narrow-activate-builds-fine"
      (!(bothBuildFails valid))
      "a narrow activate list is the intended use and must not fail the build")

    (check "act/blank-activate-entry-fails-the-build"
      (bothBuildFails (lib.recursiveUpdate valid { nixiac.activation.activate = [ "examples.example.crossplane.io" "  " ]; }))
      "expected a whitespace-only activate entry to fail the build, but it succeeded -- an empty selector matches no type, so it is a type someone believed they activated")

    # ── the wildcard gate ────────────────────────────────────────────────────────────────────────
    (check "act/wildcard-without-acknowledgement-fails-the-build"
      (bothBuildFails (lib.recursiveUpdate valid { nixiac.activation.activate = [ "*" ]; }))
      "expected activate = [ \"*\" ] without an acknowledgement to fail the build, but it succeeded -- it reproduces exactly the full CRD footprint this module exists to avoid while reading as though the footprint were managed")

    (check "act/wildcard-with-acknowledgement-builds-fine"
      (
        !(bothBuildFails (lib.recursiveUpdate valid {
          nixiac.activation = {
            activate = [ "*" ];
            acknowledgeWildcardActivation = "Throwaway cluster; API server memory is not a constraint here.";
          };
        }))
      )
      "a written reason must actually unlock the wildcard -- a gate that cannot be opened is a prohibition, not a gate")

    (check "act/blank-wildcard-acknowledgement-does-not-unlock"
      (bothBuildFails (lib.recursiveUpdate valid {
        nixiac.activation = {
          activate = [ "*" ];
          acknowledgeWildcardActivation = "";
        };
      }))
      "expected an empty acknowledgement to still fail the build, but it succeeded -- the gate checks for content, not presence")

    (check "act/narrow-list-needs-no-acknowledgement"
      (!(bothBuildFails valid))
      "a narrow activate list must never require an acknowledgement -- if it does, the gate is inverted")

    # ── declared but disabled is still validated ─────────────────────────────────────────────────
    (check "act/declared-while-disabled-still-validates"
      (bothBuildFails (lib.recursiveUpdate validControlPlane {
        nixiac.activation = { enable = false; activate = [ "*" ]; };
      }))
      "an unacknowledged wildcard must fail the build even with activation.enable = false -- a declaration that gets the data and none of the safety is the wrong thing to teach")

    # ── rendering ────────────────────────────────────────────────────────────────────────────────
    (check "act/disabled-renders-no-policy"
      (!(lib.any (n: lib.hasPrefix "activationpolicy-" n) (lib.attrNames cfg-activation-disabled.nixiac.manifests)))
      "activation.enable defaults to false and must render no activation policy, got ${builtins.toJSON (lib.attrNames cfg-activation-disabled.nixiac.manifests)}")

    (check "act/enabled-renders-exactly-one-policy"
      (lib.length (lib.filter (n: lib.hasPrefix "activationpolicy-" n) (lib.attrNames cfg-valid.nixiac.manifests)) == 1)
      "expected exactly one rendered activation policy, got ${builtins.toJSON (lib.attrNames cfg-valid.nixiac.manifests)}")

    (check "act/policy-carries-the-declared-activate-list"
      (cfg-valid.nixiac.manifests."activationpolicy-nixiac".spec.activate == [ "examples.example.crossplane.io" ])
      "the rendered policy must carry the declared activate list verbatim, got ${builtins.toJSON cfg-valid.nixiac.manifests."activationpolicy-nixiac".spec.activate}")

    (check "act/default-policy-name-is-not-default"
      (cfg-valid.nixiac.activation.policyName != "default")
      "the default policyName must NOT be \"default\" -- that name belongs to the chart's own permissive policy, and colliding with it makes sync order decide which one wins")

    (check "act/declared-apiVersion-reaches-the-object"
      ((evalBoth (lib.recursiveUpdate valid { nixiac.activation.apiVersion = "apiextensions.crossplane.io/v1beta1"; })).nixiac.manifests."activationpolicy-nixiac".apiVersion == "apiextensions.crossplane.io/v1beta1")
      "the apiVersion override must reach the rendered object -- an alpha API group moving is the expected course of events, not a surprise")

    # ── the cross-module invariant, in all THREE states ──────────────────────────────────────────
    # See this file's header for why three and not two: `or false` cannot tell "absent" from
    # "false", and the failure mode of trusting it is silent.
    (check "act/enabled-disables-the-charts-default-activations"
      (cfg-valid.nixiac.helmRelease.values.provider.defaultActivations == [ ])
      "enabling activation MUST set helmRelease.values.provider.defaultActivations = [ ] -- without it the chart's own permissive policy stays in place, a narrow policy adds nothing, and the whole mechanism silently does nothing while appearing configured")

    (check "act/disabled-leaves-helm-values-alone"
      (cfg-activation-disabled.nixiac.helmRelease.values == { })
      "with activation disabled, nixiac must not touch the chart's activation values -- got ${builtins.toJSON cfg-activation-disabled.nixiac.helmRelease.values}")

    (check "act/absent-module-leaves-helm-values-alone"
      (cfg-activation-module-absent.nixiac.helmRelease.values == { })
      "with the activation module never imported, the defensive read in modules/control-plane.nix must resolve to \"disabled\" and touch nothing -- got ${builtins.toJSON cfg-activation-module-absent.nixiac.helmRelease.values}")

    (check "act/control-plane-module-alone-still-evaluates"
      (builtins.tryEval (builtins.seq (evalControlPlaneOnly validControlPlane).system.build.toplevel true)).success
      "the control-plane module must evaluate with no activation module present at all -- it is exported standalone, and a defensive read that only works when the sibling is there is not defensive")

    # ── the activation module standing entirely alone ────────────────────────────────────────────
    # Proves the shared `nixiac.manifests` declaration in modules/manifests.nix works from either
    # side: a consumer that imports only the footprint budget gets a working output surface and
    # working assertions, with no control-plane declaration anywhere in the evaluation.
    (check "act/activation-module-alone-validates"
      (activationOnlyBuildFails { nixiac.activation = { enable = true; activate = [ "*" ]; }; })
      "expected an unacknowledged wildcard to fail the build with only the activation module imported, but it succeeded")

    (check "act/activation-module-alone-renders"
      ((evalActivationOnly narrowActivation).nixiac.manifests
        ? "activationpolicy-nixiac")
      "the activation module must render its policy with no control-plane module present -- both modules import modules/manifests.nix precisely so neither needs to know whether the other is there")

    (check "act/activation-module-alone-declares-nothing-else"
      (lib.attrNames (evalActivationOnly narrowActivation).nixiac.manifests == [ "activationpolicy-nixiac" ])
      "the activation module alone must render exactly its own object, got ${builtins.toJSON (lib.attrNames (evalActivationOnly narrowActivation).nixiac.manifests)}")
  ];
}
