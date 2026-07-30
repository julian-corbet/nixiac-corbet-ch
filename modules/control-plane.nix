# modules/control-plane.nix
#
# WHICH CONTROL PLANE RUNS, AT WHICH PINNED VERSION, WITH WHICH PROVIDERS, WIRED TO WHICH
# CREDENTIALS BY REFERENCE -- and the two inverted defaults every managed resource this consumer
# renders inherits. Schema, eval-time assertion, and plain-data output only: there is no systemd
# unit here, nothing that reaches a cluster, and nothing that holds a credential value.
#
# ── WHY A CONTROL PLANE IS A THING WORTH DECLARING IN NIX AT ALL ────────────────────────────────
#
# Not for Nix's sake. The motivation is that a control plane's own composition -- which providers
# exist, at which versions, pointed at which credentials -- is the one part of an
# infrastructure-as-code layer that is pure configuration and yet routinely ends up expressed as a
# general-purpose program: a TypeScript file, a Go module, a Helm values file three levels of
# templating deep. A program is opaque to anything that reads SOURCE rather than running it, which
# means the cloud layer becomes the one part of a setup that a documentation renderer, an
# architecture graph, or an audit cannot see.
#
# The exchange rate is measured, and it is not close: a full host evaluation costs ~95 s and throws
# every comment away; importing a plain-data .nix file costs ~0.021 s and keeps the prose. Three
# orders of magnitude, for the same fact. So this module publishes facts, and refuses to publish
# mechanism -- see `modules/manifests.nix` for what "publishes facts" means concretely, and
# `checks/default.nix`'s `nixtest.lib.mkPurityChecks` calls for that claim being proven rather
# than asserted.
#
# ── WHAT THIS MODULE DOES NOT OWN, STATED BEFORE WHAT IT DOES ──────────────────────────────────
#
#   NOT the cluster. Whatever runs a Kubernetes API server owns that; this module assumes one
#   exists and renders objects for it.
#   NOT the workloads. A control plane is not an application platform.
#   NOT credential VALUES, ever. `credentialsSecret` is a name/namespace/key triple -- a
#   REFERENCE. A public repo that could hold a credential would eventually hold one.
#   NOT per-consumer resource values. A project identifier, a region, an account -- those live in the
#   private consumer that imports this module, reachable through `providerConfigSpec` below, which
#   is a hole this module never fills.
#
# ── THE VERSION PIN IS NOT TIDINESS ─────────────────────────────────────────────────────────────
#
# `version` and every `providers.<name>.version` are asserted to be a concrete release, never
# "latest" and never a branch. A control plane is the thing that reconciles a consumer's live cloud
# resources on a timer; an unpinned one upgrades itself, unattended, between two reconciles, with a
# new provider CRD surface and a new reconciler underneath resources that are already in production.
# There is no rollback for "the version changed while nobody was looking", because nothing recorded
# which version it changed from.
#
# ⚠ AND A NAMED SUCCESSOR IS NOT A PUBLISHED ONE. Verified 2026-07-30: at least one provider
# repository that an ARCHIVED provider's own README names as its official replacement has, five
# months later, zero git tags, zero releases, and no package published under any registry -- while
# being actively maintained enough to keep taking dependency-bump commits. A populated source tree
# is not a version you can pin. Check that a release exists before writing one down here, because
# `version` accepts any well-shaped string and a registry cannot be consulted at eval time.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf mkMerge;

  cfg = config.nixiac;
  actions = import ../lib/management-actions.nix { };

  blank = s: !(builtins.isString s) || builtins.match "[[:space:]]*" s != null;

  # A pinned version is a concrete three-component release, optionally with a pre-release or build
  # suffix, optionally `v`-prefixed. Everything else -- "latest", "stable", "main", a bare major,
  # a bare major.minor -- is a moving target: it resolves to a different artifact tomorrow while
  # the declaration reads identically.
  isPinned = v: !(blank v) && builtins.match "v?[0-9]+\\.[0-9]+\\.[0-9]+([-+][A-Za-z0-9.+-]+)?" v != null;

  # A package reference must carry no tag or digest of its own, because the version belongs in
  # `version`. Split on "/" and inspect only the LAST segment, so a registry host with a port
  # (`registry.example:5000/org/pkg`) is not mistaken for a tag.
  lastSegment = p: lib.last (lib.splitString "/" p);
  packageCarriesTag = p: !(blank p) && (lib.hasInfix ":" (lastSegment p) || lib.hasInfix "@" (lastSegment p));

  # `group/version`, both halves non-empty. A ProviderConfig's API group is chosen by the provider,
  # not by Crossplane, so this is the one field in this module that can only be read off the
  # installed CRDs -- see its own description.
  isApiVersion = v:
    !(blank v) && (
      let parts = lib.splitString "/" v; in
      lib.length parts == 2 && !(blank (lib.elemAt parts 0)) && !(blank (lib.elemAt parts 1))
    );

  providerNames = lib.attrNames cfg.providers;

  # ── The duplicate-package check, and the forcing gotcha it inherits ────────────────────────────
  # `lib.unique`'s fold compares each element against a GROWING accumulator, so the FIRST element --
  # and, in a table with exactly one provider, the ONLY element -- is compared against an empty list,
  # which answers without ever forcing the element. Left alone that means a lone provider's
  # `package` string is never actually forced by this check, and a table with one entry gets a
  # comparison that is structurally incapable of looking at it. `deepSeq` closes it directly. The
  # same gap, and the same fix, as nixstorage's own disk table -- recorded here rather than
  # rediscovered.
  packages = map (n: cfg.providers.${n}.package) providerNames;
  allPackagesForced = builtins.deepSeq packages true;
  declaredPackages = lib.filter (p: p != null) packages;
  duplicatePackages =
    lib.filter (p: lib.count (q: q == p) declaredPackages > 1) (lib.unique declaredPackages);

  # ── The intent gate ───────────────────────────────────────────────────────────────────────────
  # Every management action except `Observe`, plus `deletionPolicy = "Delete"`, requires a written
  # reason. See lib/management-actions.nix's header for what each action actually does to a resource
  # that already exists, and the `defaults` descriptions below for why the reason is a sentence
  # rather than a boolean.
  dangerousDefaultActions = lib.filter (a: lib.elem a actions.intentRequired) cfg.defaults.managementPolicies;
  illegalDefaultActions = lib.filter (a: !(lib.elem a actions.legal)) cfg.defaults.managementPolicies;

  # Same reflow-and-explain helper lib/managed-resource.nix uses, reading the SAME table -- the
  # whole reason that table is a file and not two inline enums. A wrong action name gets told what
  # to write instead, not merely that it is wrong.
  oneLine = s: lib.concatStringsSep " " (lib.filter (l: l != "") (lib.splitString "\n" s));
  illegalActionDetail = a:
    if actions.rejected ? ${a}
    then "  \"${a}\": ${oneLine actions.rejected.${a}}"
    else "  \"${a}\": not a member of the managementPolicies enum.";
  destructiveDeletionDefault = cfg.defaults.deletionPolicy == "Delete";
  acknowledged = !(blank cfg.defaults.acknowledgeDangerousDefaults);

  # ── Read across to the activation module DEFENSIVELY ──────────────────────────────────────────
  # `modules/activation.nix` is exported standalone, so it may or may not be part of this
  # evaluation. `or false` is the family's house rule for reading a sibling's option: a module that
  # reads one keeps working on a consumer that never imported it. It is also the family's known
  # hazard -- a defensive read cannot distinguish "option absent" from "declared and false" -- which
  # is why the Helm values this produces are checked in `checks/` in both states rather than assumed.
  activationEnabled = config.nixiac.activation.enable or false;

  credentialsSecretModule = { ... }: {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example-cloud-credentials";
        description = ''
          Name of the Kubernetes Secret holding this provider's credentials. A REFERENCE: nixiac
          renders the name into a ProviderConfig and never reads, holds, or templates the value.

          No default, because a defaulted Secret name is a ProviderConfig that points at a Secret
          nobody created. The provider then fails authentication on every reconcile, and it fails
          it inside a controller log -- the resources it manages simply stop being observed, with no
          signal anywhere a human is looking.
        '';
      };

      namespace = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "crossplane-system";
        description = ''
          Namespace of that Secret. Required explicitly, and deliberately NOT defaulted to
          `nixiac.namespace`: a ProviderConfig's `secretRef` is resolved by the provider's own
          controller, not by the client that applied it, so a namespace guessed from where
          Crossplane happens to run resolves to nothing the moment credentials are kept somewhere
          else -- which is the normal arrangement wherever a secrets operator owns them.
        '';
      };

      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "credentials";
        description = ''
          Which key inside that Secret carries the credential. Required, with no default, because
          Secrets routinely hold several keys and the wrong one is not an error anywhere: the
          provider reads bytes, fails to parse or fails to authenticate with them, and reports it
          in its own log. A defaulted key turns "wrong entry selected" into a silent auth failure.
        '';
      };
    };
  };

  providerModule = { name, ... }: {
    options = {
      package = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "xpkg.crossplane.io/example-org/provider-example-cloud";
        description = ''
          The provider package reference, WITHOUT a tag or digest -- the version belongs in
          `version` and this module joins the two. A reference that carries its own `:tag` is
          rejected: two places to write a version is two places for it to drift, and the copy
          inside the string is the one that wins while the one a human reads in `version` is the
          one they believe.

          ⚠ REGISTRY AND VOCABULARY TRAP, both worth getting right in a declaration that outlives
          the person who wrote it. Since early 2025 the term "Official Provider" refers
          specifically to a paid-subscription build published under one vendor's own registry
          namespace. The freely published build of the SAME source, under the community
          organisation's namespace, is by that vendor's current vocabulary a "Community Provider" --
          same maintainers, same quality bar, no subscription. Point this at the community
          namespace unless a subscription is actually in play, and do not describe either as
          "official" in a comment: the word now means something specific and something else.

          ⚠ MONOLITHIC PROVIDER PACKAGES ARE GONE, not merely discouraged. Support for them ended
          2024-06-12; the installable form for the large clouds is a `provider-family-<cloud>`
          base package (which owns the shared ProviderConfig type) plus one package per service
          group. That split exists because a single monolithic provider installed more than 900
          CRDs by itself and could leave a control plane's API unresponsive for up to an hour
          during the resulting scale-up. Declare the family base package and only the service
          packages actually used -- see `nixiac.activation` for the second, finer mechanism that
          also matters, and `studies/crd-footprint.md` for the numbers.
        '';
      };

      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "v2.6.0";
        description = ''
          The exact provider release to install, joined to `package` as `package:version`. Asserted
          to be a concrete three-component release: "latest", "stable", a branch name, a bare major
          or a bare `major.minor` are all rejected.

          What breaks without the pin: a provider is the component that translates this consumer's
          declarations into API calls. An unpinned one is replaced under a running control plane by
          whatever the registry tag points at that hour -- new CRD surface, new field defaults, new
          reconciler -- against resources that are already in production, with nothing recording
          what it was replaced from.

          ⚠ Verify the release EXISTS before writing it here. This option accepts any well-shaped
          string and no registry can be consulted at eval time. Verified 2026-07-30: a provider
          repository named as the official successor to an archived one had, five months on, zero
          tags and zero releases despite an actively maintained source tree. "The repo is the
          successor" and "there is a version to pin" are different claims.
        '';
      };

      providerConfigApiVersion = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example-cloud.crossplane.io/v1beta1";
        description = ''
          The `apiVersion` of THIS provider's own ProviderConfig kind, as `group/version`.

          Required, with no default, and this is the one field in the module nixiac genuinely
          cannot derive: `Provider` is a core Crossplane type whose group follows from the pinned
          core version, but `ProviderConfig` is defined by each provider's own CRDs and its API
          group is chosen by that provider. There is no registry to consult at eval time and
          guessing produces an object the API server rejects as an unknown kind -- at apply time,
          after the manifest has rendered, committed and synced cleanly.

          Read it off the installed provider instead of inferring it from the package name:
          `kubectl get crd -o name | grep providerconfig` names the group, and
          `kubectl explain providerconfig` names the served version.
        '';
      };

      providerConfigName = mkOption {
        type = types.str;
        default = name;
        defaultText = lib.literalExpression "<name>";
        description = ''
          The ProviderConfig's own `metadata.name` -- the exact string a managed resource's
          `spec.providerConfigRef.name` has to match. Defaults to this provider's attribute name,
          which is the only default in this module that cannot go wrong: it is derived from the
          declaration rather than guessed, and a consumer reading the attribute name off the same
          file gets the same answer.

          Set it explicitly when a ProviderConfig already exists in the cluster under a different
          name and this declaration is adopting it. Getting it wrong is quiet: the resource's
          `providerConfigRef` resolves to nothing, so it never reconciles at all -- no apply error,
          no status, just a CR that sits there looking applied.
        '';
      };

      providerConfigNamespace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Namespace for this provider's ProviderConfig object, or `null` (the default) for the
          cluster-scoped form.

          Crossplane v2 introduced namespaced variants of several types that used to exist only
          cluster-scoped. Getting the scope wrong is quiet in exactly the way that hurts: a managed
          resource's `providerConfigRef` resolves against the scope its own kind expects, finds
          nothing, and the resource never reconciles -- no error on apply, no status, just a CR that
          sits there. Leave this `null` unless the installed provider actually serves a namespaced
          ProviderConfig, and confirm which one it serves rather than inferring it from the
          Crossplane version.
        '';
      };

      providerConfigSpec = mkOption {
        type = types.attrs;
        default = { };
        example = lib.literalExpression ''{ projectID = "a-consumer-specific-identifier"; }'';
        description = ''
          Extra keys merged into this ProviderConfig's `spec`, for the scoping fields a particular
          provider requires beyond credentials -- a project identifier, an account, a default
          region.

          A deliberate hole in this module rather than a set of typed options, for two reasons.
          nixiac does not know any provider's ProviderConfig schema (see
          `providerConfigApiVersion`), so typing these would be re-deriving one provider's CRD one
          field at a time and would be wrong for the next one. And every value that belongs here is
          a CONSUMER value -- which project, which account -- which is exactly the class of fact this
          repo must never hold. The consumer that imports nixiac supplies them; nixiac renders them
          and keeps none.

          `spec.credentials` is rendered by this module and must not be set here.
        '';
      };

      credentialsSecret = mkOption {
        type = types.nullOr (types.submodule credentialsSecretModule);
        default = null;
        example = lib.literalExpression ''
          {
            name = "example-cloud-credentials";
            namespace = "crossplane-system";
            key = "credentials";
          }
        '';
        description = ''
          Where this provider's credentials live, as a name/namespace/key REFERENCE. Never a value:
          a public repo that could hold a credential eventually holds one, and a credential in a Nix
          store path is world-readable on every machine that evaluated it.

          Required. A ProviderConfig with no credentials is accepted by the API server and fails at
          RECONCILE time, in a controller log -- and the failure is not "provider down", it is
          "these resources are no longer being observed", which looks like nothing at all from
          outside. Declaring a provider without saying where its credentials come from is therefore
          a build-time error here: the one place the mistake is cheap.

          ⚠ nixiac renders `spec.credentials.source = "Secret"` only. Providers on some clouds can
          instead take an injected workload identity and need no Secret at all, which this option's
          shape cannot express -- an honest gap, tracked as `experiments/README.md` #001 rather
          than papered over with a nullable field that would also weaken the assertion above.
        '';
      };
    };
  };
