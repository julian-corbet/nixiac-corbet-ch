# The smallest configuration that composes all three of nixiac's modules and exercises every
# implemented option at least once, used by the `modules-evaluate` check.
#
# EVERY VALUE HERE IS A PLACEHOLDER, and that is a requirement rather than laziness. nixiac is a
# public repo: a real package reference would say which clouds a deployment runs on, a real
# ProviderConfig API group would say which providers it installs, a real project identifier would
# say which account. Mechanism is public; values are private. The one place a real, verified
# reference belongs is the README's dated table of what exists upstream -- documentation a reader
# can check, not a declaration this repo makes about anybody's infrastructure.
#
# The placeholder ProviderConfig API groups below are the sharpest illustration of the point
# `providerConfigApiVersion`'s own description makes: a ProviderConfig's group is chosen by each
# provider, not by Crossplane, so it can only be read off the installed CRDs. An example that
# guessed one would be teaching exactly the mistake the option exists to prevent.
#
# What this exercises deliberately, because each is easy to get backwards:
#   - the SAFE defaults left untouched (observe-only, orphan-on-delete), so the composed system
#     proves they need no acknowledgement -- the check that they DO require one when changed lives
#     in checks/control-plane.nix, in both directions.
#   - two providers, distinct packages, so the duplicate-package assertion is exercised as a
#     passing case and the "one family base package plus one service package" shape is visible.
#   - `providerConfigSpec` carrying a provider-specific scoping field, to show the hole nixiac
#     never fills.
#   - `providerConfigName` left at its default on one provider and set explicitly on the other.
#   - activation enabled with a NARROW list, which is also what makes
#     `nixiac.helmRelease.values.provider.defaultActivations` non-empty of meaning -- see
#     checks/activation.nix for that wiring proven in both states.
{ ... }:
{
  nixiac = {
    enable = true;

    # An enum with one member today. Stated explicitly here rather than left to the default, so
    # that the day a second control plane exists this example shows where the choice is made.
    controlPlane = "crossplane";

    # A pinned three-component release. "latest" here would fail the build -- see
    # checks/control-plane.nix, which proves that in both directions.
    version = "v2.3.4";

    # chartVersion left unset: the chart is released in lockstep with the application, so `null`
    # means "the same as `version`". The option exists because that lockstep is a convention rather
    # than a guarantee; see its own description.

    namespace = "crossplane-system";

    providers = {
      # A family BASE package: on the large clouds this is the package that owns the shared
      # ProviderConfig type, and it is installed alongside -- never instead of -- the service
      # packages actually used. Monolithic provider packages stopped being installable in 2024.
      example-cloud = {
        package = "xpkg.crossplane.io/example-org/provider-family-example-cloud";
        version = "v2.6.0";

        # A PLACEHOLDER group. Read the real one off the installed provider:
        #   kubectl get crd -o name | grep providerconfig
        providerConfigApiVersion = "example-cloud.crossplane.io/v1beta1";

        # providerConfigName left at its default (the attribute name, "example-cloud").

        # The consumer-specific scoping fields a provider requires beyond credentials. nixiac renders
        # these and holds none of them -- which project, which account, which region is exactly the
        # class of value that belongs in the private consumer that imports this module.
        providerConfigSpec = {
          projectID = "a-consumer-specific-identifier";
        };

        # A REFERENCE, never a value. All three parts required: a guessed namespace resolves
        # against wherever the control plane happens to run rather than wherever credentials are
        # actually kept, and a guessed key silently selects the wrong entry of a multi-key Secret.
        credentialsSecret = {
          name = "example-cloud-credentials";
          namespace = "crossplane-system";
          key = "credentials";
        };
      };

      # A second, unrelated provider: a different package, so the duplicate-package assertion sees
      # a legitimate two-provider table rather than only ever a one-entry one.
      example-cluster = {
        package = "xpkg.crossplane.io/example-org/provider-example-cluster";
        version = "v1.2.1";
        providerConfigApiVersion = "example-cluster.crossplane.io/v1alpha1";

        # Set explicitly, unlike the provider above: the case where a ProviderConfig already exists
        # in the cluster under a name that is not this declaration's attribute name, and this
        # declaration is adopting it rather than creating a second one.
        providerConfigName = "example-cluster-default";

        credentialsSecret = {
          name = "example-cluster-kubeconfig";
          namespace = "crossplane-system";
          key = "kubeconfig";
        };
      };
    };

    # ── The defaults, left at their SAFE values on purpose ─────────────────────────────────────
    # Both are inverted against Crossplane's own (`[ "*" ]` and `Delete`), and both are stated
    # explicitly here rather than inherited, because this is the one part of the declaration a
    # reader most needs to see: a consumer that adopts resources which already exist wants
    # observe-only and orphan-on-delete, and wants the dangerous behaviour to be something a
    # specific resource asks for in writing.
    defaults = {
      managementPolicies = [ "Observe" ];
      deletionPolicy = "Orphan";
      # acknowledgeDangerousDefaults stays null: nothing dangerous is being asked for, so nothing
      # needs justifying. Setting either field above to a converging or destroying value without a
      # sentence here fails the build -- proven both ways in checks/control-plane.nix.
    };

    # ── The CRD footprint budget ────────────────────────────────────────────────────────────────
    # A NARROW list: only the resource types this (imaginary) consumer actually composes. The saving
    # is the gap between this list and what the providers offer -- one service package of a large
    # cloud provider ships on the order of 200 types at roughly 3 MiB of API server memory each.
    #
    # Enabling this also sets nixiac.helmRelease.values.provider.defaultActivations = [ ], which is
    # not optional: with the chart's own permissive policy in place, a narrow policy is additive and
    # changes nothing at all. See modules/activation.nix's header.
    activation = {
      enable = true;
      activate = [
        "examples.example-cloud.crossplane.io"
        "objects.example-cluster.crossplane.io"
      ];
      # acknowledgeWildcardActivation stays null: no "*" is being asked for.
    };
  };

  # ── Stubs NixOS demands of any bootable system ─────────────────────────────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this config exists to type-check
  # modules, not to describe hardware. nixiac itself needs none of this -- see flake.nix's own
  # `modules` output for why a host is not required at all -- but composing through NixOS's own
  # eval-config.nix is what makes `config.assertions` enforced, which is what the check wants.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
