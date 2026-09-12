# Security release hold —2026-09-12

Status: OPEN. No launch acceptance or cleanup completion is claimed.
Observed at2026-09-12 21:12UTC through read-only GitHub APIs.
No suspicious payload was executed or deobfuscated by this investigation.

## Confirmed evidence

- Source main88ac75f40390bc978109f87c751fc3122662c9c0 contains
  .vscode/tasks.json blob5e226620d2e360205cc8634e3c581a008d382561.
  Its task labeled eslint-check runs Node against
  public/fonts/fa-solid-400.woff2, with runOn=folderOpen and hidden output.
- .vscode/settings.json blob934d55548c36ff0e330f2a2ba69bf74b10a7dcba
  sets task.allowAutomaticTasks=true.
- The supposed font is32,218 bytes of obfuscated JavaScript, not a WOFF2 font.
  Blob1390124885046fd4b6f6dd3a61410a8ae3cf9856 starts with global.i assignment,
  contains network/RPC, eval and child-process/spawn code, and ends in run().
  Its full executable contents are deliberately not copied into this report.
- Identical task/settings/payload blobs appear on current PR399, PR415 and
  PR412 branches. Unexpected accompanying changes include .gitignore,
  editor settings and a bundle of font files.
- No author or root cause is established. Git author metadata does not prove
  who performed the ref updates. No credential exfiltration or device execution
  has been established.

## Tested commits are not the current branch heads

| Branch | Previously recorded commit | Observed changed head |
| --- | --- | --- |
| codex/prompt1-sql-verification | ab54a7b2ebc02ada46439ce3a63b33b3a96bcfe6 |24cb7fe9771d6ec20ae524d68150ab7b128ea5bf |
| codex/entitlement-source-contract-20260910 |96009cf429fc5a1ea10b286b6f2a1aa9f8c17936 |917e48a99e72bdd06ae0e72274a8dae0cf9264ed |
| codex/launch-driver-20260910 |b5c9d2a5750c95c71be24ebe12dd6da0e215c060 |15373ae25ad0fea4e4e1e3417d9cb736ab15217b |

The first two comparisons report diverged, not an ordinary forward addition.
Original run34542507155 still identifies headab54a7b2 and concludes success;
run34538507840 still identifies96009cf4 and concludes success. Those historical
checks do NOT approve the replacement heads or their unexpected additions.

## Actions actually taken

- Stopped further builds, deployments, merges and launch feature changes.
- Warned the owner not to open this repository in an editor with automatic tasks.
- Posted superseding SECURITY RELEASE HOLD comments:
  PR399 comment5648716406, PR415 comment5648716573,
  PR412 comment5648717770.
- Re-read the earlier checkpointb5c9d2a5750c95c71be24ebe12dd6da0e215c060:
  its commit changes only STATE.md; recursive tree read was not truncated
  and contains neither the suspicious task nor the disguised font.
- Created this documentation-only hold branch from that checkpoint.
  No current main/working branch was reset, force-pushed or overwritten.
  This branch is NOT a release candidate and has not been deployed.
- The mirror repository's .vscode/tasks.json lookup returned404. That does not
  prove the whole mirror, a deployment, or a local checkout is clean.
- No suspicious files were deleted; original Git evidence remains available.

## Required containment and resume conditions

1. Keep affected trees out of editors that can run automatic tasks, and do not
   run the disguised font, repository scripts or fresh installs during triage.
2. A repository administrator must investigate GitHub account/app/session and
   ref-update activity from a trusted device; identify and disable any
   unauthorized writer before restoring release access.
3. If an affected tree was opened with automatic tasks enabled, treat that
   workstation and credentials accessible to it as potentially exposed until
   examined. Rotate/revoke affected credentials from a trusted device after
   identifying scope; no blanket claim that every credential was stolen.
4. Preserve the Git objects and relevant audit evidence. Prepare a reviewed,
   non-destructive cleanup of the unexpected additions against a verified
   checkpoint; do not blindly reset main or overwrite concurrent legitimate work.
5. Re-establish trusted branch ancestry and reproduce CI on the exact reviewed
   successor. Only then resume Prompt1 and the normal Clo/mirror/Vercel release.

These steps require repository/account administration and possible device
incident response, which the current repository-content connection cannot
perform or verify. No automatic cleanup commit can establish that the writer
or a potentially affected workstation has been contained.

## Launch work preserved, not accepted

Historical supporting evidence includes the real catalog/trial resolver plus
capacity guards through signed HTTP: expired trial402 without cron, active
trial201, cross-org resolver403, two observed concurrent requests for a final
slot, and an observed assignment downgrade blocking the waiting insert.
Run34542507155/job103088015637 recorded those checks; all11 SQL jobs in
run34542507189 and pr-checks34542507182 passed on the earlier recorded source.
P1.02 corrections passed source scan,11 frontend tests,7 checkout tests and36
browser assertions at390px/1440px, with build stamp3ea04337b8d34db3.
They remain supporting tests, not approved/current production evidence.

All six launch prompts remain unfinished. COMPLETE.md must not be created.

## Shell pause and review-only task containment

