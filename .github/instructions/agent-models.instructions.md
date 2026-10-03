---
description: Which model to put in an agent definition, and the roster the names come from
applyTo: .github/agents/**
---

# Choosing the model for an agent

The `model:` field is matched against the picker string exactly. An unrecognized name falls back to
the chat default silently instead of raising an error, so a typo or an invented version number is a
bug you will not see. Never guess at a name and never assume a version bump exists because a sibling
model got one. There is a `Claude Sonnet 5.5` but no `Claude Haiku 5`.

If the model you want is not on the roster below, stop and ask for a fresh capture of the picker
rather than writing the name you expect to be there.

## Tiers

| Tier | Model | Use it for |
| --- | --- | --- |
| Deep reasoning | `Claude Opus 5.5` | Agent and prompt design, architecture calls, anything where a wrong decision is expensive to unwind |
| General | `Claude Sonnet 5.5` | Script edits, routing, research, and any prose that has to hold the house style |
| Constrained | `Claude Haiku 4.5` | Narrow rule-driven work that ends in a validation step strong enough to catch a mistake, such as a parse check |

The constrained tier is only safe where something downstream verifies the output. An agent whose
only check is its own judgement belongs on the general tier regardless of how small its job looks.

## Roster, captured from the picker 2026-10-02

Promoted: `Claude Opus 5.5`, `Claude Sonnet 5.5`, `Claude Opus 5`, `Claude Sonnet 5`, `GPT-6 Luna`,
`GPT-6.1 Sol`.

Other Claude entries: `Claude Fable 5`, `Claude Fable 5.1`, `Claude Haiku 4.5`, `Claude Opus 4.8`,
`Claude Opus 4.8 (fast mode) (Preview)`.

The roster goes stale on its own. Re-capture it with **Chat: Manage Language Models** from the
Command Palette when a model named here has disappeared, and update this file in the same change.

## Updating assignments

Each agent carries its own `model:` line, so this file guides the choice but does not override it.
Changing a tier here means editing the agent files that sit in that tier.
