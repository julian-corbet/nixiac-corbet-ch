# checks/default.nix
#
# Wires this repo's check groups into `nix flake check`. FOUR groups, all eval-time, plus one
# composed-system evaluation:
#
#   ./control-plane.nix   -- every assertion in modules/control-plane.nix, in both directions:
#                            the version pin, the duplicate-package rule, the required credential
#                            REFERENCE, the required ProviderConfig API group, and the intent gate
#                            on both inverted defaults. Plus the rendered objects themselves.
#   ./activation.nix      -- every assertion in modules/activation.nix, in both directions, plus
#                            the one cross-module invariant (enabling the footprint budget MUST
#                            change the control plane's Helm values) checked in all THREE states of
#                            the defensive sibling read: module absent, present-and-disabled,
#                            present-and-enabled.
#   ./managed-resource.nix -- lib/mkManagedResource: the inverted defaults actually stamped, the
#                            required external name, the vocabulary check with its rejected-name
#                            hints, the intent gate, and the scope/deletionPolicy interaction that
#                            is the easiest thing in this repo to get quietly wrong.
#   nixtest.lib.mkPurityChecks -- the claim the rest of the repo rests on, proven mechanically:
#                            these modules touch no host surface, so they can be evaluated by
#                            something that is not NixOS, and the facts they publish can be read
#                            without dragging a build in behind them. Called once per module file
#                            (control-plane, activation, manifests) rather than once for the group,
#                            so each is proven pure ALONE -- including manifests.nix on its own,
#                            which is the one way this repo's own README says a consumer may
#                            legitimately import it, and which this repo's own former hand-rolled
#                            copy of this fixture never actually composed by itself at all. Every
#                            proof ships with a meta-test. See flake.nix's own `inputs` for why this
#                            is a flake input rather than another hand-derived copy.
#
# NOTHING HERE BUILDS OR BOOTS ANYTHING, and that is a property of the repo rather than a shortcut:
# nixiac renders plain data, so "did it validate" and "did it render the right object" are both
# properties of an evaluation. There is no artifact to produce and no device, host, or cluster
# anywhere in reach -- which is also why there is no build-level proof group here of the kind a repo
# that produces a real disk image needs.
#
# ⚠ EVERY ASSERTION IS PROVEN IN BOTH DIRECTIONS, and the negative half is the one that is easy to
# skip. An assertion with an inverted condition passes "it fires on the violation" and breaks every
# legitimate declaration; the fixtures that must NOT fail are what catch that. Where a check group's
# base fixture exists, its "must build fine" check is listed first on purpose: if the base fixture is
# itself broken, every negative check in that group is proving nothing, and that failure should be
# the first line of the report.
{ pkgs, lib, nixpkgs, system, nixtest, controlPlaneModule, activationModule, manifestsModule, mkManagedResource }:

let
  # Shared by every NixOS-eval fixture in this directory -- one definition, so that no check group's
  # "bare" baseline can silently drift away from the baseline the others use. In particular each
  # `nixtest.lib.mkPurityChecks` call below diffs against exactly this, and a per-call copy of it
  # would make that diff measure the copies rather than the modules.
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  controlPlaneChecks = import ./control-plane.nix {
    inherit lib nixpkgs system controlPlaneModule bareStubs;
  };

  activationChecks = import ./activation.nix {
    inherit lib nixpkgs system controlPlaneModule activationModule bareStubs;
  };

  managedResourceChecks = import ./managed-resource.nix {
    inherit lib mkManagedResource;
  };

  # ── Purity, per module file, each composed ALONE against the bare stub ──────────────────────────
  # Three separate calls rather than one call over the group: `mkPurityChecks`'s own load-bearing
  # half (the eval diff) proves a module composed BY ITSELF changes no watched host surface, and a
  # group-only proof would never actually exercise `manifestsModule` without the other two -- the
  # one composition this repo's own README promises works ("a consumer that wants only the output
  # surface can import it alone").
  controlPlanePurity = nixtest.lib.mkPurityChecks {
    inherit lib nixpkgs system bareStubs;
    label = "control-plane";
    modulePath = controlPlaneModule;
    # A realistic, non-default use of control-plane's OWN options only -- deliberately no
    # `nixiac.activation`, so this run also stands in as proof that the module's defensive read of
    # `config.nixiac.activation.enable or false` (see modules/control-plane.nix's own header) keeps
    # working with the activation module entirely absent from the composition.
    populatedConfig = {
      nixiac = {
        enable = true;
        version = "v2.3.4";
        providers.example = {
          package = "xpkg.crossplane.io/example-org/provider-example";
          version = "v1.0.0";
          providerConfigApiVersion = "example.crossplane.io/v1beta1";
          providerConfigSpec = { projectID = "a-consumer-specific-identifier"; };
          credentialsSecret = { name = "example-credentials"; namespace = "crossplane-system"; key = "credentials"; };
        };
      };
    };
    # Both facts control-plane.nix itself renders: `manifests` only once `enable` and a complete
    # provider make it render something, `helmRelease` unconditionally (see that option's own
    # header for why it has no default).
    factPaths = [ "nixiac.manifests" "nixiac.helmRelease" ];
  };

  activationPurity = nixtest.lib.mkPurityChecks {
    inherit lib nixpkgs system bareStubs;
    label = "activation";
    modulePath = activationModule;
    # activation.nix's own options only -- control-plane.nix is not part of this composition at
    # all, which is exactly the standalone-import case its own header describes.
    populatedConfig = {
      nixiac.activation = {
        enable = true;
        activate = [ "examples.example.crossplane.io" ];
      };
    };
    # `nixiac.helmRelease` is not in this list on purpose: that option is declared by
    # control-plane.nix, which this composition does not import, so it is not readable here at all.
    factPaths = [ "nixiac.manifests" ];
  };

  manifestsPurity = nixtest.lib.mkPurityChecks {
    inherit lib nixpkgs system bareStubs;
    label = "manifests";
    modulePath = manifestsModule;
    # A CONSUMER adding its own object directly -- manifests.nix's own header names this as a
    # genuinely supported use ("a consumer may add its own objects here"), and it is the only
    # non-default use this module's options admit on their own, with neither of its two real
    # callers imported.
    populatedConfig = {
      nixiac.manifests.example = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.name = "example";
      };
    };
    factPaths = [ "nixiac.manifests" ];
  };

  purityResults = controlPlanePurity ++ activationPurity ++ manifestsPurity;

  results =
    controlPlaneChecks.results
    ++ activationChecks.results
    ++ managedResourceChecks.results
    ++ purityResults;

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixiac eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
    # Depending on `passedCount` forces `results`, so the tests genuinely run under
    # `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixiac-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixiac eval tests passed"
          touch $out
        '';

  # ── the composed-example check: every implemented option, once, in one system ────────────────
  # A `lib.nixosSystem` composing both real modules against examples/control-plane/configuration.nix,
  # discarding the drvPath's string context so this EVALUATES a system rather than building one. What
  # it catches that the check groups above do not: a type error, a failed assertion, or an option
  # rename across the whole composed surface at once -- including in the example itself, which is
  # otherwise the one file in the repo that nothing would notice going stale.
  composedHost = lib.nixosSystem {
    inherit system;
    modules = [
      controlPlaneModule
      activationModule
      ../examples/control-plane/configuration.nix
    ];
  };

  modules-evaluate =
    pkgs.writeText "nixiac-example-drvpath"
      (builtins.unsafeDiscardStringContext composedHost.config.system.build.toplevel.drvPath);
in
{
  inherit eval-tests modules-evaluate;
}