in
{
  imports = [ ./manifests.nix ];

  options.nixiac = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Render this control plane's manifests into `nixiac.manifests`.

        Most pure-data modules in this family have no `enable` at all -- the act of importing the
        file is the toggle, because there is nothing running to turn on. This one earns one: the
        attrset it produces is handed to a GitOps renderer, so a non-empty `nixiac.manifests` is
        the difference between a validated declaration and a control plane being installed into a
        live cluster on the next sync.

        Turning it off does NOT turn off validation. Every assertion in this module still fires for
        any provider that has been declared, enabled or not -- an example, or a half-finished
        declaration, that gets the data and none of the safety is precisely the wrong thing to
        teach.
      '';
    };

    controlPlane = mkOption {
      type = types.enum [ "crossplane" ];
      default = "crossplane";
      description = ''
        Which control plane this consumer's infrastructure-as-code layer runs on.

        An enum with exactly one member today, and an enum on purpose rather than a boolean or an
        implicit assumption. A second control plane then arrives as an ADDITION to this list, and
        every consumer that branches on `controlPlane == "crossplane"` keeps saying what it already
        said. The alternative -- a `useCrossplane` boolean, or no option at all -- makes the second
        one a rewrite of every condition in every consumer, and boolean conditions do not survive
        that: `if !useCrossplane` silently becomes "the other one" the moment there are three.
      '';
    };

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "v2.3.4";
      description = ''
        The pinned control-plane release. Asserted to be a concrete three-component version --
        "latest", "stable", a branch name, a bare major or a bare `major.minor` are all rejected.

        What breaks without a pin: the control plane is the component that reconciles live cloud
        resources on a timer. Unpinned, it replaces itself between two reconciles with whatever a
        moving tag resolves to that hour -- new CRD conversion behaviour, new reconciler semantics,
        new defaults -- underneath resources that are already in production, and with nothing
        recording which version it replaced. "Roll back to what was running yesterday" has no
        answer, because the declaration never said.

        No default. A version this repo picked would be a version nobody tested against this
        consumer, and it would go stale silently -- see `nixiac.chartVersion` for the one place a
        default is derived, and why even that one is overridable.
      '';
    };

    chartVersion = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "v2.3.4";
      description = ''
        The Helm chart version for the control plane, when it differs from `version`. `null` (the
        default) means "the same as `version`", which holds while the chart is released in lockstep
        with the application it installs.

        This option exists because that lockstep is a convention, not a guarantee, and the failure
        when it breaks is a chart that renders one application version while the declaration --
        and everything reading it -- says another. Two facts that must agree and cannot be checked
        against each other at eval time deserve two fields, with the derivation as the default and
        the override available.
      '';
    };

    chartRepository = mkOption {
      type = types.str;
      default = "https://charts.crossplane.io/stable";
      description = ''
        Helm repository the control-plane chart is fetched from, published as a fact for whatever
        actually performs the install.

        Override it to a mirror, or to a vendored copy -- both are ordinary, and a vendored chart
        tarball is the stricter choice because it removes a network dependency from a deploy. What
        must NOT happen is repointing this at a rolling channel (a `master`/`main` chart stream):
        that reintroduces exactly the unpinned upgrade `version` exists to prevent, through a field
        nobody thinks of as a version.
      '';
    };

    namespace = mkOption {
      type = types.str;
      default = "crossplane-system";
      description = ''
        Namespace the control plane itself runs in. Defaulted -- unusually for this family, which
        avoids guessed defaults -- because this specific value is the upstream chart's own
        convention and every piece of third-party documentation, every `kubectl` example and every
        support answer assumes it. Deviating is legal and occasionally necessary; doing it silently
        means every diagnostic command anyone pastes from anywhere looks in the wrong place.

        This is NOT a default for where credentials live: see `providers.<name>.credentialsSecret`
        for why that namespace is required explicitly instead of being derived from this one.
      '';
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerModule);
      default = { };
      description = ''
        The providers this control plane installs, keyed by a short name that also becomes the
        default ProviderConfig name.

        Each entry is a package, a pinned version, the API group of that provider's own
        ProviderConfig kind, and a REFERENCE to where its credentials live. No entry ever holds a
        credential value, and no entry holds a consumer resource value -- provider-specific scoping
        fields go through `providerConfigSpec`, which this module renders and never fills.

        Keep this list as short as the consumer actually needs. Provider packaging for the large
        clouds is split into a family base package plus one package per service group precisely
        because CRD count is a real cost to the API server, and installing a service package "in
        case" is paying for it -- see `nixiac.activation` and `studies/crd-footprint.md`.
      '';
    };

    defaults = {
      managementPolicies = mkOption {
        # DELIBERATELY `listOf str` rather than `listOf (enum actions.legal)`. An enum here would
        # reject an illegal member first, which makes the assertion below unreachable -- and the
        # assertion is the better guard, because it can consult lib/management-actions.nix's
        # `rejected` table and answer "you probably meant this instead" for the specific names that
        # get written by mistake. Two guards for one condition, one of them unreachable, is worse
        # than one guard with a message that teaches.
        type = types.listOf types.str;
        default = [ "Observe" ];
        example = [ "Observe" "Create" "Update" ];
        description = ''
          The `spec.managementPolicies` every managed resource rendered through
          `lib.mkManagedResource` inherits unless it overrides them.

          THIS DEFAULT IS THE LOAD-BEARING CHOICE IN THE WHOLE MODULE. Crossplane's own default is
          `[ "*" ]` -- every action, including Update and Delete -- and it is the right default for
          a control plane that CREATES what it manages. It is exactly backwards for adopting
          resources that already exist and are already in production, and the failure is silent:
          Crossplane treats `spec.forProvider` as the source of truth, so on the FIRST reconcile of
          a freshly-applied CR it converges the LIVE resource to whatever the spec says. The spec of
          a just-written adoption manifest is, by construction, a partial hand-transcription of
          what the live resource looks like. Reading crossplane-runtime's own reconciler settles the
          timing: when the observation is not up to date, the diff is logged at DEBUG level and
          `external.Update()` is called in the SAME pass. No confirmation step, no
          drift-detected condition to notice first.

          `[ "Observe" ]` inverts it: the resource is read, `status.atProvider` is populated, and
          nothing is ever written. The dangerous behaviour is then something a specific resource
          asks for, with a written reason, rather than something every resource has by default and
          only the careful ones remove.

          ⚠ `[ "Observe" ]` does not prove an adoption is CORRECT. An observe-only resource whose
          spec is wildly wrong still reports `Synced=True`: when the policy forbids Update, the
          diff is logged at DEBUG and the reconcile is marked successful. `Synced` means "the
          controller ran", not "the declaration matches reality".

          ⚠ Do not reach for `LateInitialize` to close that gap. It answers "does my spec match
          reality?" by rewriting the spec to match reality -- which is why it is in the
          intent-required set alongside Delete despite touching nothing in the cloud.
        '';
      };

      deletionPolicy = mkOption {
        type = types.enum actions.legalDeletionPolicies;
        default = "Orphan";
        description = ''
          The `spec.deletionPolicy` every CLUSTER-SCOPED managed resource rendered through
          `lib.mkManagedResource` inherits unless it overrides it. Crossplane's own default is
          `Delete`; nixiac's is `Orphan`.

          What `Delete` breaks: it decides what happens to a real cloud resource when its
          DECLARATION goes away -- and declarations go away for reasons with nothing to do with
          intent. A rename. A refactor. A file moved between directories. A GitOps prune of a path
          that stopped being rendered. Under `Delete` each of those destroys production
          infrastructure; under `Orphan` each of them is a no-op that leaves the resource running
          and unmanaged, which is recoverable in an afternoon.

          ⚠ This field only exists on the legacy, cluster-scoped managed-resource kinds. The modern
          v2 namespaced kinds have no `deletionPolicy` at all, and `lib.mkManagedResource` therefore
          omits it for them -- which loses nothing, because on a modern kind orphan-on-delete comes
          from the ABSENCE of `Delete` in `managementPolicies`, which the default above already
          gives. Asking for `Delete` on a namespaced resource is a hard error rather than a silent
          omission, so that nobody believes a request took effect that never reached the cluster.
        '';
      };

      acknowledgeDangerousDefaults = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "This control plane owns the lifecycle of every resource it renders; nothing here pre-existed it.";
        description = ''
          A written reason for turning off the safe defaults above. Required as soon as
          `deletionPolicy = "Delete"`, or `managementPolicies` contains anything other than
          `Observe`.

          A SENTENCE, not a boolean, and that is the entire mechanism. `= true` can be typed by
          reflex, reads as noise in a diff, and answers no question a year later. A sentence has to
          be composed, it shows up in review as prose someone chose to write, it names the person
          who accepted the risk by being in their commit, and it is still legible to whoever
          inherits the declaration. An empty or whitespace-only string does not count -- the
          assertion checks for content, not for presence.

          This gates the global DEFAULT. A single resource that needs converging or destroying
          asks for it per resource, through `lib.mkManagedResource`'s own `acknowledgeDangerous`,
          which is the narrower and better place for it: this option makes every resource dangerous
          at once.
        '';
      };
    };

    helmRelease = mkOption {
      type = types.attrs;
      readOnly = true;
      # NO `default`, deliberately, and it is not an oversight: with `readOnly = true` a default
      # counts as one definition and this module's own unconditional assignment counts as a second,
      # so declaring one turns every evaluation into "the option is read-only, but it's set multiple
      # times". Measured here 2026-07-30 against a minimal two-line module before it was understood.
      # There is no case where the default would be reached anyway -- the assignment below is
      # unconditional, precisely so a consumer can read these facts whether or not `enable` is set.
      description = ''
        Derived, read-only: the facts an installer needs to put this control plane on a cluster --
        chart name, repository, version, namespace, and the values that must accompany the rest of
        this declaration.

        Published as data rather than performed, because nixiac does not install anything: whatever
        already turns declarations into cluster state reads these fields by name. The reason it
        exists at all instead of leaving the consumer to retype four strings is `values`: when
        `nixiac.activation` is enabled, the chart MUST be installed with the permissive default
        activation policy disabled, or the whole footprint mechanism silently does nothing (see
        that module's own header). A footprint discipline that depends on two independently
        maintained declarations agreeing is one that will eventually stop being true.
      '';
    };
  };

  config = mkMerge [
    # ── Validation: runs for anything DECLARED, whether or not `enable` is set ─────────────────
    (mkIf (cfg.enable || cfg.providers != { }) {
      assertions =
        [
          {
            # Not a tautology, and the one assertion here that is about THIS REPO rather than about
            # a declaration. `controlPlane` is an enum so that a second control plane is an addition
            # rather than a rewrite of every consumer's condition -- but adding an enum member is
            # only half of that work, and the other half is a renderer in this file. Without this
            # assertion, adding a member would produce a declaration that validates, renders
            # nothing, and looks installed. It is also what FORCES the enum: nothing else in this
            # module reads `controlPlane`, and an option nothing forces is an option whose type is
            # never checked (the same class of gap `deepSeq` closes for the package list above).
            assertion = cfg.controlPlane == "crossplane";
            message = ''
              nixiac.controlPlane = "${toString cfg.controlPlane}" is declared, but this version of
              nixiac has no renderer for it -- see the `nixiac.manifests` branch in
              modules/control-plane.nix. Adding a member to the enum is half the change; the other
              half is the objects that member should render.
            '';
          }

          {
            assertion = cfg.version != null;
            message = ''
              nixiac.version is unset. The control-plane version has no default here on purpose: a
              version this repo chose would be one nobody tested against this consumer, and it would
              go stale without anything saying so. Pin the release you have actually run.
            '';
          }

          {
            assertion = cfg.version == null || isPinned cfg.version;
            message = ''
              nixiac.version = "${toString cfg.version}" is not a pinned release.

              Expected a concrete three-component version, optionally `v`-prefixed and optionally
              with a pre-release suffix (e.g. "v2.3.4", "2.3.4", "v2.3.4-rc.1"). Rejected:
              "latest", "stable", a branch name, a bare major ("v2"), a bare major.minor ("v2.3").

              A control plane reconciles live cloud resources on a timer. Unpinned, it upgrades
              itself between two reconciles -- new CRD conversion behaviour, new reconciler, new
              defaults -- under resources already in production, and nothing recorded what it
              upgraded FROM, so there is nothing to roll back to.
            '';
          }

          {
            assertion = cfg.chartVersion == null || isPinned cfg.chartVersion;
            message = ''
              nixiac.chartVersion = "${toString cfg.chartVersion}" is not a pinned release. Same
              rule and same reason as nixiac.version -- a moving chart version installs a moving
              application version, through a field nobody thinks of as a version.
            '';
          }

          {
            assertion = allPackagesForced && duplicatePackages == [ ];
            message = ''
              nixiac.providers: the same package is declared under more than one name:
              ${lib.concatStringsSep "\n" (map (p: "  ${p}") duplicatePackages)}

              One package, one name. Two names for one package means two Provider objects racing to
              install the same controller, and if the two entries also disagree about `version` the
              cluster ends up with whichever revision won -- with both declarations still reading as
              though they were honoured.

              Note that a family base package and its service packages are DIFFERENT packages and
              are meant to be declared separately; this only fires on a genuine duplicate.
            '';
          }

          {
            assertion = cfg.defaults.managementPolicies != [ ];
            message = ''
              nixiac.defaults.managementPolicies is empty. An empty list declares no actions at
              all -- not even Observe -- so every resource inheriting it reads nothing, publishes no
              `status.atProvider`, and is indistinguishable from a typo. The safe minimum, and this
              option's own default, is [ "Observe" ].
            '';
          }

          {
            assertion = illegalDefaultActions == [ ];
            message = ''
              nixiac.defaults.managementPolicies contains value(s) the API server rejects:
              ${lib.concatStringsSep "\n" (map illegalActionDetail illegalDefaultActions)}
              The accepted set is exactly: ${lib.concatStringsSep ", " actions.legal}.

              Caught here rather than at apply time because an unknown enum member fails inside a
              controller in a cluster -- long after the manifest rendered, committed and synced
              cleanly -- while whoever wrote it believes they asked for the behaviour the name
              suggests.
            '';
          }

          {
            assertion = dangerousDefaultActions == [ ] || acknowledged;
            message = ''
              nixiac.defaults.managementPolicies asks for ${lib.concatStringsSep ", " dangerousDefaultActions},
              and nixiac.defaults.acknowledgeDangerousDefaults is unset.

              `Observe` is the only action nixiac applies without a written reason, because it is the
              only one that cannot change or destroy a resource that already exists. Everything else
              either converges the live resource to a hand-transcribed spec on the next reconcile
              (Create/Update/*), destroys it when its declaration goes away (Delete), or rewrites
              your own spec to match reality so a wrong declaration looks correct (LateInitialize).

              This is the GLOBAL default, so turning it off makes every rendered resource
              dangerous at once. Prefer per-resource `acknowledgeDangerous` in
              `lib.mkManagedResource`. If the global default is genuinely right, write a
              sentence here saying why.
            '';
          }

          {
            assertion = !destructiveDeletionDefault || acknowledged;
            message = ''
              nixiac.defaults.deletionPolicy = "Delete" and
              nixiac.defaults.acknowledgeDangerousDefaults is unset.

              `Delete` decides what happens to real cloud resources when their DECLARATIONS go
              away -- and declarations go away for reasons unrelated to intent: a rename, a
              refactor, a file moved between directories, a GitOps prune of a path that stopped
              being rendered. As a global default, this makes every one of those events
              destructive for every resource at once.

              Write a sentence in acknowledgeDangerousDefaults saying why this control plane owns
              the lifecycle of everything it renders -- or leave the default "Orphan" and let the
              individual resources that genuinely need destroying ask for it themselves.
            '';
          }
        ]
        ++ lib.concatMap
          (n:
            let p = cfg.providers.${n}; in
            [
              {
                assertion = p.package != null;
                message = ''
                  nixiac.providers.${n}.package is unset. A provider with no package is a Provider
                  object with nothing to install: it applies cleanly and then does nothing, which
                  from outside looks like "the provider is starting".
                '';
              }
              {
                assertion = p.package == null || !(packageCarriesTag p.package);
                message = ''
                  nixiac.providers.${n}.package = "${toString p.package}" carries its own tag or
                  digest. Put the version in `nixiac.providers.${n}.version` instead -- this module
                  joins them as `package:version`.

                  Two places to write one version is two places for it to drift, and the copy
                  inside the package string is the one the cluster obeys while the one in `version`
                  is the one a human reads.
                '';
              }
              {
                assertion = isPinned p.version;
                message = ''
                  nixiac.providers.${n}.version = "${toString p.version}" is not a pinned release.

                  Expected a concrete three-component version (e.g. "v2.6.0"). Rejected: unset,
                  "latest", "stable", a branch name, a bare major, a bare major.minor.

                  A provider is what translates this consumer's declarations into API calls.
                  Unpinned, it is replaced under a running control plane by whatever a moving tag
                  resolves to -- new CRD surface, new field defaults, new reconciler -- against
                  resources already in production.

                  ⚠ A well-shaped version string is not a version that EXISTS: no registry can be
                  consulted at eval time. Confirm the release is published before pinning it.
                '';
              }
              {
                assertion = isApiVersion p.providerConfigApiVersion;
                message = ''
                  nixiac.providers.${n}.providerConfigApiVersion = "${toString p.providerConfigApiVersion}"
                  is not a `group/version` pair.

                  This is the one field nixiac cannot derive: `ProviderConfig` is defined by each
                  provider's own CRDs and its API group is chosen by that provider, not by
                  Crossplane. A guessed group renders an object the API server rejects as an unknown
                  kind -- at apply time, after the manifest rendered, committed and synced cleanly.

                  Read it off the installed provider: `kubectl get crd -o name | grep providerconfig`
                  for the group, `kubectl explain providerconfig` for the served version.
                '';
              }
              {
                assertion = p.credentialsSecret != null;
                message = ''
                  nixiac.providers.${n}.credentialsSecret is unset.

                  A ProviderConfig with no credentials is accepted by the API server and fails at
                  RECONCILE time, inside a controller log. The visible symptom is not "the provider
                  is down" -- it is that the resources this provider manages quietly stop being
                  observed, which looks like nothing at all from outside the cluster. Fail here
                  instead: this is the one place the mistake is cheap.

                  Credentials are referenced, never held: give a Secret name, its namespace, and
                  the key inside it.
                '';
              }
              {
                assertion = p.credentialsSecret == null
                || (!(blank p.credentialsSecret.name)
                && !(blank p.credentialsSecret.namespace)
                && !(blank p.credentialsSecret.key));
                message = ''
                  nixiac.providers.${n}.credentialsSecret is incomplete: ${
                    lib.concatStringsSep ", " (
                      lib.optional (blank p.credentialsSecret.name) "name"
                      ++ lib.optional (blank p.credentialsSecret.namespace) "namespace"
                      ++ lib.optional (blank p.credentialsSecret.key) "key"
                    )
                  } missing or blank.

                  A partial secret reference is worse than none: it renders a ProviderConfig that
                  looks wired up and resolves to nothing, so the failure surfaces only as resources
                  that stopped being observed. All three parts are required, and none is defaulted --
                  a guessed namespace resolves against wherever Crossplane happens to run rather
                  than wherever credentials are actually kept, and a guessed key silently selects
                  the wrong entry of a multi-key Secret.
                '';
              }
              {
                assertion = !(p.providerConfigSpec ? credentials);
                message = ''
                  nixiac.providers.${n}.providerConfigSpec sets `credentials`, which this module
                  renders from `credentialsSecret`. One of the two definitions would win silently.
                  Put the Secret reference in `credentialsSecret` -- that is the field the
                  "credentials are references, never values" guarantee is checked against.
                '';
              }
            ])
          providerNames;
    })

    # ── Derived facts: published whether or not manifests are rendered ────────────────────────
    {
      nixiac.helmRelease = {
        chart = "crossplane";
        repository = cfg.chartRepository;
        version = if cfg.chartVersion != null then cfg.chartVersion else cfg.version;
        namespace = cfg.namespace;

        # The values that MUST accompany this declaration, not a suggestion of nice ones. The
        # chart's own install creates a permissive activation policy that activates every managed
        # resource kind in every installed provider; with that policy in place, a narrow
        # `nixiac.activation` policy is additive and changes nothing, so the entire footprint
        # mechanism silently does nothing while appearing configured. See modules/activation.nix.
        values = lib.optionalAttrs activationEnabled {
          provider.defaultActivations = [ ];
        };
      };
    }

    # ── Rendering ──────────────────────────────────────────────────────────────────────────────
    (mkIf cfg.enable {
      # Branched on the enum rather than assuming its one member, so that adding a second control
      # plane to `controlPlane` cannot produce a declaration that validates and renders nothing.
      # The assertion above is the readable failure; this is the one that survives an evaluator
      # which does not enforce assertions at all.
      nixiac.manifests =
        if cfg.controlPlane != "crossplane"
        then
          throw ''
            nixiac.controlPlane = "${toString cfg.controlPlane}" has no renderer in this repo.
            See the matching assertion in modules/control-plane.nix: adding an enum member is half
            the change, and the objects that member should render are the other half.
          ''
        else
          lib.listToAttrs (lib.concatMap
            (n:
              let
                p = cfg.providers.${n};

                # A second, redundant-looking guard on top of the assertions above, and deliberately
                # not redundant: nixiac's modules are meant to be evaluated by things that are not
                # NixOS (a GitOps renderer, a plain `lib.evalModules`), and `config.assertions` is a
                # passive list that only becomes an error when something chooses to enforce it. An
                # evaluator that does not would otherwise interpolate `null` into a package reference
                # and render `"null:null"`, or drop the provider silently. Neither is acceptable, so
                # the render itself refuses.
                complete = p.package != null && p.version != null
                  && p.providerConfigApiVersion != null && p.credentialsSecret != null;

                require = v:
                  if complete then v
                  else
                    throw ''
                      nixiac.providers.${n} cannot be rendered: package/version/providerConfigApiVersion/credentialsSecret
                      must all be set. If you are seeing this instead of nixiac's own assertion messages,
                      the evaluator in use does not enforce `config.assertions` -- read them out of
                      `config.assertions` directly for the full explanation of each field.
                    '';
              in
              map (entry: { inherit (entry) name; value = require entry.value; }) [
                {
                  name = "provider-${n}";
                  value = {
                    # `pkg.crossplane.io/v1` is hardcoded, and the contrast with
                    # `providerConfigApiVersion` is the point: `Provider` is a CORE Crossplane type, so
                    # its group follows from the pinned core version and this module can know it. A
                    # ProviderConfig's group is chosen by each provider, so this module cannot, and asks.
                    apiVersion = "pkg.crossplane.io/v1";
                    kind = "Provider";
                    metadata.name = n;
                    spec.package = "${p.package}:${p.version}";
                  };
                }
                {
                  name = "providerconfig-${n}";
                  value = {
                    apiVersion = p.providerConfigApiVersion;
                    kind = "ProviderConfig";
                    metadata = { name = p.providerConfigName; }
                      // lib.optionalAttrs (p.providerConfigNamespace != null) {
                      namespace = p.providerConfigNamespace;
                    };
                    spec = p.providerConfigSpec // {
                      # `source = "Secret"` is the only credentials source nixiac renders. See
                      # `credentialsSecret`'s own description and experiments #001 for the honest gap.
                      credentials = {
                        source = "Secret";
                        secretRef = {
                          inherit (p.credentialsSecret) name namespace key;
                        };
                      };
                    };
                  };
                }
              ])
            providerNames);
    })
  ];
}
