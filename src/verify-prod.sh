#!/usr/bin/env bash
# Post-deploy verification against the real production URL.
#
# CI proves a PR is sound before merge. It does not prove what is actually being
# served afterwards: a deploy can fail, roll back, land a stale build, or lose
# headers to a config change, and none of that is visible from a green PR. This
# closes that gap — the repo's release rule is "not done until verified live",
# and this is that rule as code instead of a habit.
#
# Usage: bash src/verify-prod.sh [url]
# Exit 0 = production is serving this commit's build, with its headers and gates.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

URL="${1:-https://the-sporve-web.vercel.app}"
FAIL=0
pass(){ printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail(){ printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }

# The stamp is a content hash of the built page, so this asks production
# "which build are you serving?" and compares it to the one in this checkout.
EXPECT=$(grep -o 'name="sporve-build" content="[a-f0-9]*"' index.html | grep -o '[a-f0-9]\{16\}')
[ -n "$EXPECT" ] || { fail "no build stamp in local index.html — run build.py first"; exit 1; }
echo "── waiting for $EXPECT ─────────────────────────────"

# Vercel builds take time, and a push-triggered check will always arrive first.
LIVE=""
for i in $(seq 1 60); do
  LIVE=$(curl -sL --compressed "$URL" | grep -o 'name="sporve-build" content="[a-f0-9]*"' | grep -o '[a-f0-9]\{16\}')
  [ "$LIVE" = "$EXPECT" ] && break
  sleep 10
done
if [ "$LIVE" = "$EXPECT" ]; then
  pass "production serving build $EXPECT"
else
  fail "production serving '$LIVE', expected '$EXPECT' after 10 minutes"
  exit 1
fi

echo "── headers ─────────────────────────────────────────"
H=$(curl -sI "$URL")
for h in "content-security-policy" "x-frame-options" "x-content-type-options" \
         "referrer-policy" "permissions-policy" "strict-transport-security"; do
  printf '%s' "$H" | grep -qi "^$h:" && pass "$h present" || fail "$h MISSING in production"
done
# CORS is asserted on the API, not on the marketing page.
#
# Vercel serves static assets with `access-control-allow-origin: *` by default.
# On fully public HTML that is untidy rather than dangerous: it exposes nothing
# that is not already public, carries no credentials, and CORS grants no access
# a plain GET does not already have. The header that would matter is on
# /api/ai, which spends money — and that endpoint must emit none at all, so a
# browser refuses to hand a cross-origin caller its response.
API_CORS=$(curl -sI -X POST "$URL/api/ai" | grep -ci "^access-control-allow-origin:")
[ "$API_CORS" -eq 0 ] && pass "/api/ai emits no CORS headers" \
  || fail "/api/ai is emitting CORS headers — cross-origin callers can read it"

echo "── /api/ai gates ───────────────────────────────────"
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
A="$URL/api/ai"
[ "$(code "$A")" = "405" ] && pass "GET rejected (405)" || fail "GET not rejected"
[ "$(code -X POST "$A" -H 'content-type: text/plain' -d x)" = "415" ] \
  && pass "non-JSON rejected (415)" || fail "non-JSON not rejected"
[ "$(code -X POST "$A" -H 'content-type: application/json' -H 'origin: https://evil.example' -d '{"text":"hi"}')" = "403" ] \
  && pass "cross-origin rejected (403)" || fail "cross-origin NOT rejected"
# Same-origin is 503 without a key and 200 with one. Both mean every gate
# passed; anything else means a gate is misbehaving.
SO=$(code -X POST "$A" -H 'content-type: application/json' -H "origin: $URL" -d '{"text":"open my earnings"}')
case "$SO" in
  200) pass "same-origin accepted (200 — key configured, AI live)";;
  503) pass "same-origin accepted (503 — gates pass, no key set yet)";;
  *)   fail "same-origin returned $SO — expected 200 or 503";;
esac

echo "────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] && echo "  PRODUCTION VERIFIED" || echo "  PRODUCTION VERIFICATION FAILED"
exit $FAIL
