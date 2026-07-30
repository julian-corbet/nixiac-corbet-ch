# checks/managed-resource.nix
#
# The `lib.mkManagedResource` check group. Free -- no NixOS evaluation, no build, no cluster: the
# function under test is a plain function over plain data, so every property of it is a property of
# one `let` binding.
#
# ⚠ WHY `tryEval` AND NOT `assertions`. `lib.mkManagedResource` deliberately guards with `throw`
# rather than `config.assertions`, because a GitOps renderer calling a plain function has no
# `config.assertions` to collect -- so a guard living there would not exist at all for the caller
# this function is actually FOR. That makes `builtins.tryEval` the only way to observe the guard, and
# it comes with a constraint worth writing down: `tryEval` intercepts `throw` and `assert`, and does
# NOT intercept `abort` or an infinite recursion. Every guard in that file is therefore a `throw`, on
# purpose. If one is ever converted to an `abort`, the check for it here stops being a check and
# starts aborting this whole evaluation.
#
# `builtins.deepSeq` inside each probe, not a bare force: the guards live in a `let` binding the
# returned attrset's own laziness would otherwise never reach, and a guard nothing forces is not a
# guard. That is exactly the gap `lib/managed-resource.nix`'s own `guard` binding closes on the
# production side -- checking it here from the outside proves the closure works rather than assuming
# it.
{ lib, mkManagedResource }:

let
  check = name: ok: detail: { inherit name ok detail; };

  # A complete, valid, ADOPTING resource -- observe-only, orphan-on-delete, an explicit external
  # name. Every negative fixture below is this, with exactly one thing changed.
  baseArgs = {
    inherit lib;
    apiVersion = "example.example-cloud.crossplane.io/v1beta1";
    kind = "Example";
    name = "an-example";
    namespace = "example-ns";
    externalName = "the-identifier-the-cloud-already-uses";
    providerConfigRef = "example-cloud";
    forProvider = { region = "somewhere"; };
  };

  render = args: mkManagedResource (baseArgs // args);

  # Forces the whole returned structure, so a guard hiding behind a lazy attribute cannot escape.
  throws = args: !(builtins.tryEval (builtins.deepSeq (render args) true)).success;
  renders = args: (builtins.tryEval (builtins.deepSeq (render args) true)).success;

  base = render { };
  clusterScoped = render { scope = "cluster"; namespace = null; };

  # ── A local plain-data scan ─────────────────────────────────────────────────────────────────
  # The rendered object has to survive being serialised: a GitOps renderer turns it into JSON (a
  # strict subset of YAML 1.2), and a source parser reads it without evaluating anything. A
  # derivation, a function, a path, or a string carrying store context all break that -- and the
  # first one breaks it in the worst way, by dragging a build in behind a fact somebody only wanted
  # to READ. Written out here rather than imported from a sibling fixture library, because this repo
  # takes no flake input on any other nix* repo, ever.
  impurePaths = prefix: v:
    if builtins.isAttrs v then
      (if v ? outPath || v ? drvPath || (v.type or null) == "derivation"
      then [ "${prefix} (a derivation -- reading this fact forces a build)" ]
      else lib.concatLists (lib.mapAttrsToList (n: sub: impurePaths "${prefix}.${n}" sub) v))
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: sub: impurePaths "${prefix}[${toString i}]" sub) v)
    else if builtins.isFunction v then [ "${prefix} (a function)" ]
    else if builtins.isPath v then [ "${prefix} (a path -- copies the file into the store)" ]
    else if builtins.isString v && builtins.hasContext v then [ "${prefix} (a string carrying store context)" ]
    else [ ];

