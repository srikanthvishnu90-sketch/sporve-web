# P1.02 — entitlement source decisions

2026-09-10. Supporting evidence only; not a production or complete billing claim.

## Actual red

Source commit ec84de0e9c54ae3628ba69486b1c2cb09d5dddeb:
run34511426762/job102986238718 returned10 matching lines and exit1.
Nine lines made name-based decisions; one was a harmless input type check.
The exact owner regex has no path exclusion or allowlist.

Actual handler tests at14e4ae101cf93ac44c5dbce4287ca4db3882af5b:
run34511740336/job102987272531: tests7, pass1, fail6.
Observed failures included wrong Enterprise label, key-based denial, truthy
malformed permission, raw catalog error and invalid input accepted.

Frontend tests at7347a9ce56314b084bf1c4cec799532f2ffa4716:
run34512546263/job102989978819: tests8, pass0, fail8.
The initial catalog invented three plans; revalidation was absent.

## Actual green supporting checks

Source commit5c50e4a09965e0ef3a09abad0a374d07e0cf89ae:
run34512916205/job102991212585:
```text
PASS P1.02: zero matches across src/, api/, supabase/
```
run34512916205/job102991213044: tests7, pass7, fail0.
run34512916205/job102991213052: tests8, pass8, fail0.

The handler uses catalog purchase permission, price and label; the frontend
uses validated catalog choices, quotas and seats. Empty/failed catalogs have
explicit states and retry rather than invented numbers. Onboarding preserves
the selected catalog key, and purchase initiation refreshes eligibility.

## Generated build

Actual build job102991212858:
```text
built size: 2237040 bytes
build stamp: e7bff9c12cfbe7da
```
Generated commit8ee8ae770b088f129b0a7f5f15482e13c3035e0e has parent5c50e4a,
and exactly index.html/vercel.json changed. Both came from src/build.py,
not hand-edited output. The narrowly scoped draft-write build job is removed
after that build; the retained CI workflow has read-only repository permission.

The prior smoke at source5c50e4a correctly failed for stale generated files;
that failure is not waived. Full smoke and the new390/1440px browser checks
must pass on the final generated head before review/release.

## Boundaries and known blockers

- Catalog choices do not prove the deployed catalog has canonical keys/prices;
  P1.01 live read/review/caller-cutover blocker remains.
- Pricing marketing cards and annual checkout are separate unfinished criteria.
- Existing Stripe customer persistence, checkout idempotency and coupon failure
  handling are not repaired by this slice. No real/test Stripe request executed.
- Client catalog checks are presentation and early feedback, not an auth boundary.
  API/SQL quota enforcement, trial/dunning and multi-tenant acceptance remain.
- The local UI skill files were inaccessible; repository design-rules.md was
  read, and no typography/color/layout/motion design was introduced.
- No production deployment. No G1–G4 gate closed. Request independent Clo review.

Evidence:
https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34512916205
https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34511740336
https://github.com/srikanthvishnu90-sketch/sporve-web/actions/runs/34512546263
