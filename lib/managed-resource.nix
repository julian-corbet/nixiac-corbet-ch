# lib/managed-resource.nix -- `lib.mkManagedResource`
#
# THE RENDERING SHAPE: one Nix attribute set in, one Crossplane managed-resource CR (as plain,
# JSON-serialisable Nix data) out, with nixiac's INVERTED DEFAULTS stamped on unconditionally and
# the dangerous ones reachable only by writing down why.
#
# A plain function, not a NixOS module -- the same convention nixtest's own `lib.mkEfiDisk` uses,
# for the same reason: a caller that already has `lib` needs no module system to merge a returned
# attrset into its own rendering pass. It is also why this file re-implements validation as
# `throw` rather than `assertions`: a GitOps renderer evaluating a plain function has no
# `config.assertions` to collect, so the guard has to live where the render happens or it does not
# exist at all.
#
# ── WHY THE DEFAULTS ARE INVERTED, AND WHY THE INVERSION HAS TO LIVE *HERE* ─────────────────────
#
# Crossplane's own defaults are `managementPolicies: ["*"]` (every action) and `deletionPolicy:
# Delete`. Both are correct for the use case Crossplane was designed around -- a control plane that
# CREATES the resources it manages, where "make reality match the spec" and "remove the resource
# when its declaration goes away" are exactly what you want.
#
# They are exactly backwards for the use case this repo exists for: ADOPTING resources that already
# exist and are already in production. Two concrete failures, in the order they bite:
#
#   1. A freshly-applied CR with `managementPolicies` OMITTED inherits `["*"]`, which includes
#      Update. Crossplane treats `spec.forProvider` as the source of truth. On the FIRST reconcile
#      it therefore converges the live resource to whatever the spec happens to say -- and the spec
#      of a just-written adoption manifest is, by definition, a partial, hand-transcribed guess at
#      what the live resource looks like. Reading crossplane-runtime's own reconciler makes the
#      timing unambiguous: when the observation is not up to date, the diff is logged at DEBUG
#      level and then `external.Update()` is called IN THE SAME RECONCILE PASS. There is no
#      pause, no confirmation, and no drift-detected status condition to notice first.
#   2. A CR with `deletionPolicy` omitted inherits `Delete`, so removing the declaration -- a
#      refactor, a rename, a file moved between directories in a GitOps repo, an Argo CD prune --
#      destroys the real resource.
#
#   Nothing about either failure is loud. Which is why the inversion cannot be documentation: it has
#   to be the default value of the thing that renders the manifest.
#
# ⚠ AND THE INVERSION ONLY PROTECTS WHAT GOES THROUGH THIS FUNCTION. A hand-written CR alongside a
# nixiac-rendered one gets Crossplane's defaults, not nixiac's, and looks no different in a
# directory listing. That is the honest limit of this mechanism, stated here rather than left to be
# discovered: `nixiac.defaults.*` is a fact this function reads, not a policy applied to a cluster.
#
# ── `Synced=True` DOES NOT PROVE AN ADOPTION IS CORRECT ────────────────────────────────────────
#
# Worth stating next to the option that makes observe-only the default, because it is the natural
# next mistake: an observe-only resource whose `spec.forProvider` is wildly wrong still reports
# `Synced=True`. In crossplane-runtime's reconciler, when the resource is not up to date and the
# policy does not permit Update, the diff is logged at DEBUG and the reconcile is then marked
# successful. The condition means "the controller ran without error", not "your declaration matches
# reality". Proving an adoption is correct needs an out-of-band three-way diff between the
# declaration, `status.atProvider`, and the provider's own view -- and it must be done WITHOUT
# adding `LateInitialize`, which answers the question by rewriting the spec to match reality and
# making the evidence disappear.
#
# ── WHY `scope` EXISTS, AND WHY `deletionPolicy` IS SOMETIMES OMITTED ON PURPOSE ────────────────
#
# Crossplane v2 ships two generations of managed-resource kinds side by side, and every upjet
# provider surveyed carries parallel `cluster` and `namespaced` API trees:
#
#   scope = "cluster"     -- the legacy, cluster-scoped kinds. BOTH `spec.deletionPolicy` and
#                            `spec.managementPolicies` exist. crossplane-runtime reconciles the two
#                            through a legacy resolver that prefers managementPolicies whenever it
#                            is non-default.
#   scope = "namespaced"   -- the modern v2 kinds. `spec.managementPolicies` only. There is NO
#                            `deletionPolicy` field: the modern resolver is constructed without
#                            one.
#
# So on a namespaced resource this function EMITS NO `deletionPolicy` KEY, and that is not a lost
# guarantee -- orphan-on-delete on a modern kind comes from the ABSENCE of `Delete` in
# `managementPolicies`, which nixiac's default `[ "Observe" ]` already gives. `deletionPolicy =
# "Orphan"` is the legacy-kind restatement of the same promise, on a field that is itself
# deprecated in favour of managementPolicies.
#
# What this function refuses to do is silently drop a request. Asking for `deletionPolicy =
# "Delete"` on a namespaced resource is a throw, not a quiet omission, because the field would not
# reach the cluster while the operator would have every reason to believe it had.
#
# ── WHY `externalName` IS REQUIRED AND NEVER DEFAULTED FROM THE RESOURCE NAME ───────────────────
#
# `crossplane.io/external-name` is the annotation that answers "which real object is this CR
# about". For most resource types Crossplane DEFAULTS it from `metadata.name` -- which is exactly
# the wrong behaviour for adoption, because `metadata.name` is a Nix attribute name chosen for
# readability in a config file, and the live resource's identifier is whatever the cloud already
# calls it. Defaulting would silently point the CR at an object that does not exist (best case:
# "not found" on first reconcile) or at a DIFFERENT object that happens to share the name (worst
# case: an adoption of the wrong thing, reported as success).
#
# For resource types whose identifier is CLOUD-ASSIGNED rather than operator-chosen -- upjet
# configures these with `config.IdentifierFromProvider`, which disables the
# default-from-object-name behaviour and instead refreshes the annotation from the provider's own
# reported id -- there is additionally no way to have Crossplane discover the value for you before
# the first observe. The operator must supply the correct pre-existing id, and getting it wrong
# adopts the wrong object. Either way the answer is the same: nixiac makes it a required field with
# no default.
#
# ⚠ `initProvider` IS EMITTED BUT ITS ADOPTION BEHAVIOUR IS UNVERIFIED. `spec.initProvider` is the
# analogue of Terraform's `ignore_changes`, and it is the only lever that keeps a converging
# resource from fighting an out-of-band change to a field. Its own generated documentation says
# those values are merged "when the resource is created" -- and a resource nixiac ADOPTS is never
# created by Crossplane. Whether the merge applies at all on an adopted resource has not been
# proven either way here, so this function renders the field as given and does not pretend to a
# guard it has not measured. See `experiments/README.md` #002.
{ lib
, apiVersion
, kind
, name
, scope ? "namespaced"
, namespace ? null
, externalName ? null
, forProvider ? { }
, initProvider ? null
, providerConfigRef ? null
, managementPolicies ? [ "Observe" ]
, deletionPolicy ? "Orphan"
, acknowledgeDangerous ? null
, labels ? { }
, annotations ? { }
}:

