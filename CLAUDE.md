# the-sporve-web — standing rules

## 0. Coordinate with Codex before editing

Codex may edit this repository concurrently. Read `.clo-sync/activity.md` when
it exists, then claim the task and files before writing:

```bash
python3 .claude/hooks/clo-sync.py begin claude "TASK" FILE...
```

After verification, close the claim with `end` and include the check performed.
Claude write tools are also observed automatically by the `PostToolUse` hook.
If Codex has an unfinished claim on the same file, re-read it immediately before
editing and narrow or hand off the work. The ledger contains observable actions,
not private reasoning, and must never contain prompts, secrets, or raw tool output.

Derived from 170 of the owner's own messages across the last 7 days. Each rule
below is here because he had to say it more than five times.

## 1. A task is not done until it is deployed and verified live

The most repeated instruction in the corpus, ~10 times: *"update everything to
sporve.vercel aswell as the github repo"*, *"make sure these are all implemented
then make sure it's live updated in vercel"*.

After any user-visible change: build, commit, push, wait for the Vercel deploy,
then **verify against the production URL** and end the turn with that URL.
Never report "done" from a local build.

This is the shared Claude/Codex release contract, enforced through Clo. Use
`MODE: release` after the implementation and audit are complete. The release
report must name the pushed commit SHA, successful Vercel production result,
verification method, and `https://the-sporve-web.vercel.app`. A failed push,
deployment, or live check means the task is incomplete; never silently leave
changes local.

**Verify the right way.** This page renders from template literals, so a string
like `coach-insights` is generated at runtime and **never appears in the served
HTML**. Grepping for it will fail forever and look like a broken deploy — that
happened, and cost two timeouts. Verify by either:

- grepping a **source** marker (`bizVerified`, `data-sporttoggle`, `mqpause`), or
- comparing `wc -c` of the live response against local `index.html`, or
- driving the live page and asserting on the rendered DOM.

## 2. Change only what was asked

~7 times: *"do not change too much with the app"*, *"keep much all the
information the same but rearrange"*.

Do not restructure, rename, reword or improve adjacent code, copy or layout. If
the change appears to require touching something outside its scope, stop and
ask. List every file touched at the end of the turn.

## 3. Colour law

~6 times, and stated as an absolute: *"DO NOT CHANGE the brand color palette"*,
*"black background always have white or slate text"*.

- Black, white and slate are frozen. They carry all chrome and are never restyled.
- **Text on a black ground is white or slate. Never a token that can resolve
  dark** — `--paper` inverts under `data-theme="dark"` and has produced
  near-black-on-black. Use literals in `.band.dark`.
- `--accent #C2410C` measures **4.06:1 on black** and is banned there for
  anything but large display text. Use `--accent-on-dark #F08A62` (8.52:1).
- Sport colours are **accent-only**: tag, glyph, dot, 3px identity bar. Never a
  card background, never generic chrome, never body text — the ramp measures
  3.35–3.95:1 as label type. Use `sportInk()` when a sport colour must be text.

The reference site `sporve.vercel.app` uses this same system: its slate
`#F7F9FF` is ΔE 2.1 from `--raise`, its black `#0A0C0F` is ΔE 3.6 from `--ink`,
and every chromatic colour on it is a sport token. Briefs proposing
`#E05A47`/`#38BDF8`/`#10B981` are approximating what is already here.

## 4. Two typographic registers, chosen by subject

- **Expressive — Syne (display) + Plus Jakarta Sans (body).** The default.
  Landing, dashboard, and ~75% of the product-toggle pages.
- **Serious — Hanken Grotesk alone**, weight doing all the work (800 headline /
  700 label / 400 body). For pages whose subject is **money, safety, consent or
  law**, where a quirky display face reads as levity about something the reader
  is being asked to trust.

Currently serious: `trust`, `bookings`, `pricing`, `info`, `wallet`, and the
coach `finances` and `media` tabs. Four of the sixteen product-toggle pages —
the 25% asked for.

Switch by adding `reg-serious` to `#app`; `render()` decides. The class
re-declares `--display` and `--sans` **and sets `font-family` on itself** — the
second part is required, because a custom property only changes an element that
actually evaluates it. Headings do (`font-family:var(--display)`); a `<p>` does
not, it inherits the computed family from `<body>`, which is outside the
wrapper. Without that line you get Hanken headings over Plus Jakarta body.

## 5. Section rhythm — chapters, not a checkerboard

Do not alternate mechanically. Runs of two are wanted: white / black / black /
white, or black / black / white / black / white / white. Two blocks of the same
ground read as one **chapter**, which is the point — group sections that belong
together and let the ground say so.

