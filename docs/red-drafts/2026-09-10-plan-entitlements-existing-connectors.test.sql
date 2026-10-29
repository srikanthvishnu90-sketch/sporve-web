-- Isolated-only wrapper: verify the actual catalog migration against the
-- connector column reported deployed independently on September10.
\set existing_connectors true
\ir 2026-09-08-plan-entitlements.test.sql
