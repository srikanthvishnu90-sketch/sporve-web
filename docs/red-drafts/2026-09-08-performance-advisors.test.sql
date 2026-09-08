-- Dry run for 2026-09-08-performance-advisors.sql part D. Read-only.
-- Expected BEFORE apply: ~119 rows, each showing the rewritten expression.
-- Expected AFTER apply: 0 rows, and get_advisors(performance) reports 0
-- auth_rls_initplan findings, 0 unindexed_foreign_keys, 0 duplicate_index.
select tablename, policyname, cmd,
  regexp_replace(qual, '(?<!select\s)auth\.(uid|role|jwt)\(\)', '(select auth.\1())', 'gi') as new_using,
  regexp_replace(with_check, '(?<!select\s)auth\.(uid|role|jwt)\(\)', '(select auth.\1())', 'gi') as new_check
from pg_policies
where schemaname='public'
  and (coalesce(qual,'')||coalesce(with_check,'')) ~* '(?<!select\s)auth\.(uid|role|jwt)\(\)'
order by 1,2;

-- Sanity: no policy should lose or gain a role or command.
select count(*) as policies_total from pg_policies where schemaname='public';
