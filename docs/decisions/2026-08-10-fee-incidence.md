# Fee incidence — coach-side deducted

**Date:** 2026-08-10 · **Decided by:** owner, direct (not relayed) · **Status:** applied

## The decision, in the owner's words

> "if a parent pays 80% for a session we take 12% of it and the remainder goes to the
> coach, that is exactly what the 12% incumbent is. The way the platform works in grand
> sheme is that prcess, on the parent side, the you book a training session/camp/team etc,
> and then your done, the 12% fee comes out of the coach earnings"

## What it means

Sporve's 12% is a **share of the coach's price**, not a surcharge on it.

```text
Coach lists:        $100
Parent pays:        $100      <- the only number the family sees
Sporve's 12%:        $12      <- taken from the coach's side
Coach receives:      $88
```

The family books and is done. The fee never enters their total.

## What it supersedes

- `mod-payments.js` previously modelled **charged-on-top** (`total = gross + fee`),
  which showed a parent $112 on a $100 listing.
- `sporve-web.host.html` modelled **9% charged on top** — both the wrong rate and the
  wrong incidence. These survived `e373fda`, whose commit message claims the 9%
  constants were flattened but whose diff touched only `index.html`,
  `mod-coachonboard.js` and `mod-companies.js`. Seven `0.09` constants were live in
  production until this change.
- `mod-companies.js:293` and `mod-coachonboard.js:33` already modelled deducted
  incidence correctly and were left alone.

## Change table

| File | Line | Change |
|---|---|---|
| `src/mod-payments.js` | 30 | comment: "charged on top" → "deducted from" |
| `src/mod-payments.js` | 294 | `total: gross + fee` → `total: gross` (root arithmetic) |
| `src/mod-payments.js` | 386–391 | review-step fee row shown as `−$X (paid by the coach)`; fine print rewritten |
| `src/mod-payments.js` | 597, 698 | `refundTotal = refundGross + refundFee` → `refundGross` |
| `src/mod-payments.js` | 647–648 | "Platform fee paid" → "Sporve's 12% (from the coach)" |
| `src/mod-payments.js` | 665 | refund math row: fee returns to the coach, not the family |
| `src/mod-payments.js` | 957, 964 | credit pack "Charged today" and CTA drop the fee |
| `src/mod-payments.js` | 1015–1018 | transactions legend: "Charged" is the coach's price, no fee added |
| `src/mod-payments.js` | 1365, 1371 | pack txn `chargedCents` and toast drop the fee |
| `src/sporve-web.host.html` | 4476–4477 | 9% on-top → 12% coach-paid; parent total = list price |
| `src/sporve-web.host.html` | 5107 | dashboard Earnings `0.09` → `0.12` |
| `src/sporve-web.host.html` | 5491 | coach Finances `0.09` → `0.12` |
| `src/sporve-web.host.html` | 5503–5504 | transactions table `0.09` → `0.12` |
| `src/sporve-web.host.html` | 5705 | book modal fee `0.09` → `0.12` |
| `src/sporve-web.host.html` | 5724–5725 | book modal: fee shown as coach-paid; total = list price |

## Judgement calls made

1. **The fee row stays visible.** Deducted incidence could have removed Sporve's cut from
   the family's view entirely. It is instead itemized as `−$12 · Sporve's 12% (paid by the
   coach)`, keeping the "we itemize everything" trust story without adding to the total.
   Overrule this if you want the family to see only the price.
2. **Refunds return the session share only.** The family never paid the fee, so it cannot
   come back to them; `refundFee` is retained as the coach-side clawback and still writes
   to the ledger (`feeCents`, `netCents`). The cancel button now promises a smaller number
   than before — this is correct, not a regression.

## Still open

- ~~**Employee sub-payouts.**~~ **Closed 2026-08-10 by the owner:**

  > "that's all up to the coaches in itself… if i regoster a golf course, and they offer 3
  > coaches, then they handle the commision between the 88% of the trainings and how much
  > each individual keeps"

  Staff commission is taken **from the org's 88%**, after Sporve's cut — and the split is
  the org's own business, not something Sporve arbitrates. Sporve's math therefore stops at
  `gross → 12% → 88% to the org`. The existing `commissionType`/`commissionValue` fields
  (`sporve-web.host.html:3117`, `:5833`, `:8203`, `:5555`) are the org's internal
  bookkeeping and must never be netted against the platform fee.
- **Single source of truth.** The rate is still authored as a separate constant in five
  places, which is why it has now been partially migrated twice. A `platform_config` row
  read by every surface is the real fix and belongs in the backend build.
- `~/SportsMan-main` Flutter `platform_fee.dart` still carries 18/4 constants
  (`docs/gaps.md` #17) — web and app will disagree again until that is flattened.
