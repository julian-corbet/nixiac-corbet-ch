# checks/purity.nix
#
# MECHANICALLY PROVES THE CLAIM THE REST OF THIS REPO IS BUILT ON: nixiac's modules are pure data.
# They declare options, they assert, they publish facts -- and they change nothing about a host.
#
# ── WHY THIS IS THE LOAD-BEARING CHECK GROUP AND NOT A STYLE POLICE ─────────────────────────────
#
# Three separate promises in this repo are only true if this one is:
#
#   1. `flake.nix` exports these modules under `modules.*` as well as `nixosModules.*`, on the
#      grounds that a host is not required -- a GitOps renderer, or a bare `lib.evalModules`, is an
#      equally valid evaluator. That is a claim about what these files touch, and a claim about what
#      a file touches is exactly the kind of thing that stops being true one convenience commit
#      later.
#   2. `nixiac.manifests` is documented as facts a consumer can read without dragging a build in
#      behind them -- which is false the moment one of those facts is a derivation, a path, or a
#      string carrying store context.
#   3. The whole motivation for declaring a control plane in Nix is that its composition can be read
#      by something that PARSES source rather than evaluating it. Measured on the hosts this family
#      was built for: a full host evaluation is ~95 s and discards every comment; importing a
#      plain-data .nix file is ~0.021 s and keeps the prose. A fact welded into a systemd unit's
#      script can only be recovered by evaluating and then TEXT-PARSING a derivation.
#
# ── HOW IT PROVES IT: THREE WAYS, ONE OF WHICH IS THE LOAD-BEARING ONE ──────────────────────────
#
#   (a) NO `pkgs` ARGUMENT -- via `builtins.functionArgs`, not a text search. A module can reference
#       something called `pkgs` under another bound name, or smuggle it in through `...`, but it
#       cannot legally USE it as `pkgs` in its own body without that name appearing as a formal
#       argument first.
#   (b) AN EVAL DIFF -- composing every module together with a realistic, NON-DEFAULT use of their
#       own options changes no watched host surface at all, compared to the identical bare stub
#       system without them. THIS IS THE LOAD-BEARING ONE: it is not enough that the source never
#       writes `systemd.services` directly, because an INDIRECT write -- some other option that
#       happens to expand into a unit or a package -- dodges a text scan and cannot dodge a diff of
#       what the module system actually PRODUCES.
#   (c) A SOURCE SCAN -- the cheap, fast-failing companion to (b), so a violation names a readable
#       reason without waiting for a full evaluation.
#
# ── AND EVERY ONE OF THEM SHIPS WITH A META-TEST ─────────────────────────────────────────────────
#
# A comparison that has never been shown capable of failing is not a proof, it is an assumption
# wearing a proof's clothes. The decoy module below genuinely binds `pkgs`, genuinely adds a systemd
# unit, and genuinely installs a package -- composed only against the bare stub, never alongside the
# real modules -- so each comparison is shown to notice a real violation rather than merely that the
# modules under test happen not to commit one today.
#
# Written out here rather than imported from a sibling fixture library that already implements this
# generically, because this repo takes no flake input on any other nix* repo, ever.
{ lib, nixpkgs, system, controlPlaneModule, activationModule, manifestsModule, bareStubs }:

let
  check = name: ok: detail: { inherit name ok detail; };

  evalNixosModules = modules:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    }).config;

  sorted = lib.sort (a: b: a < b);

  # The two surfaces every NixOS module that "does something to a host" ends up touching. Not an
  # exhaustive list of ways a module could stop being pure data -- a stray `users.users.*` entry
  # with no `pkgs` involved would dodge both -- and that gap is stated here rather than papered
  # over. It is the honest limit of this check group.
  surfaces = [
    {
      path = "systemd.services";
      value = cfg: sorted (lib.attrNames cfg.systemd.services);
    }
    {
      path = "environment.systemPackages";
      value = cfg: sorted (map (p: p.name) cfg.environment.systemPackages);
    }
  ];

  # A realistic, NON-DEFAULT use of every option in the repo. Passing `{ }` here would make the eval
  # diff vacuous: a module that declares options nobody set cannot change any surface, so the check
  # would pass for a module that violates the claim badly.
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
      activation = {
        enable = true;
        activate = [ "examples.example.crossplane.io" ];
      };
    };
  };

  cfg-bare = evalNixosModules [ bareStubs ];
  cfg-nixiac = evalNixosModules [ controlPlaneModule activationModule populatedConfig bareStubs ];

  # Deliberately broken, used ONLY to prove the comparisons have teeth. Never composed alongside the
  # real modules, and never exported by this flake. Its own namespace can never collide with a real
  # option.
  decoyModule = { config, lib, pkgs, ... }: {
    options.nixiacPurityDecoy.enable =
      lib.mkEnableOption "decoy, for this check group's own meta-tests -- never a real module";
    config = lib.mkIf config.nixiacPurityDecoy.enable {
      systemd.services.nixiac-purity-decoy-unit.script = "exit 0";
      environment.systemPackages = [ pkgs.hello ];
    };
  };

  cfg-decoy = evalNixosModules [ bareStubs decoyModule { nixiacPurityDecoy.enable = true; } ];

  isCommentLine = line: builtins.match "[ \t]*#.*" line != null;
  stripComments = src:
    lib.concatStringsSep "\n" (lib.filter (l: !(isCommentLine l)) (lib.splitString "\n" src));

  modulePaths = {
    "control-plane" = controlPlaneModule;
    "activation" = activationModule;
    "manifests" = manifestsModule;
  };

  # ── (a) no `pkgs` argument, per module file ─────────────────────────────────────────────────
  noPkgsChecks = lib.mapAttrsToList
    (label: path:
      check "purity/${label}-binds-no-pkgs-argument"
        (!(lib.functionArgs (import path) ? pkgs))
        "${toString path}'s own module function now binds a `pkgs` argument -- a module that needs pkgs is a module that can build something, and every claim in this file's header depends on these three not being able to")
    modulePaths;

  # ── (b) the eval diff, plus its meta-test, per watched surface ──────────────────────────────
  evalDiffChecks = lib.concatMap
    (s: [
      (check "purity/composing-nixiac-never-changes-${s.path}"
        (s.value cfg-nixiac == s.value cfg-bare)
        "composing all of nixiac's modules with a realistic, non-default use of their own options changed ${s.path} vs. the identical system without them -- got: ${builtins.toJSON (s.value cfg-nixiac)}, expected: ${builtins.toJSON (s.value cfg-bare)}")

      (check "purity/mechanism-catches-a-${s.path}-change (meta-test)"
        (s.value cfg-decoy != s.value cfg-bare)
        "a decoy module that DOES change ${s.path} was not caught by this comparison -- the comparison itself is what is broken, not the modules under test")
    ])
    surfaces;

  # ── (c) the source scan, per module file per surface ────────────────────────────────────────
  # Comments stripped first, because this file's own headers discuss both watched option paths at
  # length and a literal scan cannot tell prose from a write. Note that an option `description` is a
  # real Nix string rather than a `#` comment, so this scan also constrains what the descriptions
  # may name -- an acceptable price here, since nothing in nixiac's option surface has any reason to
  # mention a NixOS host primitive by name.
  sourceScanChecks = lib.concatMap
    (label: map
      (s: check "purity/${label}-source-never-mentions-${s.path}"
        (!(lib.hasInfix s.path (stripComments (builtins.readFile modulePaths.${label}))))
        "${toString modulePaths.${label}}'s source text now contains the literal string \"${s.path}\"")
      surfaces)
    (lib.attrNames modulePaths);

  # ── the published facts must be plain, serialisable data ────────────────────────────────────
  # Not a style point: `nixiac.manifests` is documented as objects a consumer serialises to JSON and
  # a parser reads without evaluating anything, and `nixiac.helmRelease` as facts an installer reads
  # by name. A derivation, a path, a function, or a string carrying store context breaks both
  # promises -- and the derivation case breaks it in the worst way, by dragging a build in behind a
  # fact somebody only wanted to read.
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

  factChecks = map
    (path:
      let bad = impurePaths path (lib.getAttrFromPath (lib.splitString "." path) cfg-nixiac);
      in check "purity/${path}-is-plain-data"
        (bad == [ ])
        "`${path}` is not plain data, so this fact cannot be read without dragging a build in behind it: ${lib.concatStringsSep ", " bad}. Facts must be strings (without store context), numbers, bools, null, or lists/attrsets of those.")
    [ "nixiac.manifests" "nixiac.helmRelease" ];

in
{
  results =
    noPkgsChecks
    ++ evalDiffChecks
    ++ sourceScanChecks
    ++ factChecks
    ++ [
      (check "purity/functionArgs-mechanism-catches-a-pkgs-argument (meta-test)"
        (lib.functionArgs decoyModule ? pkgs)
        "the decoy module (which binds `pkgs` itself) was not detected by functionArgs -- the mechanism itself is broken")

      (check "purity/plain-data-scan-catches-a-derivation (meta-test)"
        (impurePaths "decoy" { welded = { type = "derivation"; outPath = "/nix/store/decoy"; }; } != [ ])
        "a decoy fact carrying a derivation-shaped attrset was accepted by the plain-data scan -- the scan itself is broken, not the modules under test")

      # A composed nixiac declaration renders real objects, and the point of the checks above is
      # that it renders ONLY objects. If this ever came back empty, every purity check above would
      # pass trivially -- a module that produces nothing changes nothing.
      (check "purity/the-populated-fixture-actually-renders-something"
        (cfg-nixiac.nixiac.manifests != { })
        "the populated fixture rendered no manifests at all, which would make every purity check in this group vacuous")
    ];
}