No Bash/shell commands, repository scripts, CI runs or deployments were executed
for this follow-up. Static JSON validation alone produced:
```text
taskCount=0
automaticTasks=off
embeddedTasks=false
containsShellCommand=false
```
Review-only commit17a5ea6035ca590eccfcb03faa1880a37920646c, parent88ac75f40390bc978109f87c751fc3122662c9c0,
changes exactly .vscode/tasks.json and .vscode/settings.json.
It has NOT been applied to main, a working checkout, or a deployment; no branch
ref or PR was created for it, preventing automatic CI from running.
The disguised payload remains preserved, so the patch is only entry-point
containment, not complete incident remediation.

Important precision: the observed boolean true setting is invalid in current
VS Code and does not establish that automatic tasks were enabled or ran.
Current [VS Code source](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/tasks/browser/task.contribution.ts)
defines this as the application-level string on/off setting; repository settings
alone cannot be relied on to change the user's automatic-task preference.
The confirmed issue is the configured folder-open executable task and disguised
JavaScript, not proof of execution on a device.

Owner action without a shell: in an EMPTY VS Code window, open the Command
Palette, choose Tasks: Manage Automatic Tasks, then Disallow Automatic Tasks.
See [official automatic-task documentation](https://code.visualstudio.com/docs/debugtest/tasks#_control-automatic-task-execution).
This does not terminate a process that might already have run; device and
credential exposure assessment remains an external containment requirement.

## Resume verification — 2026-09-12 21:55 UTC

The owner asked to continue launch work after authorizing routine in-scope
commands. That preference does not establish incident containment.

Actual read-only GitHub tree results:
```text
source main = 88ac75f40390bc978109f87c751fc3122662c9c0
source recursive tree: truncated=false; 455 entries; 370 blobs
known incident path/blob matches = 3
mirror main = 61d603edf1a716d003c41525eea5fed194a0fac5
mirror recursive tree: truncated=false; 408 entries; 327 blobs
known incident path matches = 0; known incident blob matches = 0
path/blob comparison: identical=320; changed=7; source-only=43; mirror-only=0
```

Source still contains the exact task, settings and disguised-font hashes
recorded above. The mirror result is stronger than the earlier single-path
404, but is ONLY a negative check for these known indicators, not a complete
security audit of the mirror, its dependencies, deployed artifacts or devices.
No live deployment was inspected or changed in this follow-up.

The source and mirror are not identical snapshots. The seven common paths
with different blobs are:
- .github/workflows/pr-checks.yml: source ca75fecbc71f3024a2e0d6ef88b6018ba30bed6e; mirror ef4d109f4c6f5b217a629ba7fcfc21d881f6b816
- .gitignore: source 45f2aa9c1f15ec379cff6d190cfb468591001165; mirror e7409e7b50e7ca360e67ffb1af6e30a5af0ef249
- docs/red-drafts/2026-09-08-invite-creates-guardian.sql: source c6b4e51ec1acaae88f4bfce93fcec0d9bc06f274; mirror 3dd3f315b01a295553f98987c6a7071a65b78fe7
- src/smoke.sh: source fe07da77ab652101f5c54bf8c7b97287d2135e67; mirror cbf3856b7a04c50529d92e588f2887df65fe8f11
- supabase/config.toml: source 7dec5a93fd3367f4ca4b428e4f6f06dc05633b9c; mirror b252b6663a414094e89124638cdb655cef1f71b9
- tools/deploy-prod.sh: source b8aff1bd6887c1683a99497467364dc2e5249869; mirror 940e83d193d0699bf2ed6c7004fb96e15959f1c5
- tools/strix-scan.sh: source 7f200fdf57ada1cf928df2aa364289de2310648b; mirror daeaf89a27a3f032c9f14119dd6ee1382fe526b6

Source-only entries include both the incident files and apparently legitimate
work, including the connector registry, gmail-scan, and migrations 001037–001046.
This inventory does not approve that work or prove migrations were deployed.
Do not replace source with the mirror wholesale: it would discard source-only
work and would not establish account or device containment.

The PR412 handoff was read in full (seven existing comments); it contains no
subsequent containment receipt. No attribution, account compromise, token theft,
or workstation execution is inferred from the absence of a receipt.

### Precise handoff to Robin / repository administrator

- Investigate the ref/account/app/session changes from a trusted device and
  provide the resulting containment decision, actor/time evidence where
  available, and any scoped credential or workstation follow-up.
- Review the existing two-file containment object
  17a5ea6035ca590eccfcb03faa1880a37920646c as an unapplied proposal, not a fix
  already live; it does not remove the disguised payload.
- Establish a reviewed clean successor preserving legitimate source-only work,
  compare it with the preserved original test commits, then rerun checks on
  that exact successor only after execution is safe.
- Return non-secret evidence in this incident record / PR412. Do not paste
  credentials, tokens, or raw malicious code into the handoff.

Current access supports repository-content operations, not GitHub account
administration or workstation incident response. No shell, build, install,
test workflow, merge, deployment, money movement, or credential change was
performed. No acceptance criterion was ticked and no prompt was completed.
