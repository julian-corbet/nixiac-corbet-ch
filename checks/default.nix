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
#   ./purity.nix          -- the claim the rest of the repo rests on, proven mechanically: these
#                            modules touch no host surface, so they can be evaluated by something
#                            that is not NixOS, and the facts they publish can be read without
#                            dragging a build in behind them. Every proof there ships with a
#                            meta-test.
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
{ pkgs, lib, nixpkgs, system, controlPlaneModule, activationModule, manifestsModule, mkManagedResource }:

let
  # Shared by every NixOS-eval fixture in this directory -- one definition, so that no check group's
  # "bare" baseline can silently drift away from the baseline the others use. In particular
  # ./purity.nix's eval diff compares against exactly this, and a per-group copy of it would make
  # that diff measure the copies rather than the modules.
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

  purityChecks = import ./purity.nix {
    inherit lib nixpkgs system controlPlaneModule activationModule manifestsModule bareStubs;
  };

  results =
    controlPlaneChecks.results
    ++ activationChecks.results
    ++ managedResourceChecks.results
    ++ purityChecks.results;

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