Two constraints when doubling up: keep the hairline join between them
(`.band.dark` carries `border-bottom-color:#1C222B`) so the pair still has
internal structure, and never double up two *white* blocks without a divider —
148px of unbroken white padding reads as one over-long run, which has already
happened once.

## 6. Fan out to subagents

~8 times: *"have the agents hekp you run through the remainder"*. For any
multi-part task, run subagents in parallel rather than serially, and say which
agent produced which finding.

Two operational notes learned the hard way: **pin a snapshot** of the source
before launching read-only auditors, because editing files while they read
stalls them; and **tell them to `rg -l` then read line ranges**, because
pointing an agent at a 208-file repo without that reliably times it out.

## 7. Owner comprehension protocol

The owner is a business-side founder learning engineering through this
codebase. He is the only person accountable for it. Assume he knows the
product cold and the implementation not at all — explain at that level,
neither talking down nor assuming.

**After every single change, give a five-sentence technical reading.** Not a
diff summary. Five sentences, in CS/engineering language, covering: what
changed, the mechanism (why it works), what it touches downstream, what would
break it, and how it was verified. Short and dense beats long and gentle. Use
the real names — selector specificity, cascade, custom property inheritance,
render cycle, RLS policy, idempotency key.

**Predict-then-correct on anything non-trivial.** Before showing a diff on a
CRITICAL-PATH change, ask him to state what he thinks it requires — which
files, which tables, which failure modes — then correct the prediction
explicitly. Prediction error is where the learning happens; a clean summary
read cold produces the feeling of understanding without the thing itself.

**Mark `[CRITICAL-PATH]`** on any change touching RLS, Stripe, auth, booking
capacity, or consent. Those are the surfaces where a silent bug costs money,
safety, or the company.

**Log gaps.** `docs/gaps.md` holds what he has not closed, tiered by blast
radius. Reference it, weave those topics into explanations, and when a debrief
exposes a new gap, add a row. When he answers one cold, move it to Closed with
the date.

**Do not let this slow shipping.** The five-sentence reading costs seconds.
The predict step costs two minutes and only applies to critical-path work.
If pressure forces a cut, keep the readings — they run inside the existing
workflow rather than beside it.

## 8. Teach as you go — explain every edit

Stated directly: *"Make sure that the agent helps me learn exactly what is
going on after each edit."*

After each change, say in plain language: **what changed, why, and what it
means for the page.** Not a diff summary — the reasoning. If a judgement call
was made (a value held back, a spec item interpreted rather than followed
literally), say which and why, so the owner can overrule it.

The owner did not write this code. A change he cannot follow is a change he
cannot review, and an unreviewable change is how the wrong thing ships twice.

## 9. Check a spec's premises before building on them

Pasted briefs have repeatedly asserted things that are not true of this repo —
fonts that are not embedded, reference files that do not exist, a package
manager that is not installed, hex values approximating tokens already here.
Verify every load-bearing claim against the repo BEFORE writing code, and
report the mismatch rather than silently building on it or silently ignoring
it. A spec that reverses a decision the owner made earlier is the most
important case: surface it, do not just pick one.

## 10. When the owner has to act, give click-level steps

~7 times: *"this still to vauge, tell me exactly where to go, what to click"*.
Exact URL, exact button label, full copy-paste-ready values. No "navigate to
your project settings".

## 11. Branch and PR — do not push to main

CodeRabbit reviews **pull requests**, so a change pushed straight to `main`
gets no review. Route every substantive change through a branch and a PR:

```bash
git checkout -b <kind>/<short-name>      # feat/ fix/ chore/ style/
# ...edit, then:
bash src/smoke.sh                        # must exit 0
git commit -am "<message>"
git push -u origin HEAD
gh pr create --fill
```

CodeRabbit comments within a minute or two; the `pr-checks` workflow runs the
smoke test on the same PR. Read both before merging. Merge with
`gh pr merge --squash` once green. This also gives the Claude/Codex split a
real review gate instead of two actors pushing to `main` in parallel.

Trivial, non-code changes (a doc typo, a comment) may still go direct — the
gate is for anything that touches behaviour, style tokens, or the build.

---

## Before you commit

```bash
bash src/smoke.sh
```

Exit 0 = safe. It checks: the build emits, all three faces inline, the host script
boots, no JS errors on 13 visitor-reachable routes, the dark-ground invariant
holds, no horizontal overflow at three breakpoints, and every rendered font
size is on the 8-step scale. Every one of those is a defect this repo has
actually shipped.

## The build

`python3 src/build.py` inlines `src/mod-*.js` into `src/sporve-web.host.html`
and writes `index.html`. **Edit the sources, never `index.html`.** Fonts and
hero images are base64'd in, because the built page must survive a CSP that
blocks every external request. `mod-companies.js` still fetches
`picsum.photos` externally, which violates that and is the one open warning in
the smoke test.
