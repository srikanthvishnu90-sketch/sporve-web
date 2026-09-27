-- Expected failure is checked by CI, followed by independent rollback assertions.
\set invalid_connectors true
\ir 2026-09-08-plan-entitlements.test.sql
