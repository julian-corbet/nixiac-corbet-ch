# modules/manifests.nix
#
# THE ONE OUTPUT SURFACE: `nixiac.manifests` is an attribute set of Kubernetes objects, as plain
# Nix data, keyed by a short stable name. Every module in this repo contributes to it; nothing in
# this repo consumes it. Handing that attrset to a renderer is the whole delivery mechanism.
#
# ── WHY THIS IS ITS OWN FILE ────────────────────────────────────────────────────────────────────
#
# Both `control-plane.nix` and `activation.nix` write into this option, and both are exported
# STANDALONE (see flake.nix), so either one may be the only nixiac module a consumer imports. An
# option declared independently in two modules is a merge whose behaviour depends on the two
# declarations agreeing about type, default and `readOnly` forever -- so the declaration lives in
# one file that both import instead. Importing the same path twice is idempotent in the module
# system, which is what makes this work without either module knowing whether the other is present.
#
# ── WHY PLAIN DATA, AND NOT RENDERED YAML ───────────────────────────────────────────────────────
#
# Serialising to YAML needs a tool (`yq`, `remarshal`, `kubectl`), which means `pkgs`, which means
# this module could no longer be evaluated by anything but a full NixOS/nixpkgs evaluation, and its
# facts could no longer be read without dragging a build in behind them. JSON is a strict subset of
# YAML 1.2, so `builtins.toJSON` on each of these objects produces a document every Kubernetes
# client and every GitOps renderer already accepts -- with no tool, no derivation, and no store
# path anywhere in the path from declaration to manifest.
#
# That is also the property that makes this repo readable by a source PARSER rather than an
# evaluator. Measured on the hosts this family was built for: a full host evaluation is ~95 s and
# discards every comment on the way; importing a plain-data .nix file is ~0.021 s. Cloud
# infrastructure expressed as a general-purpose program is invisible to that parser; cloud
# infrastructure expressed as an attrset of facts is not.
#
# ── WHY IT IS NOT `readOnly`, AND WHAT GUARDS IT INSTEAD ────────────────────────────────────────
#
# `readOnly = true` permits exactly one definition, which would forbid the second module in this
# repo from contributing at all. So this option is writable, and a consumer may add its own objects
# to it -- which is genuinely useful (one attrset to hand to one renderer) and genuinely a hazard: a
# hand-added object with a typo'd `kind` renders, commits, syncs, and fails in a controller log.
# The `assertions` below close exactly that gap, for every object regardless of who put it there.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf;

  cfg = config.nixiac;

  # The three fields without which an entry is not a Kubernetes object at all. Deliberately not a
  # deeper schema: nixiac does not know any provider's CRD, and validating a `spec` it cannot know
  # the shape of is what the API server is for. This checks only what makes an object ADDRESSABLE.
  missingFields = name: m:
    lib.optional (!(m ? apiVersion) || m.apiVersion == null || m.apiVersion == "") "apiVersion"
    ++ lib.optional (!(m ? kind) || m.kind == null || m.kind == "") "kind"
    ++ lib.optional (!(m ? metadata) || !(m.metadata ? name) || m.metadata.name == null || m.metadata.name == "") "metadata.name";

  broken = lib.filterAttrs (name: m: missingFields name m != [ ]) cfg.manifests;
in
{
  options.nixiac.manifests = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
    example = lib.literalExpression ''
      {
        "provider-example-cloud" = {
          apiVersion = "pkg.crossplane.io/v1";
          kind = "Provider";
          metadata.name = "example-cloud";
          spec.package = "xpkg.crossplane.io/example-org/provider-example-cloud:v1.2.3";
        };
      }
    '';
    description = ''
      Every Kubernetes object this repo's modules render, keyed by a short stable name, as plain
      Nix data. This is nixiac's entire delivery surface: it installs nothing, applies nothing, and
      reaches no cluster. A consumer hands `lib.attrValues config.nixiac.manifests` (or
      `builtins.toJSON` of each) to whatever already turns declarations into cluster state --
      typically a GitOps renderer that commits them for Argo CD to sync.

      Keyed rather than a list on purpose: a key gives a consumer a stable name to override or drop
      one object without re-deriving the rest, and it makes a rendered diff readable when a version
      bump changes one manifest out of a dozen.

      A consumer may add its own objects here to get a single attrset to render. Every entry --
      contributed by this repo or by the consumer -- is asserted to carry `apiVersion`, `kind` and
      `metadata.name`, because an object missing any of those is rejected by the API server at
      apply time, which in a GitOps loop is long after it rendered, committed and synced cleanly.
    '';
  };

  config = mkIf (broken != { }) {
    assertions = [
      {
        assertion = false;
        message = ''
          nixiac.manifests: ${toString (lib.length (lib.attrNames broken))} entr(ies) are not
          addressable Kubernetes objects:
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (name: m: "  ${name}: missing ${lib.concatStringsSep ", " (missingFields name m)}")
            broken)}

          An object without apiVersion, kind and metadata.name cannot be applied. Caught here
          because the alternative is a manifest that renders, commits and syncs cleanly and then
          fails inside a controller log nobody is reading.
        '';
      }
    ];
  };
}
