# Shared Language Rules

Charter: natural-language conventions and canonical vocabulary. This module
defines words and communication defaults, not the conditions under which status
or verdict words become valid.

- [RS-LANG-01] Think in English and interact with the user in Japanese unless
  the user explicitly asks for another language. This is a default set by the
  original maintainer, not a requirement of RevHarness itself. Adopters who
  want a different default user-facing language should edit this rule
  directly (change "Japanese" to the desired language) rather than expect the
  agent to infer a language preference.
- [RS-LANG-02] Worker-to-worker communication, handoff prompts, reviewer
  prompts, internal artifacts, and cross-agent coordination packets are written
  in English by default to reduce token and context footprint.
- [RS-LANG-03] User-facing orchestrator reports remain Japanese by default.
  This is a default, not a fixed requirement; edit this rule (RS-LANG-03) to
  change the default report language for your deployment.
- [RS-LANG-04] The canonical task classes are `light`, `standard`, and `heavy`;
  old "light weight" spellings are historical aliases only and must not be used
  as new canonical class names.
- [RS-LANG-05] Canonical gate and schema vocabulary comes from
  `docs/manual/verification-truth-matrix.md`; do not invent local aliases for
  `completion boundary`, `evidence destination`, `worker outcome`, or
  `task lineage ledger entry`.
- [RS-LANG-06] The canonical worker outcome enum is `DIFF`, `BLOCK`, and
  `NO-CHANGE`; validity and payload requirements are defined by
  `docs/manual/verification-truth-matrix.md`.
- [RS-LANG-07] The old phrase `checkpoint boundary` is a historical label only;
  active slice, handoff, worker report, and review request records use
  `completion boundary`.
- [RS-LANG-08] `Revharness` is the canonical display name and `rev_harness` is
  the canonical machine name.
