# modules/activation.nix
#
# THE CRD FOOTPRINT: which managed resource TYPES a provider is allowed to materialise real CRDs
# for. A second, finer mechanism than provider packaging, layered on top of it -- and the one that
# turns "install only the service packages you use" from good hygiene into a measured memory
# saving. Schema, assertion, and one rendered object; nothing here reaches a cluster.
#
# ── WHY THIS IS ITS OWN MODULE AND NOT A FIELD ON A PROVIDER ────────────────────────────────────
#
# Because it is a different question with a different owner. `nixiac.providers` answers "which
# controllers run" -- a property of the control plane's composition. This module answers "how much
# API-server memory is this consumer willing to spend on type definitions" -- a property of the
# CLUSTER's budget, decided by whoever owns that cluster's headroom, and legitimately different
# between two environments running the identical provider set. Lumping them into one toggle would
# force one answer for both, which is the same reason nothing in this family ships a single
# `tools.enable`: one option per tool, never a bundle.
#
# ── THE NUMBERS, BECAUSE THEY ARE THE ENTIRE ARGUMENT ───────────────────────────────────────────
#
# Two mechanisms from two eras of the project, and both still matter:
#
#   ERA 1 -- PROVIDER FAMILIES (shipped 2023-06, monolithic support ENDED 2024-06-12). A single
#   monolithic cloud provider installed more than 900 CRDs by itself, and the resulting CRD-driven
#   scale-up could leave a control plane's API unresponsive for up to an hour. The fix was splitting
#   each provider into a family base package plus one package per service group. This is not
#   optional any more: there is no monolithic package left to install for the large clouds.
#
#   ERA 2 -- THIS MODULE'S MECHANISM (Crossplane v2+, ALPHA). Each CRD costs roughly 3 MiB of API
#   server memory. One service package of a large cloud provider still installs around 200 CRDs --
#   roughly 600 MiB -- for the handful of resource types a consumer actually composes. Naming only
#   those types brought a documented case from ~200 CRDs to 3: a 99% reduction. The mechanism is that
#   since v2 a provider's CRDs arrive as INACTIVE ManagedResourceDefinitions (no real CRD, near-zero
#   cost) and a real CRD only materialises when an activation policy names that type. The transition
#   from inactive to active is one-way.
#
# So: choosing the smallest family sub-package per service is NECESSARY AND NO LONGER SUFFICIENT.
# Both mechanisms are needed, and the second is the one with the large number attached.
#
# ⚠ THE DEFAULT INSTALL CANCELS THIS MECHANISM ENTIRELY, SILENTLY. The chart's own install creates a
# permissive activation policy that activates everything. Activation policies are additive, so with
# that policy present a narrow one adds nothing and changes nothing -- full CRD count, full memory
# cost, and a declaration that reads as though the footprint were under control. The chart must be
# installed with its default activations disabled. That wiring is not left to the consumer to
# remember: enabling this module changes `nixiac.helmRelease.values` in `modules/control-plane.nix`
# so the two facts cannot disagree, and `checks/` proves the values in both states.
#
# ⚠ THIS IS AN ALPHA FEATURE. Crossplane's own documentation says it may change or be dropped at any
# time, and the API group/version below is expected to move. That risk is documented rather than
# gated behind an acknowledgement, on the principle this repo applies consistently: a written reason
# is required for things that can OVERWRITE OR DESTROY a resource that already exists. Depending on
# an alpha API can cost a migration; it cannot cost the consumer its data.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf mkMerge;

  cfg = config.nixiac.activation;

  blank = s: !(builtins.isString s) || builtins.match "[[:space:]]*" s != null;

  wildcardRequested = lib.elem "*" cfg.activate;
  acknowledged = !(blank cfg.acknowledgeWildcardActivation);
  blankEntries = lib.filter blank cfg.activate;
