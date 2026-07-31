{
  description = "nixiac -- the Crossplane control plane declared in Nix, as data: which control plane runs, which providers at which PINNED versions, ProviderConfig wiring by REFERENCE (never a credential value), how much API-server memory the CRD footprint is allowed to cost, and a Nix -> Crossplane-CR rendering shape whose defaults are INVERTED against Crossplane's own -- observe-only and orphan-on-delete -- so that converging or destroying a live cloud resource has to be asked for per resource, in writing. Renders plain-data Kubernetes objects; installs nothing, applies nothing, reaches no cluster.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # NOTHING that renders or runs alongside this control plane -- in particular no other nix*
    # PRODUCT repo -- not the module that owns the cluster this control plane runs on, and not the
    # one that owns the workloads beside it. A control plane is a thing a consumer composes
    # ALONGSIDE those, not a thing that depends on them, and an input here would make the
    # composition order a fact about this repo rather than about the consumer. Where nixiac needs
    # to know something a sibling declares, it reads the option defensively
    # (`config.<sibling>.<x> or null`) so that the module keeps working on a consumer that never
    # imported it -- see modules/control-plane.nix's own read of
    # `config.nixiac.activation.enable or false` for the in-repo version of the same pattern, and
    # `checks/` for that read being proven in both states rather than assumed.
    #
    # No GitOps-renderer input either. nixiac's whole delivery surface is `nixiac.manifests`, an
    # attrset of plain Kubernetes objects; JSON is a strict subset of YAML 1.2, so any renderer,
    # any client, and any human already accepts them without this repo depending on a particular
    # one. See modules/manifests.nix's own header.
    #
    # nixtest IS taken as an input, and it is a different category of thing entirely: a lib-only
    # TEST FIXTURE (see that repo's own README -- "no NixOS module, no `enable`, nothing that acts
    # on a host"), never a runner, never composed into anything this flake exports. A hand-derived
    # copy of `nixtest.lib.mkPurityChecks` in `checks/purity.nix` could silently drift into a
    # weaker proof (e.g. eval-pure as a module GROUP, never each module ALONE -- so
    # `modules/manifests.nix` composed on its own, the one way this repo's own README says it may
    # legitimately be imported, would never actually be eval-diffed) while still reading as "the
    # purity check passing", which is worse than no check because it stops anyone from looking.
    # One recipe, taken as a dependency, cannot drift from itself.
    nixtest = {
      url = "github:julian-corbet/nixtest-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixtest }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # THREE independently importable modules under one `nixiac.*`
      # namespace. All three are pure schema, eval-time assertion, and
      # plain-data output -- none of them ships a systemd unit, touches a
      # host, or reaches a cluster, which is what makes them evaluable by
      # something other than NixOS (see `modules` below).
      #
      #   controlPlane -- which control plane, which version, which
      #                   providers, wired to which credentials BY
      #                   REFERENCE, plus the two inverted defaults every
      #                   rendered resource inherits.
      #   activation   -- how much API-server memory the CRD footprint is
      #                   allowed to cost. A separate module because it is
      #                   the CLUSTER's budget, not the control plane's
      #                   composition, and two environments running the
      #                   identical provider set can legitimately answer it
      #                   differently.
      #   manifests    -- the single output surface both of the above write
      #                   into, declared in one file so that neither has to
      #                   know whether the other is present. Imported
      #                   automatically by both; listed here because a
      #                   consumer that wants only the output surface (to
      #                   hand hand-written objects to the same renderer)
      #                   can import it alone.
      #
      # `default` is the common case: a control plane and its footprint
      # budget declared together.
      # ---------------------------------------------------------------
      nixosModules.controlPlane = ./modules/control-plane.nix;
      nixosModules.activation = ./modules/activation.nix;
      nixosModules.manifests = ./modules/manifests.nix;
      nixosModules.default = {
        imports = [
          self.nixosModules.controlPlane
          self.nixosModules.activation
        ];
      };

      # The same three files under a name that does not claim a host.
      #
      # Nothing in this repo runs on a machine: a control plane runs on a
      # Kubernetes cluster, and these modules only ever produce data
      # describing one. `nixosModules.*` exists because NixOS's own
      # `eval-config.nix` is what this repo's `checks` compose through (and
      # because a host that RENDERS GitOps artifacts is a perfectly ordinary
      # place to import them), not because a host is required. A GitOps
      # renderer, or a bare `lib.evalModules`, is an equally valid
      # evaluator -- and `checks/` proves the claim that makes that true (via
      # nixtest's shared `lib.mkPurityChecks` fixture), by showing these
      # modules change no host-only surface at all.
      modules = {
        controlPlane = ./modules/control-plane.nix;
        activation = ./modules/activation.nix;
        manifests = ./modules/manifests.nix;
        default = self.nixosModules.default;
      };

      lib = {
        # The rendering shape: one attrset in, one Crossplane managed-resource CR out, with the
        # inverted defaults stamped on and the dangerous ones reachable only by writing down why.
        # A plain function, called with `lib` supplied directly by whatever evaluation needs it --
        # the same convention nixtest's own fixtures use, and for the same reason: a caller that
        # already has `lib` needs no module system to merge a returned attrset into its own render.
        #
        #   nixiac.lib.mkManagedResource {
        #     inherit lib;
        #     apiVersion = "example.example-cloud.crossplane.io/v1beta1";
        #     kind = "Example";
        #     name = "an-example";
        #     namespace = "example";
        #     externalName = "the-identifier-the-cloud-already-uses";
        #     providerConfigRef = "example-cloud";
        #     forProvider = { region = "somewhere"; };
        #   }
        mkManagedResource = import ./lib/managed-resource.nix;

        # The vocabulary table, exposed so a consumer can inspect or validate the accepted
        # management actions without re-reading the file -- same reason nixstorage exposes
        # `lib.partitionRoles`. Pure data; see that file's header for the measured finding it
        # records about two sources disagreeing and the documentation being wrong.
        managementActions = import ./lib/management-actions.nix { };
      };

      # All three modules composed into one system from examples/control-plane, plus the eval-time
      # and purity check groups for the parts a single composed evaluation cannot exercise (an
      # assertion firing, a `throw` from the rendering function, the claim that these modules touch
      # no host-only surface). Same split nixstorage and nixtest already use in this family.
      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system nixtest;
          controlPlaneModule = self.nixosModules.controlPlane;
          activationModule = self.nixosModules.activation;
          manifestsModule = self.nixosModules.manifests;
          mkManagedResource = self.lib.mkManagedResource;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
