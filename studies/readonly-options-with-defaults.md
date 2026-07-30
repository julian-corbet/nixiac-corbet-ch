# A `readOnly` NixOS option must not declare a `default`

**Provenance: measured here, 2026-07-30, against nixpkgs
`nixos-unstable` @ `0954f7e`.** Reproduced down to a two-line module. This is
the one study in this directory that is this repo's own measurement rather
than a survey of somebody else's source.

## The symptom

`nixiac.helmRelease` was declared as a derived, read-only fact:

```nix
helmRelease = mkOption {
  type = types.attrs;
  readOnly = true;
  default = { };          # <- the problem
  description = "…";
};
```

with exactly one assignment, unconditional, in the same module. Every
evaluation that read it failed:

```
error: The option `nixiac.helmRelease' is read-only, but it's set multiple times.
Definition values:
- In `…/modules/control-plane.nix': { }
- In `…/modules/control-plane.nix':
    { chart = "crossplane"; namespace = "crossplane-system"; … }
```

Two definitions, both attributed to the same file, one of them an empty
attrset that does not appear anywhere in that file.

## The wrong diagnosis, and why it was tempting

The module's `config` was a `mkMerge` of three branches, two of them
`mkIf`-guarded and one of them writing a *sibling* key in the same namespace
(`nixiac.manifests`). The obvious reading was that `mkIf` on a sibling was
producing a spurious empty definition for the whole namespace — an
interaction between `mkMerge`, `pushDownProperties` and a namespace
containing several options.

That reading survived exactly one experiment. Rewriting the module's `config`
as a single flat attrset — no `mkMerge`, no `mkIf`, using `lib.optionals` and
`lib.optionalAttrs` for the conditional parts — reproduced the error
unchanged.

## The measurement

A two-line reduction, run three ways against the same nixpkgs:

```nix
{ config, lib, ... }:
let inherit (lib) mkOption types; cfg = config.tst; in {
  options.tst = {
    enable = mkOption { type = types.bool; default = false; };
    out    = mkOption { type = types.attrs; readOnly = true; default = { }; };
    other  = mkOption { type = types.attrs; default = { }; };
  };
  config = {
    tst.out   = { a = 1; };
    tst.other = lib.optionalAttrs cfg.enable { b = 2; };
  };
}
```

| Variant | Result |
|---|---|
| `mkMerge` + `mkIf`, `readOnly` **with** `default` | ❌ "set multiple times" |
| flat `config`, no `mkMerge` at all, `readOnly` **with** `default` | ❌ "set multiple times" |
| flat `config`, `readOnly` **without** `default` | ✅ `{"a":1}` |

The variable is the `default`, and nothing else. `mkMerge` and `mkIf` were
never involved.

## The finding

For an option with `readOnly = true`, a declared `default` counts toward the
definition count. One default plus one assignment is two definitions, and
`readOnly` permits at most one — so **any `readOnly` option that both
declares a default and is ever assigned fails every evaluation**, regardless
of how the assignment is written.

The corollary is that the combination is not merely redundant, it is
unusable: a `readOnly` option is either always assigned (and must have no
default) or never assigned (and the default is the only value, at which point
`readOnly` is guarding nothing anybody could have written).

## What it changed here

`nixiac.helmRelease` declares **no** `default`, and the absence carries its
own comment explaining why — pointing out that the assignment below it is
unconditional precisely so a consumer can read those facts whether or not
`nixiac.enable` is set, which means the default would never have been reached
anyway.

The comment exists because this is a textbook example of a change that looks
like an oversight. An option with no default is exactly what a tidy-up commit
adds one to, and the resulting failure is not local: it appears at every read
site, blames the file that declares the option, and lists an empty attrset
from nowhere. Writing the reason next to the absence is cheaper than
rediscovering it.

## What was not established

Why the default is counted as a definition rather than as a fallback — that
is a question about `lib/modules.nix`'s `mergeDefinitions` internals, and the
behaviour is consistent enough to design around without answering it. Whether
it is intended, a long-standing wart, or something that varies by nixpkgs
generation was not investigated; the measurement above is pinned to one
revision and says so.
