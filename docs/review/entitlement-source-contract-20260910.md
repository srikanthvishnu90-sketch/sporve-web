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

## Final source review and rebuild

Actual routed browser run34513823073/job102994210145:
```text
PASS real Chromium at390px: catalog values, selected onboarding plan, no horizontal scroll, visible error/retry, no JavaScript errors
PASS real Chromium at1440px: catalog values, selected onboarding plan, no horizontal scroll, visible error/retry, no JavaScript errors
PASS26 DOM assertions; mocked catalog only, no live billing acceptance
```
Six screenshots are in artifact10166865514 (run34513823073).
The initial desktop failure was a harness defect: injecting the inner view
outside its dashboard produced left-32/right1472 at1440px. The test now uses
the real router and coach tab; no width assertion or product CSS was weakened.

Full smoke on generated172961a, run34513226526/job102992219645:
```text
build outputs in sync with sources
SMOKE PASSED
```

Final review executed the source with two purchasable rows and found two
primary buttons (expected1). The corrected source has primary1/choices2;
the ninth catalog unit test preserves this design rule.
Source6eb05338ef8b1badf00d640e5be90b39bcd2a070, run34535161420:
- source scan zero (job103064960534);
- catalog tests9/pass9/fail0 (job103064960538);
- checkout tests7/pass7/fail0 (job103064960557).
Build job103064960703:
```text
built size: 2237075 bytes
build stamp: 573099944beae4ba
```
Generated29961286bb033685d27fe4d7d443acc5036b8a46 has parent6eb05338
and only index.html/vercel.json changes. Latest browser test also checks one
primary action at both widths; final whole-head CI is still required.

Independent review was requested. CodeRabbit replied "Review rate limited"
(comment5623348949); that is NOT approval. Clo review and the authorized
production release/verification remain required.

## Independent review corrections — supersedes earlier final evidence

Review5172771792 on9a9b38e5 posted four actionable comments; it was COMMENTED,
not approval. All four findings were verified against source and addressed.
The production/Clo release gate remains open.

- Unavailable persisted paid choice: actual V8 module evaluation before the fix
  rendered1 checkout button and no unavailable label; after the fix it renders0
  checkout buttons and the unavailable label, preserving the selected key.
  Both unavailable and available submitted-state regressions now run in CI.
- All four test checkouts disable persisted credentials; setup-node and
  upload-artifact use full SHAs verified from their official repositories.
- Browser dependencies are isolated under scripts/ci-browser, with a real
  npm-generated lock and npm ci. Production package files are unchanged.
- Artifact upload names only the eight intended screenshots.
- Temporary draft-only generator produced47a2b206c2bc0425378a99a4904909776984ae30,
  parent58f6d3789b7ce8d9ea5756f422ee99782902e8e2, changing only index.html,
  vercel.json and the CI-only lock. The writer was then removed completely.
  Build stamp3ea04337b8d34db3 comes from actual build.py output.

Actual corrected head78e984634fed20e7ab2918b28b5c1532f6cb922e:
```text
run34537954736/job103073832941: PASS P1.02: zero matches across src/, api/, supabase/
job103073832724: tests11, pass11, fail0
job103073833051: tests7, pass7, fail0
job103073832956: PASS real Chromium at390px and1440px
job103073832956: PASS36 DOM assertions; mocked catalog only, no live billing acceptance
run34537954813/job103073833565: build outputs in sync with sources; SMOKE PASSED
run34537954813/job103073833178: security-regressions success
secret-scan34537954799: success
```

The initial lock-bootstrap run34537423014 correctly failed npm ci before its
parent commit contained a lock; its generator succeeded. This failure was not
bypassed. The generated successor and read-only final workflow passed above.

Thirteen intended files reviewed in PR415; no production merge, deployment or
live marker verification is claimed. Earlier eleven-file/six-screenshot and
stamp573099944beae4ba descriptions are historical, not current release targets.