in
{
  results = [
    # ── the base fixture must render, or every negative check below proves nothing ───────────────
    (check "mr/valid-adoption-renders"
      (renders { })
      "the base valid adoption fixture must render -- if it throws, every negative check in this group is proving nothing")

    # ── the inverted defaults, actually stamped ──────────────────────────────────────────────────
    (check "mr/defaults-to-observe-only"
      (base.spec.managementPolicies == [ "Observe" ])
      "an unspecified managementPolicies must render [ \"Observe\" ], not Crossplane's own [ \"*\" ] -- got ${builtins.toJSON base.spec.managementPolicies}")

    (check "mr/namespaced-omits-deletionPolicy"
      (!(base.spec ? deletionPolicy))
      "a namespaced (modern v2) resource must carry NO deletionPolicy field -- the modern kinds have none, and orphan-on-delete comes from the absence of Delete in managementPolicies instead")

    (check "mr/cluster-scoped-emits-orphan-deletionPolicy"
      (clusterScoped.spec.deletionPolicy == "Orphan")
      "a cluster-scoped (legacy) resource must default to deletionPolicy = \"Orphan\", not Crossplane's own \"Delete\" -- got ${toString (clusterScoped.spec.deletionPolicy or "<absent>")}")

    (check "mr/external-name-annotation-is-rendered"
      (base.metadata.annotations."crossplane.io/external-name" == "the-identifier-the-cloud-already-uses")
      "the external-name annotation must carry the declared identifier -- it is what decides WHICH real object this CR adopts")

    (check "mr/providerConfigRef-is-rendered-as-a-name"
      (base.spec.providerConfigRef == { name = "example-cloud"; })
      "providerConfigRef must render as { name = ...; } -- got ${builtins.toJSON (base.spec.providerConfigRef or null)}")

    (check "mr/forProvider-is-passed-through-verbatim"
      (base.spec.forProvider == { region = "somewhere"; })
      "forProvider must be passed through untouched -- nixiac knows no provider's schema and must not reshape it")

    (check "mr/namespace-is-rendered-for-a-namespaced-resource"
      (base.metadata.namespace == "example-ns")
      "a namespaced resource must carry its namespace")

    (check "mr/cluster-scoped-carries-no-namespace"
      (!(clusterScoped.metadata ? namespace))
      "a cluster-scoped resource must carry no namespace -- setting one records an intent that is silently ignored")

    # ── externalName: required, never defaulted from `name` ───────────────────────────────────────
    (check "mr/missing-externalName-throws"
      (throws { externalName = null; })
      "expected a missing externalName to throw, but it rendered -- letting it default from metadata.name points the CR at whatever object happens to share the config's naming, and adopting the wrong object reports success")

    (check "mr/blank-externalName-throws"
      (throws { externalName = "   "; })
      "expected a whitespace-only externalName to throw, but it rendered")

    (check "mr/externalName-is-not-silently-set-from-name"
      (base.metadata.annotations."crossplane.io/external-name" != base.metadata.name)
      "the fixture's externalName and name differ on purpose -- if these were ever equal, this group could not tell a real external name from a defaulted one")

    # ── the vocabulary check ─────────────────────────────────────────────────────────────────────
    (check "mr/illegal-action-Orphan-throws"
      (throws { managementPolicies = [ "Orphan" ]; })
      "expected \"Orphan\" as a management action to throw, but it rendered -- it is a legal deletionPolicy value and NOT a legal management action, and the API server rejects it at apply time in a controller log")

    (check "mr/illegal-action-MustCreate-throws"
      (throws { managementPolicies = [ "MustCreate" ]; })
      "expected \"MustCreate\" to throw, but it rendered -- the name comes from an unrelated test helper and has never been a member of the enum")

    (check "mr/illegal-action-FullControl-throws"
      (throws { managementPolicies = [ "FullControl" ]; })
      "expected \"FullControl\" to throw, but it rendered -- it is prose from the documentation; the API value meaning \"every action\" is the literal \"*\"")

    (check "mr/unknown-action-throws"
      (throws { managementPolicies = [ "Observe" "TotallyMadeUp" ]; })
      "expected an unknown action name to throw, but it rendered -- a name with no entry in the rejected-names table must still be refused, or the table becomes the allowlist")

    (check "mr/empty-managementPolicies-throws"
      (throws { managementPolicies = [ ]; })
      "expected an empty managementPolicies to throw, but it rendered -- not even Observe applies, so the CR reads nothing and is indistinguishable from a typo")

    # Every legal member must be ACCEPTED when acknowledged -- the other direction of the same
    # table. A vocabulary check that rejects a legal value is the failure nobody tests for.
    (check "mr/every-legal-action-is-accepted-when-acknowledged"
      (lib.all
        (a: renders {
          managementPolicies = [ a ];
          acknowledgeDangerous = "Exercising one legal action, for this repo's own checks.";
        })
        [ "Observe" "Create" "Update" "Delete" "LateInitialize" "*" ])
      "every member of the accepted enum must render when acknowledged -- if one is rejected, the vocabulary table and the API have drifted apart in the direction nobody notices")

    # ── the intent gate ──────────────────────────────────────────────────────────────────────────
    (check "mr/observe-only-needs-no-acknowledgement"
      (renders { managementPolicies = [ "Observe" ]; })
      "observe-only must never require an acknowledgement -- if it does, the gate is inverted and every safe resource is blocked")

    (check "mr/Update-without-acknowledgement-throws"
      (throws { managementPolicies = [ "Observe" "Update" ]; })
      "expected Update without an acknowledgement to throw, but it rendered -- Crossplane converges the live resource to spec.forProvider in the same reconcile pass the drift is noticed, with no confirmation step")

    (check "mr/Create-without-acknowledgement-throws"
      (throws { managementPolicies = [ "Observe" "Create" ]; })
      "expected Create without an acknowledgement to throw, but it rendered -- it makes a SECOND resource whenever the external name does not match the live one")

    (check "mr/Delete-without-acknowledgement-throws"
      (throws { managementPolicies = [ "Observe" "Delete" ]; })
      "expected Delete without an acknowledgement to throw, but it rendered")

    (check "mr/LateInitialize-without-acknowledgement-throws"
      (throws { managementPolicies = [ "Observe" "LateInitialize" ]; })
      "expected LateInitialize without an acknowledgement to throw, but it rendered -- it touches nothing in the cloud and destroys the evidence an adoption gate depends on, which is exactly why it is gated")

    (check "mr/wildcard-without-acknowledgement-throws"
      (throws { managementPolicies = [ "*" ]; })
      "expected [ \"*\" ] without an acknowledgement to throw, but it rendered -- it is Crossplane's own default, which is why OMITTING the field is the most dangerous possible value")

    (check "mr/dangerous-with-acknowledgement-renders"
      (renders {
        managementPolicies = [ "Observe" "Create" "Update" ];
        acknowledgeDangerous = "This control plane created this resource; nothing pre-existed it.";
      })
      "a written reason must actually unlock the dangerous policies -- a gate that cannot be opened is a prohibition wearing a gate's clothes")

    (check "mr/blank-acknowledgement-does-not-unlock"
      (throws {
        managementPolicies = [ "Observe" "Delete" ];
        acknowledgeDangerous = "  ";
      })
      "expected a whitespace-only acknowledgement to still throw, but it rendered -- the gate checks for content, not presence")

    (check "mr/acknowledgement-does-not-launder-an-illegal-action"
      (throws {
        managementPolicies = [ "Orphan" ];
        acknowledgeDangerous = "A reason cannot make an invalid enum member valid.";
      })
      "an acknowledgement must not launder an illegal action name -- the intent gate and the vocabulary check are separate guards and must stay separate")

    # ── deletionPolicy ───────────────────────────────────────────────────────────────────────────
    (check "mr/cluster-scoped-Delete-without-acknowledgement-throws"
      (throws { scope = "cluster"; namespace = null; deletionPolicy = "Delete"; })
      "expected deletionPolicy = \"Delete\" without an acknowledgement to throw, but it rendered -- a rename, a refactor, a moved file or a GitOps prune then destroys production infrastructure")

    (check "mr/cluster-scoped-Delete-with-acknowledgement-renders"
      (renders {
        scope = "cluster";
        namespace = null;
        deletionPolicy = "Delete";
        acknowledgeDangerous = "This resource is ephemeral and owned end to end by this control plane.";
      })
      "a written reason must actually unlock deletionPolicy = \"Delete\"")

    (check "mr/illegal-deletionPolicy-throws"
      (throws { scope = "cluster"; namespace = null; deletionPolicy = "Retain"; })
      "expected an unknown deletionPolicy to throw, but it rendered")

    # THE ONE THAT IS EASY TO GET WRONG, and the reason this function has a `scope` argument at all:
    # asking for Delete on a modern namespaced kind must be a hard error, not a quiet omission,
    # because the field does not exist there and the operator would believe the request took effect.
    (check "mr/namespaced-Delete-deletionPolicy-throws-rather-than-being-dropped"
      (throws { deletionPolicy = "Delete"; acknowledgeDangerous = "A reason does not create a field that the modern API does not have."; })
      "expected deletionPolicy = \"Delete\" on a namespaced resource to throw, but it rendered -- the modern kinds have no deletionPolicy field, so silently dropping it would leave the operator believing a destructive request had been recorded")

    (check "mr/namespaced-Orphan-deletionPolicy-is-accepted-and-omitted"
      (renders { deletionPolicy = "Orphan"; } && !(base.spec ? deletionPolicy))
      "the default \"Orphan\" must be accepted on a namespaced resource and simply not rendered -- it is the legacy-kind restatement of a guarantee managementPolicies already gives")

    # ── scope and namespace consistency ──────────────────────────────────────────────────────────
    (check "mr/unknown-scope-throws"
      (throws { scope = "global"; })
      "expected an unknown scope to throw, but it rendered")

    (check "mr/namespaced-without-namespace-throws"
      (throws { namespace = null; })
      "expected a namespaced resource with no namespace to throw, but it rendered -- it would be applied into whatever namespace the client defaults to, which for a renderer is the renderer's own")

    (check "mr/cluster-scoped-with-namespace-throws"
      (throws { scope = "cluster"; })
      "expected a cluster-scoped resource carrying a namespace to throw, but it rendered -- a silently ignored namespace records an intent that never takes effect")

    # ── shape ────────────────────────────────────────────────────────────────────────────────────
    (check "mr/missing-apiVersion-throws"
      (throws { apiVersion = null; })
      "expected a missing apiVersion to throw, but it rendered")

    (check "mr/missing-kind-throws"
      (throws { kind = null; })
      "expected a missing kind to throw, but it rendered")

    (check "mr/missing-name-throws"
      (throws { name = ""; })
      "expected an empty name to throw, but it rendered")

    (check "mr/null-kind-message-does-not-itself-crash"
      (
        let r = builtins.tryEval (builtins.deepSeq (render { kind = null; }) true);
        in !r.success
      )
      "a null `kind` must produce this function's own error and not a Nix type error from inside the error MESSAGE -- which is why the message interpolates toString on both kind and name")

    # ── initProvider: rendered as given, deliberately unguarded ──────────────────────────────────
    (check "mr/initProvider-is-rendered-when-given"
      ((render { initProvider = { region = "somewhere"; }; }).spec.initProvider == { region = "somewhere"; })
      "initProvider must reach the rendered spec -- it is the only ignore_changes analogue available")

    (check "mr/initProvider-is-absent-when-not-given"
      (!(base.spec ? initProvider))
      "initProvider must not be rendered as null when unset -- an explicit null is a different declaration from an absent field")

    # ── the output must survive serialisation ────────────────────────────────────────────────────
    (check "mr/output-is-plain-serialisable-data"
      (impurePaths "managedResource" base == [ ])
      "the rendered object must be plain data: ${lib.concatStringsSep ", " (impurePaths "managedResource" base)}. A renderer serialises it to JSON and a source parser reads it without evaluating anything -- a derivation in here would drag a build in behind a fact somebody only wanted to read")

    (check "mr/plain-data-scan-catches-a-derivation (meta-test)"
      (impurePaths "decoy" { welded = { type = "derivation"; outPath = "/nix/store/decoy"; }; } != [ ])
      "a decoy value carrying a derivation-shaped attrset was accepted by the plain-data scan -- the scan itself is broken, not the function under test")

    (check "mr/plain-data-scan-catches-a-function (meta-test)"
      (impurePaths "decoy" { welded = (x: x); } != [ ])
      "a decoy value carrying a function was accepted by the plain-data scan -- the scan itself is broken")

    # ── the forcing meta-test: the guards must not be escapable by laziness ──────────────────────
    # `lib/managed-resource.nix` routes its return value through a `guard` binding precisely so that
    # a caller reading ONE attribute still pays for the validation. Without it, `.metadata` would be
    # reachable without ever forcing `spec`, and every policy check above would be a thunk nobody
    # evaluated. This proves the closure from the outside.
    (check "mr/reading-metadata-alone-still-forces-the-guards"
      (
        !(builtins.tryEval
          (builtins.seq (render { managementPolicies = [ "*" ]; }).metadata.name true)
        ).success
      )
      "reading only metadata.name of an unacknowledged wildcard resource must still throw -- if it does not, every guard in lib/managed-resource.nix is escapable by simply not reading spec")
  ];
}