in
{
  imports = [ ./manifests.nix ];

  options.nixiac.activation = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Render a managed-resource activation policy into `nixiac.manifests`, and set the
        control-plane Helm values that make it take effect.

        Default false, and the default is not a judgement that the footprint does not matter -- it
        is that this mechanism is ALPHA (upstream reserves the right to change or drop it, and its
        API group is expected to move), so a repo cannot switch it on for a consumer that has not
        agreed to carry that. Leaving it off means the control plane keeps its own default
        behaviour: every managed resource type in every installed provider gets a real CRD, at
        roughly 3 MiB of API server memory each.

        Turning it on is a commitment to keep `activate` in step with what the consumer actually
        composes. A resource type that is not named here has no CRD, so applying a CR of that type
        fails as an unknown kind -- a loud, immediate, entirely recoverable failure, which is the
        right direction for this trade to fail in.
      '';
    };

    policyName = mkOption {
      type = types.str;
      default = "nixiac";
      description = ''
        `metadata.name` of the rendered activation policy.

        Deliberately NOT "default": that name belongs to the permissive policy the chart's own
        install creates, and reusing it would make this module's object and the chart's object the
        same object -- so whichever applied last would win, and which one that was would depend on
        sync ordering rather than on anything declared. Keep them distinct, and disable the chart's
        one explicitly (see `nixiac.helmRelease.values`) rather than by collision.
      '';
    };

    apiVersion = mkOption {
      type = types.str;
      default = "apiextensions.crossplane.io/v1alpha1";
      description = ''
        API group and version of the activation-policy kind.

        An option rather than a constant because the mechanism is alpha: `v1alpha1` is what the
        companion ManagedResourceDefinition type was verified at (2026-07-30), and an alpha group
        moving to `v1beta1` is the expected course of events, not a surprise. When it moves, a
        manifest still carrying the old version is rejected as an unknown kind -- at apply time,
        after it rendered and committed cleanly -- so this needs to be a value a consumer can
        correct in one place without waiting on this repo.

        Confirm what the installed control plane actually serves before trusting the default:
        `kubectl explain managedresourceactivationpolicy` names the served version.
      '';
    };

    activate = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "examples.example-cloud.crossplane.io" "objects.example-k8s.crossplane.io" ];
      description = ''
        The managed resource types allowed to materialise real CRDs, named the way the API server
        names them (`<plural>.<group>`). Anything not listed stays an inactive definition with no
        CRD and no memory cost.

        ⚠ Confirm the exact accepted selector form against the alpha version actually installed
        (`kubectl explain managedresourceactivationpolicy.spec.activate`) rather than inferring it
        from an example. This option validates that entries are non-empty and that a wildcard is
        deliberate; it cannot validate a selector against CRDs it has no access to at eval time.

        Keep this list derived from what the consumer composes, not from what a provider offers. The
        whole saving is the gap between the two: one service package of a large cloud provider ships
        on the order of 200 types, and a documented case needed 3 of them.

        `[ "*" ]` is accepted and requires `acknowledgeWildcardActivation`, because it reproduces
        exactly the behaviour this mechanism exists to avoid while looking like it is configured.
      '';
    };

    acknowledgeWildcardActivation = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Short-lived throwaway cluster; API server memory is not a constraint here.";
      description = ''
        A written reason for activating every managed resource type (`"*"` in `activate`).

        Required because `[ "*" ]` is indistinguishable, from the outside, from a considered narrow
        list: the declaration reads as though the footprint were managed and the cluster pays the
        full cost -- roughly 3 MiB of API server memory per CRD, on the order of 200 CRDs per
        service package of a large cloud provider. A sentence rather than a boolean, for the same
        reason as everywhere else in this repo: it has to be composed, it survives in the diff, and
        it is still legible to whoever inherits the declaration.
      '';
    };
  };

  config = mkMerge [
    # Validation runs for anything DECLARED, enabled or not -- same rule as the control-plane
    # module: a declaration that gets the data and none of the safety is the wrong thing to teach.
    (mkIf (cfg.enable || cfg.activate != [ ]) {
      assertions = [
        {
          assertion = !cfg.enable || cfg.activate != [ ];
          message = ''
            nixiac.activation.enable = true but nixiac.activation.activate is empty.

            An empty activate list activates nothing, and with the chart's own permissive policy
            disabled (which enabling this module does -- see nixiac.helmRelease.values) that means NO
            managed resource type has a real CRD at all. Every CR the consumer applies is then rejected
            as an unknown kind, and the control plane looks installed and healthy while managing
            nothing.

            Name the resource types this consumer actually composes, or leave
            nixiac.activation.enable = false and keep the control plane's own default behaviour.
          '';
        }

        {
          assertion = blankEntries == [ ];
          message = ''
            nixiac.activation.activate contains ${toString (lib.length blankEntries)} empty or
            whitespace-only entr(ies). An empty selector matches no resource type, so it is not a
            harmless no-op -- it is a type someone believed they had activated, and the CRs of that
            type will be rejected as an unknown kind.
          '';
        }

        {
          assertion = !wildcardRequested || acknowledged;
          message = ''
            nixiac.activation.activate contains "*" and
            nixiac.activation.acknowledgeWildcardActivation is unset.

            `"*"` activates every managed resource type in every installed provider, which is
            precisely the behaviour this module exists to avoid -- roughly 3 MiB of API server memory
            per CRD, on the order of 200 CRDs per service package of a large cloud provider, against
            a documented case that needed 3. The declaration would read as though the footprint were
            under control while the cluster paid the full cost, which is worse than not enabling this
            module at all: at least that state is honest about what it is doing.

            If a wildcard is genuinely right here -- a throwaway cluster, an environment where API
            server memory is not a constraint -- write a sentence saying so.
          '';
        }
      ];
    })

    (mkIf cfg.enable {
      nixiac.manifests."activationpolicy-${cfg.policyName}" = {
        apiVersion = cfg.apiVersion;
        kind = "ManagedResourceActivationPolicy";
        metadata.name = cfg.policyName;
        spec.activate = cfg.activate;
      };
    })
  ];
}
