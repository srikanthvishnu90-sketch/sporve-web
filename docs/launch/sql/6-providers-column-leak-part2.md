# providers column leak — part 2 (the half that needs a client change)

## What is already fixed

Applied to production 2026-08-11, verified:

```sql
revoke select on public.providers from anon;
grant select (id, business_name, bio, sports, location, status,
              onboarding_completed, verification_status, background_check_status,
              background_check_completed_at, provider_type, created_at,
              coach_years_coaching, coach_years_played, credentials)
  on public.providers to anon;
```

`anon` is now blocked on `latitude`, `longitude`, `stripe_account_id`,
`stripe_charges_enabled`, `owner_id`, `account_status`. Verified with
`has_column_privilege`.

**This broke nothing.** Every direct `providers` read in
`lib/core/data/supabase_repository.dart` is `.eq('owner_id', uid)` — the
authenticated owner reading their own row. Anonymous browse and search go
through `search_candidates`, which is `SECURITY DEFINER` and therefore unaffected
by column grants; it returns a computed `dist`, never raw coordinates. That is
the correct architecture and it was already in place.

## What is NOT fixed, and why it needs a paired change

`providers_select_public` grants SELECT to **`anon, authenticated`**. Signup is
free and open. So any signed-in user still reads, for all 20 visible coaches:

| column | still exposed to `authenticated` |
|---|---|
| `latitude` | yes |
| `longitude` | yes |
| `stripe_account_id` | yes |
| `owner_id` | yes |

Closing it means revoking those columns from `authenticated` too. **Column
privileges are per-role, not per-policy** — Postgres cannot express "full columns
on your own row, restricted columns on everyone else's" through `GRANT`. So the
owner's own full-row read has to move to a definer function.

The blocking detail: `supabase_repository.dart:3339` calls `.select()` with no
arguments — `SELECT *` — on the owner's own row. Revoking the columns without
changing that line returns `permission denied for column latitude` and **breaks
the coach dashboard for every coach**. That is why this half was not applied
tonight: the SQL alone is a regression.

---

## The complete fix — apply BOTH halves together

### Half 1 — SQL

```sql
begin;

-- The owner's own full row, via definer rights, so the table grant can be narrowed.
create or replace function public.get_my_provider()
  returns setof public.providers
  language sql stable security definer set search_path = ''
as $$
  select * from public.providers where owner_id = auth.uid();
$$;
revoke execute on function public.get_my_provider() from public, anon;
grant  execute on function public.get_my_provider() to authenticated;

-- Now narrow the table grant to the same public-safe set anon has.
revoke select on public.providers from authenticated;
grant select (id, business_name, bio, sports, location, status,
              onboarding_completed, verification_status, background_check_status,
              background_check_completed_at, provider_type, created_at,
              coach_years_coaching, coach_years_played, credentials)
  on public.providers to authenticated;

commit;
```

### Half 2 — Flutter, `lib/core/data/supabase_repository.dart:3339`

```dart
// BEFORE
final row = await _db
    .from('providers')
    .select()
    .eq('owner_id', uid)
    .maybeSingle();

// AFTER — definer function returns the owner's full row; the table grant no
// longer needs to expose latitude/longitude/stripe_* to every signed-in user.
final rows = await _db.rpc('get_my_provider');
final row = (rows as List).isEmpty ? null : rows.first;
```

`:2119` (`buffer_minutes, vacation_until`) and `:3458`
(`cancellation_policy, what_to_bring, …`) name their columns explicitly. **Check
whether each named column is in the grant list above** — if any is not, either
add it to the grant or move that read to the RPC as well. `:3380`, `:3500` and
`:3953` are updates or `.select('id')` and are unaffected.

### Order of operations

1. Merge and **ship** the Flutter change first, or ship both behind the same
   release. The RPC can exist before the client uses it — creating
   `get_my_provider()` is harmless on its own.
2. Only after the client is live on the RPC, run the `revoke` half.
3. Reversing that order breaks every coach dashboard until the app updates,
   and mobile clients do not update on your schedule.

---

## A better long-term answer

Even with the above, `authenticated` and `anon` both still see `location` (the
free-text town). That is intended and fine. The real question is whether exact
`latitude`/`longitude` should be stored at coach precision at all.

For an independent coach, exact coordinates are usually a home address. The
durable fix is to store a **deliberately fuzzed** public coordinate alongside the
exact one:

- `providers.latitude` / `longitude` — exact, owner + service role only, used by
  `search_candidates` to compute distance server-side
- `providers.public_latitude` / `public_longitude` — rounded to ~1km, safe to
  expose, used for map pins

That removes the class of bug rather than this instance of it, and it is what a
launch with real coaches needs. Backlog item, not tonight's work.
