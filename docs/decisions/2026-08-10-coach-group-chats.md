# Coach group chats — booker-scoped, AI-addressable by name

**Date:** 2026-08-10 · **Decided by:** owner, direct · **Status:** recorded, not built

## The decision, in the owner's words

> "it's essentially the ability to invite any individual to whatever group chat needed,
> more so for now focus on the ability for a coach to create a groupchat between him and
> the respected individuals that book his platform, so if he needs to create a groupchat
> for a group training, this way he can message x to help him. And he let's say he names
> the group chat Monday at noon, he can also ask the AI chatbox to say 'message monday
> noon' that practice has been cancelled, or practice has blank or blank etc."

## Scope narrowing

This **supersedes the priority** in
[2026-08-10-org-membership-invites.md](./2026-08-10-org-membership-invites.md). The
Slack-like cross-org invite model is still the destination, but the near-term target is
smaller and does not require an auth boundary:

> A coach creates a named group chat containing the families who booked his sessions,
> and can address that group by name through the AI chatbox.

Org membership stays parked. This is the piece to build.

## What already exists

The group-chat feature is **substantially built**. `sporve-web.host.html`:

| Piece | Line | Note |
|---|---|---|
| `kind: "direct" \| "group"` on conversations | `5390` | groups are a filter, not a separate screen |
| Group/Direct tab switch | `5399-5403` | `S.inboxTab` |
| Named groups | `5392`, `8043` | `c.name` — "Monday at noon" works today |
| "+ New group" → modal | `5398`, `5779`, `8028` | |
| Member picker, shared with "Add people" | `5583`, `5791` | one control, learned once |
| Create handler | `8031-8047` | writes `{id, kind, name, members}` |
| Per-sender attribution in group threads | `5437` | `m.from` shown only when `isGroup` |
| Empty state specific to groups | `5407-5412` | |

So "name a group and message it" is done. Two things are not.

## Gap 1 — the member pool excludes the people the owner named

`providerPeople()` (`:5570-5581`) builds the pickable pool from exactly three sources:

```text
SEED.teams[].roster[]        -> team rosters
S.trainers[]                 -> the coach's own staff
S.conversations (direct)     -> anyone who already DM'd him
```

**`S.bookings` is not among them.** A family who booked a session but never sent a direct
message cannot be added to a group. That is precisely the population the owner named —
"the respected individuals that book his platform" — and it is the natural roster for a
group-training chat.

Fix: add bookings as a fourth source, deduped by the existing `seen` name key, labelled
with the program they booked so the coach can tell two Sarahs apart. `S.bookings` carries
`athlete`, `program`, `programId`; the pool entry needs `{id, name, role}`.

## Gap 2 — no AI action layer exists

Verified absent. `sig-ai-coach` (`:2757-2778`, `:6462`) is **CSS and markup only** — a
parent-side *coach-finder* demo on a marketing page. There is no coach-side assistant, and
critically **no action-execution layer**: nothing anywhere in `src/` maps a typed
instruction onto a state mutation.

"Message Monday noon that practice is cancelled" requires three things that do not exist:

1. **Intent parse** — recognise `message <group-name> <body>` as an addressed send.
2. **Group resolution by fuzzy name** — "monday noon" must match a group named
   "Monday at noon". Case-insensitive, whitespace-tolerant, and it must handle *no match*
   and *ambiguous match* as first-class outcomes rather than guessing.
3. **Confirm-before-send.** An AI that broadcasts to a roster of families on a
   misparse is worse than one that asks. The send should be previewed and confirmed.

## Judgement calls to confirm

1. **Bookers are addable but not auto-added.** A booking should make someone *pickable*,
   not silently drop them into a group — the coach chooses. Say so if you want a
   one-click "add everyone who booked Monday 12pm" instead; that is a different and
   arguably better control for group training.
2. **Confirm-before-send on AI broadcasts.** Recommended, since the blast radius is every
   family on the roster. Overrule if you want it to send immediately.
3. **Demo-only.** This is client-side `S.*` state on a static page. Real group messaging
   needs the `org_members`-style membership table and RLS from the other decision record;
   nothing here should be mistaken for a backend.

## Not started

Blocked behind PR #48 (fee incidence), which touches the same host file.