let
  actions = import ./management-actions.nix { };

  # A string is "blank" if it is empty or nothing but whitespace. Used for every field where an
  # empty string would be accepted by the type system and then mean something wrong at reconcile
  # time -- an `externalName` of "" adopts nothing, an acknowledgement of "   " is not a reason.
  blank = s: !(builtins.isString s) || builtins.match "[[:space:]]*" s != null;

  # `toString` on both, deliberately: a caller that passed `null` for `kind` or `name` must still
  # get this function's own message, not a Nix type error from inside the message itself.
  require = cond: message:
    if cond then true
    else throw "nixiac.mkManagedResource (${toString kind} \"${toString name}\"): ${message}";

  # ── Shape checks: the fields that make a CR addressable at all ─────────────────────────────
  # A CR missing any of these is not a partially-configured resource, it is not a Kubernetes
  # object -- the API server rejects it outright, and a GitOps renderer will happily commit it
  # first.
  shapeOk =
    require (!(blank apiVersion))
      "`apiVersion` is required. It is the provider's own API group and version (the group is chosen by the provider, not by Crossplane), so it can only be read off the installed CRDs -- guessing it renders an object the API server rejects as an unknown kind."
    && require (!(blank kind)) "`kind` is required."
    && require (!(blank name)) "`name` is required -- it becomes `metadata.name`."

    && require (lib.elem scope [ "namespaced" "cluster" ])
      "`scope` must be \"namespaced\" (the modern v2 kinds) or \"cluster\" (the legacy kinds), got \"${toString scope}\". The two generations have different spec fields; see this file's header."

    && require (scope != "namespaced" || !(blank namespace))
      "`scope = \"namespaced\"` requires a `namespace`. A namespaced object with no namespace is applied into whatever namespace the client happens to default to, which for a GitOps renderer is the renderer's own -- not a placement anyone declared."

    && require (scope != "cluster" || namespace == null)
      "`scope = \"cluster\"` must not carry a `namespace`. A cluster-scoped object's namespace is silently ignored, so setting one records an intent that never takes effect.";

  # ── external-name: required, never defaulted ───────────────────────────────────────────────
  externalNameOk =
    require (!(blank externalName))
      "`externalName` is required and is never defaulted from `name`. `metadata.name` is an attribute name chosen for readability; the annotation `crossplane.io/external-name` decides WHICH REAL OBJECT this CR adopts. Letting it default points the CR at whatever object happens to share the config's own naming, and an adoption of the wrong object reports success. See this file's header.";

  # ── managementPolicies: the vocabulary, then the intent gate ───────────────────────────────
  illegalActions = lib.filter (a: !(lib.elem a actions.legal)) managementPolicies;

  # A rejected name gets its own reason back (what to write instead) rather than a bare "not in
  # the enum" -- the whole value of catching this at build time is saying what was meant.
  # The table's reasons are written as multi-line prose; reflow them onto one line so a list of
  # several bad values stays readable in a build failure.
  oneLine = s: lib.concatStringsSep " " (lib.filter (l: l != "") (lib.splitString "\n" s));

  illegalActionDetail = a:
    if actions.rejected ? ${a}
    then "  \"${a}\": ${oneLine actions.rejected.${a}}"
    else "  \"${a}\": not a member of the managementPolicies enum.";

  dangerousActions = lib.filter (a: lib.elem a actions.intentRequired) managementPolicies;

  policiesOk =
    require (managementPolicies != [ ])
      "`managementPolicies` must not be empty. An empty list declares no actions at all, so not even Observe applies -- the CR reads nothing, publishes no `status.atProvider`, and is indistinguishable from a typo. The safe minimum is [ \"Observe\" ]."

    && require (illegalActions == [ ])
      ''
        `managementPolicies` contains ${toString (lib.length illegalActions)} value(s) the API server rejects:
        ${lib.concatStringsSep "\n" (map illegalActionDetail illegalActions)}
        The accepted set is exactly: ${lib.concatStringsSep ", " actions.legal}.
        This is caught here rather than at apply time because a rejected enum member fails inside a
        controller log in a cluster, long after the manifest rendered, committed and synced cleanly.
      ''

    && require (dangerousActions == [ ] || !(blank acknowledgeDangerous))
      ''
        `managementPolicies` asks for ${lib.concatStringsSep ", " dangerousActions}, and `acknowledgeDangerous` is unset.

        `Observe` is the only action nixiac applies without a written reason, because it is the only
        one that cannot change or destroy a resource that already exists:
          Create          -- makes a SECOND resource if `externalName` does not match the live one.
          Update          -- converges the live resource to `spec.forProvider` in the same reconcile
                             pass the drift is noticed. No confirmation, no drift condition.
          Delete          -- destroys the real resource when this CR is removed.
          LateInitialize  -- rewrites your own spec to match reality, which makes a wrong
                             declaration look correct and destroys the evidence an adoption gate
                             depends on.
          *               -- all of the above. It is Crossplane's own default, which is why
                             OMITTING the field is the most dangerous possible value.

        Set `acknowledgeDangerous` to a sentence saying why this specific resource needs it. A
        sentence, not a boolean: it lands in the diff, it is readable by whoever inherits this, and
        it cannot be set by reflex the way `= true` can.
      '';

  # ── deletionPolicy: legal value, scope-appropriate, and gated the same way ─────────────────
  deletionOk =
    require (lib.elem deletionPolicy actions.legalDeletionPolicies)
      "`deletionPolicy` must be one of ${lib.concatStringsSep ", " actions.legalDeletionPolicies}, got \"${toString deletionPolicy}\"."

    && require (scope != "namespaced" || deletionPolicy == "Orphan")
      ''
        `deletionPolicy = "${toString deletionPolicy}"` was requested on a `scope = "namespaced"`
        resource, and the modern v2 managed-resource kinds have no `deletionPolicy` field at all --
        crossplane-runtime constructs the modern policy resolver without one. Rendering it would
        produce a manifest that either loses the key or is rejected for an unknown field, while the
        operator has every reason to believe the request took effect.

        On a namespaced kind, deletion behaviour comes from `managementPolicies` alone: the absence
        of `Delete` IS orphan-on-delete. If you genuinely want Crossplane to destroy this resource,
        add "Delete" to `managementPolicies` (which requires `acknowledgeDangerous`) rather than
        setting a field that does not exist here.
      ''

    && require (deletionPolicy != "Delete" || !(blank acknowledgeDangerous))
      ''
        `deletionPolicy = "Delete"` was requested and `acknowledgeDangerous` is unset.

        This is the field that decides what happens to a REAL cloud resource when its declaration
        goes away -- and a declaration goes away for reasons that have nothing to do with intent: a
        rename, a refactor, a file moved between directories, a GitOps prune of a path that stopped
        being rendered. `Orphan` (nixiac's default) makes that class of accident a no-op. `Delete`
        makes it destructive.

        Set `acknowledgeDangerous` to a sentence saying why this resource's lifecycle genuinely
        belongs to the control plane.
      '';

  validated = shapeOk && externalNameOk && policiesOk && deletionOk;

  # Every check above is forced before anything is returned. Without this, a caller that only ever
  # reads `.metadata` would never force `spec`, and the policy gate -- the entire point of the
  # function -- would be a lazily-unevaluated thunk. Same class of gap as `builtins.deepSeq` on a
  # single-element list in nixstorage's own disk table: a guard nothing forces is not a guard.
  guard = v: if validated then v else throw "unreachable";

  spec =
    { inherit managementPolicies forProvider; }
    // lib.optionalAttrs (scope == "cluster") { inherit deletionPolicy; }
    // lib.optionalAttrs (initProvider != null) { inherit initProvider; }
    // lib.optionalAttrs (providerConfigRef != null) { providerConfigRef = { name = providerConfigRef; }; };

in
guard {
  inherit apiVersion kind spec;

  metadata =
    {
      inherit name;
      annotations = { "crossplane.io/external-name" = externalName; } // annotations;
    }
    // lib.optionalAttrs (labels != { }) { inherit labels; }
    // lib.optionalAttrs (namespace != null) { inherit namespace; };
}
