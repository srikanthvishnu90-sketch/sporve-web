# Sporv launch state

Updated: 2026-09-10
Overall: INITIALIZING — no acceptance criterion credited.

This file is the progress authority. A checked criterion must identify its
actual verification output and tested commit; a commit message alone is not
proof. Parked criteria stay explicitly labelled PARKED, never green.

## Initialization

- First action: read `docs/launch/STATE.md` on the source repository's main.
- Actual result: GitHub API404, Not Found.
- The owner's supplied message ended at "instead pick" and contained no state
  template. This minimal bootstrap does not claim to reproduce that missing
  template.
- Canonical prompt source requested by owner: `docs/launch/PROMPTS.md`.
  It has not yet been read in this initialization step.
- Existing work is not automatically promoted to completed acceptance.

## Prompts

| Prompt | Status | Acceptance evidence |
| --- | --- | --- |
| 1 | NOT DONE | Awaiting canonical acceptance import and verification. |
| 2 | NOT DONE | Awaiting canonical acceptance import and verification. |
| 3 | NOT DONE | Awaiting canonical acceptance import and verification. |
| 4 | NOT DONE | Awaiting canonical acceptance import and verification. |
| 5 | NOT DONE | Awaiting canonical acceptance import and verification. |
| 6 | NOT DONE | Awaiting canonical acceptance import and verification. |

## PARKED

None. Missing evidence is not a pass, and no launch risk has been accepted.

## NEXT

Read `docs/launch/PROMPTS.md` and the binding repository instructions,
enumerate each exact acceptance criterion here, then work the first unchecked
criterion in Prompt1. If the canonical file is absent, record that fact and
recover the owner's available prompt specifications without inventing the
truncated instructions.

## Evidence log

- 2026-09-10: initial STATE.md read returned GitHub API404.
- This bootstrap commit adds only STATE.md; it changes no runtime,
  database, credentials, payment, deployment or existing agent-owned file.
