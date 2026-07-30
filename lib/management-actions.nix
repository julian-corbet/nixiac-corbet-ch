# lib/management-actions.nix -- `lib.managementActions`
#
# THE VOCABULARY TABLE: the exact set of strings Crossplane's own API accepts in a managed
# resource's `spec.managementPolicies`, plus the names that LOOK like they belong there and are
# rejected on apply. Pure data -- no `pkgs`, no `lib`, no derivation, nothing to evaluate a system
# for. Exported as `lib.managementActions` so a consumer can inspect or validate the vocabulary
# without re-reading this file, the same reason nixstorage exposes `lib.partitionRoles`.
#
# ── WHY A TABLE AND NOT A HARDCODED `types.enum` INLINE ─────────────────────────────────────────
#
# Three consumers need the identical list and must never disagree about it: `modules/
# control-plane.nix` (validating `nixiac.defaults.managementPolicies`), `lib/managed-resource.nix`
# (validating a per-resource override at render time, where there is no module system to lean on),
# and `checks/` (proving both of the above fire on the violation and stay silent otherwise). Three
# transcriptions of one enum is the same drift nixstorage's own disk table exists to remove, one
# domain over.
#
# ── THE MEASURED FINDING THIS FILE RECORDS: TWO SOURCES DISAGREED, AND THE DOCS WERE WRONG ─────
#
# A first survey of Crossplane's management policies (2026-07-30) reported the accepted values as
# `Observe`, `Create`, `Update`, `Delete`, `LateInitialize`, `MustCreate`, `Orphan`, and `*`,
# citing a `crossplane-runtime` pull request that added an `Orphan` convenience action equal to
# "everything except Delete".
#
# A second pass read the kubebuilder `Enum` annotation in `crossplane/crossplane`'s own
# `apis/core/v2/policies.go` directly, and found the accepted set to be exactly:
#
#     Observe ; Create ; Update ; Delete ; LateInitialize ; *
#
# `Orphan` had zero hits anywhere in `crossplane-runtime` as a management ACTION, and the
# `MustCreate` hits turned out to be an unrelated test helper (`resource.MustCreateObject()`).
# The source wins over the survey and over the docs page, and the failure mode is what makes the
# distinction load-bearing rather than pedantic: an unknown enum member is rejected by the API
# server AT APPLY TIME, which in a GitOps loop means a manifest that renders cleanly, commits
# cleanly, syncs, and then fails inside a controller log nobody is reading -- while the operator
# who wrote `Orphan` believes they asked for "manage everything but never delete" and got it.
#
# `rejected` below turns each of those plausible-but-wrong names into a build-time error that says
# what to write instead. It is deliberately a table of NAMES, not a blocklist of behaviours: the
# point is to catch the transcription, not to have an opinion about the intent.
#
# ── WHY `Observe` IS THE ONLY ACTION THAT NEEDS NO WRITTEN REASON ───────────────────────────────
#
# `intentRequired` below is every action except `Observe`, and the grouping is not squeamishness
# about the word "delete". Each of the four does something a freshly-applied manifest against an
# ALREADY-EXISTING, in-production resource should never do by accident:
#
#   Create   -- creates a second resource if the external-name annotation does not actually match
#               the live one, so a typo becomes a duplicate instead of an error.
#   Update   -- Crossplane treats `spec.forProvider` as the source of truth and converges the live
#               resource to it IN THE SAME RECONCILE PASS the drift is noticed, with no
#               pause-for-confirmation and no drift-detected condition. A partially-filled
#               `forProvider` is therefore not "incomplete", it is a diff waiting to be applied.
#   Delete   -- destroys the real cloud resource when the CR is removed.
#   *        -- all of the above, and it is Crossplane's own DEFAULT, so OMITTING the field is the
#               most dangerous possible value.
#
#   LateInitialize -- looks harmless (it only writes back into your own spec) and is the one that
#               destroys EVIDENCE. During an adoption gate the whole question is "does my declared
#               spec match reality?"; late-initialisation answers it by rewriting the spec to match
#               reality, after which the diff is gone and the gate reports success regardless of
#               whether the declaration was ever right.
{}:
{
  # The exact kubebuilder Enum from crossplane/crossplane apis/core/v2/policies.go, in that
  # file's own order. Verified 2026-07-30 against the source, not against a docs page.
  legal = [ "Observe" "Create" "Update" "Delete" "LateInitialize" "*" ];

  # The one action that only ever READS. Populates `status.atProvider` from the live resource and
  # takes no create/update/delete action, ever.
  safe = [ "Observe" ];

  # Everything else: allowed, but only with a written reason. See this file's header for what each
  # one actually does to a resource that already exists and is in production.
  intentRequired = [ "Create" "Update" "Delete" "LateInitialize" "*" ];

  # `spec.deletionPolicy`, the OLD pre-managementPolicies field. Two legal values, and it exists
  # only on cluster-scoped (legacy) managed resource kinds -- see lib/managed-resource.nix's own
  # header for why the modern namespaced kinds have no such field at all, and why that is not a
  # gap.
  legalDeletionPolicies = [ "Orphan" "Delete" ];

  # Names that appear in blog posts, in pull-request titles, in other people's manifests, and in
  # at least one survey of this API -- and that the API server rejects. Keyed by the wrong name,
  # valued with what to write instead. See this file's header for how the disagreement was
  # settled.
  rejected = {
    Orphan = ''
      `Orphan` is a legal value of `spec.deletionPolicy`, but NOT of
      `spec.managementPolicies` -- the two fields are different generations of the same
      idea and do not share a vocabulary. If you meant "manage everything except
      deletion", write the set out: [ "Observe" "Create" "Update" "LateInitialize" ].
    '';

    MustCreate = ''
      `MustCreate` is not a management action. The name comes from an unrelated test
      helper in crossplane-runtime (`resource.MustCreateObject()`); it has never been a
      member of the managementPolicies enum.
    '';

    FullControl = ''
      `FullControl` is prose from the documentation, not an API value. The enum member
      that means "every action" is the literal string "*" -- which is also Crossplane's
      own default, and the single most dangerous value a nixiac-rendered manifest can
      carry. If you genuinely want it, ask for it by name and write down why.
    '';

    Ignore = ''
      `Ignore` is not a management action. A resource nixiac should look at but never
      touch is `[ "Observe" ]`; a resource nixiac should not render at all is one you
      leave out of the declaration entirely.
    '';
  };
}
