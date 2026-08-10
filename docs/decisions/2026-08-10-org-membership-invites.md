# Organizations — invite-based membership, Slack-like

**Date:** 2026-08-10 · **Decided by:** owner, direct · **Status:** recorded, not built

## The decision, in the owner's words

> "Interms of organizations, Sporve in itself can communicate with their team members via
> invite, so if I login to sporve as a normal regular indiivfidual person, i can receive an
> invite to join a group and access the messages. Similar to slack."

And, on the money side of the same structure:

> "if i regoster a golf course, and they offer 3 coaches, then they handle the commision
> between the 88% of the trainings and how much each individual keeps"

## The model

An **organization** (golf course, club, academy, team) registers on Sporve and lists
services. Individual coaches/trainers exist as **ordinary Sporve accounts** — the same
account a parent or athlete would have. Membership is the join between them:

```
individual account  --invited-->  organization  --owns-->  listings, messages, schedule
```

Three properties that follow:

1. **Invite-based, not self-serve.** You do not "sign up as a coach at Apex FC"; the org
   invites you and you accept. A pending invite is a first-class state.
2. **One identity, many orgs.** A person logs in as themselves and may belong to several
   organizations — the Slack workspace model, not a separate per-org login.
3. **Membership gates messages.** Accepting an invite grants access to that group's
   messages. This is an authorization boundary, not a UI filter.

Money is unaffected by all of this: Sporve takes 12% of gross, the org receives 88%, and
the org divides that 88% among its people however it likes. Sporve does not arbitrate the
internal split. See [2026-08-10-fee-incidence.md](./2026-08-10-fee-incidence.md).

## What exists today

| Piece | Status | Evidence |
|---|---|---|
| Trainer roster on an org | present, demo data | `sporve-web.host.html:3117-3119` (`om_1..om_3`) |
| Invite form (name, specialty, commission) | present | `:5833-5836`, writes at `:8203` |
| `affiliation: "pending" \| "active"` | present as a field | `:3117-3119`, `:8203` |
| Commission display | present | `:5555` |
| Group messaging surface | present | `:5389` inbox tab |
| **Invite actually reaching a person's account** | **absent** | nothing links `om_*` to a login |
| **Accept/decline flow** | **absent** | `affiliation` is never transitioned by any handler |
| **Membership gating message access** | **absent** | inbox is not scoped by membership |

So the org side is modelled as a *roster the org owns*, and the owner is describing
something structurally different: a *relationship between two accounts*. The current demo
data cannot represent "I am one person in two organizations."

## Consequences for the backend

**[CRITICAL-PATH]** — this is an authorization boundary, so it is RED-set work:

- Needs a membership table (`org_members`: org_id, user_id, role, status, invited_by,
  invited_at, accepted_at) rather than trainers embedded in an org record.
- Needs RLS keyed on membership for messages: a user reads a group's messages **iff** an
  accepted membership row exists. A UI-only filter is not sufficient.
- Invite acceptance must be idempotent — a double-clicked accept link must not create two
  membership rows.
- Interacts with the existing `claim_organization_role` RPC already live in prod.

## Not started

Recorded only. Building this touches auth and RLS, which is RED under CLAUDE.md §12 —
draft and owner-applied, never auto-merged.
