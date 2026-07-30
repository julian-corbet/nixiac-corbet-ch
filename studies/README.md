# studies

Written-up findings: results worth keeping, with enough context that someone
other than the author can understand what was tried, what was measured, and
what was concluded. This is where a promising result from
[`../experiments/`](../experiments/README.md) lands once it has been turned
into something durable.

A study earns its place here once it changed a decision in the main project.
Each one below names which.

⚠ **Provenance is stated per study, and two of the three are not our own
measurements.** A survey of upstream source and documentation is a legitimate
finding — it settled a real disagreement and changed real code here — but it
is a different kind of evidence from something this repo ran, and conflating
the two is how a citation quietly becomes a claim. Each study says which it
is in its first paragraph.

- [`management-policy-vocabulary.md`](management-policy-vocabulary.md) —
  **source survey.** Two independent surveys of Crossplane's
  `managementPolicies` enum disagreed, and the published documentation was
  wrong about a third thing. Reading the kubebuilder annotation in the source
  settled it. Changed: the accepted enum, the rejected-names table with
  "what to write instead", and the decision to type the option loosely so the
  *assertion* is the guard.
- [`crd-footprint.md`](crd-footprint.md) — **source survey.** Why a control
  plane's CRD count is a memory budget rather than tidiness: the numbers
  behind provider families and behind the newer per-type activation
  mechanism, and the default that silently cancels the second one. Changed:
  `modules/activation.nix` exists at all, and `nixiac.helmRelease.values`
  carries the wiring that makes it take effect.
- [`readonly-options-with-defaults.md`](readonly-options-with-defaults.md) —
  **measured here.** A `readOnly` NixOS option that also declares a `default`
  fails every evaluation with "set multiple times", including the one this
  repo hit. Reproduced down to a two-line module. Changed:
  `nixiac.helmRelease` declares no default, with the reason written next to
  the absence so nobody helpfully adds one back.

See the main [README](../README.md) for the project itself, and
[`../docs/design.md`](../docs/design.md) for the reasoning already settled
well enough to state as a decision rather than a finding.
