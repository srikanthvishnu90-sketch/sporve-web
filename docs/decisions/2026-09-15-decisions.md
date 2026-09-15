# DECISIONS — 2026-09-15
Binding. Agents implement these; they do not re-litigate them.
- **D1 Client architecture.** Single web surface; installable PWA at app.sporv.ai. Flutter/Dart mobile is RETIRED: delete the surface, delete FCM_SERVICE_ACCOUNT, remove mobile references from PRODUCT.md, CONTEXT.md, AGENTS.md. Parents install nothing and create no account. Ever.
- **D2 SMS provider: TWILIO.** Messaging Service with a number pool; A2P 10DLC brand+campaign registration starts today; toll-free number in parallel; Twilio Verify for guardian phone confirmation at import.
- **D3 Background checks: NCSI** (association acceptance decides, not price). Status+dates only, never report contents; `consider` never auto-adjudicated; org-paid by default, coach-paid as an org setting.
- **D4 Embeddings: OpenAI text-embedding-3-large @ 1024 dims.** Delete VOYAGE_API_KEY, JINA_API_KEY, EMBEDDING_PROVIDER. Anthropic stays for generation.
- **D5 Database tenancy: SPLIT THE PROJECTS.** The agent product gets its own Supabase project (us-east-1), own credentials. The marketplace keeps the existing project. A shared Postgres between a consumer marketplace and a system holding minors' PII is not a tenancy boundary.
- **D6 Observability: Sentry + BetterStack** (uptime, public status page, on-call). Status page live before the first paid org. Page on: webhook dead-letter growth, reconciliation drift, delivery failure rate.
- **D7 Email.** tx.sporv.ai (transactional) + msg.sporv.ai (bulk); >5,000 sends/month → dedicated subdomain; inbound reply.sporv.ai with plus-addressed routing; DMARC p=none → p=quarantine;pct=100 after 7 clean days → p=reject after 30; Postmark DMARC Digests.
- **D8 Legal: real counsel.** Fixed-fee package: ToS, COPPA-aware Privacy, DPA, AUP, subprocessor list (names Anthropic), refund terms. Generator terms only as a dated stopgap.
- **D9 Insurance: Vouch.** E&O + cyber; quote before pricing is final.
- **D10 Compromised machine: clean reinstall, no forensics.** New SSH/GPG keys, re-enrolled 2FA, record in docs/incidents/. Signed commits, branch protection on main requiring CI, no-implant-check.mjs stays, lockfile audit in CI.
- **D11 Pricing defaults.** parent_pays_fees=true; base + per-athlete billed at registration; SMS is COGS (12–20 msgs/athlete/season).
- **D12 Public front door.** sporv.ai/o/{slug} + embeddable registration button + custom-domain CNAME. No website builder.
- **D13 Sanctioning bodies.** No API integration in v1; qualification field on every lead; accepted export formats; one state-association partnership pursued off the critical path.
- **D14 Migration number blocks.** Fable (Claude): 20260915_001050–001099. Codex: 20260915_001100–001149. Neither agent edits GATES.md, 00-MASTER.md, or README.md. Neither touches files outside its assigned spec's surface.
