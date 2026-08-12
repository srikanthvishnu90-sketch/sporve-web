#!/usr/bin/env bash
# Smoke test for the-sporve-web.
#
# Why this exists: the repo had no test suite, no CI and no runner, so any
# automated change had nothing to verify itself against. Everything below is a
# check that a real defect in this repo has already tripped at least once:
#
#   boots        a ${...} pasted into a plain function body is a syntax error
#                that kills the whole host script -- shipped twice
#   errors       sportMenuHTML() was called and never defined; clicking the
#                first chip on the default route crashed the app, live
#   contrast     white-on-white headline (c6cf658), then near-black-on-black
#                under a dark theme -- both were INHERITED grounds, which a
#                CSS grep cannot see, so this resolves the painted background
#   overflow     new landing components broke the phone layout more than once
#   scale        the 8-step type scale drifts the moment someone hand-writes a px
#
# Exit 0 = safe to commit. Non-zero = revert, do not push.
# Usage: bash src/smoke.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

B="$HOME/.claude/skills/gstack/browse/dist/browse"
FAIL=0
pass(){ printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail(){ printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }

echo "── build ────────────────────────────────────────────"
if python3 src/build.py >/tmp/smoke-build.txt 2>&1; then
  pass "build.py exits 0"
else
  fail "build.py failed:"; sed 's/^/        /' /tmp/smoke-build.txt; exit 1
fi
grep -q "NONE FOUND" /tmp/smoke-build.txt && fail "fonts missing -- type contract not met" \
  || pass "all faces inlined"
[ -s index.html ] && pass "index.html emitted ($(wc -c < index.html) bytes)" \
  || { fail "index.html empty or missing"; exit 1; }

# gstack's browse is a developer convenience and lives outside the repo, so it
# is absent on a CI runner. src/ci-browse.mjs is the in-repo fallback: a
# Playwright-backed daemon implementing the six subcommands used below. Without
# it this script exited 0 after 3 of 25 assertions and CI showed a green tick
# for a run that never opened a page.
CIB=""
if [ ! -x "$B" ]; then
  if command -v node >/dev/null 2>&1 && node -e "import('playwright')" >/dev/null 2>&1; then
    node src/ci-browse.mjs serve >/tmp/ci-browse.log 2>&1 &
    CIB=$!
    for _ in $(seq 1 50); do [ -f .ci-browse-port ] && break; sleep 0.2; done
    if [ ! -f .ci-browse-port ]; then
      fail "ci-browse daemon failed to start:"; sed 's/^/        /' /tmp/ci-browse.log; exit 1
    fi
    B="node src/ci-browse.mjs"
    echo "  using in-repo ci-browse (playwright)"
  else
    # Fail, do not skip. A check that goes green without running is the exact
    # failure this file exists to prevent.
    fail "no browser harness: gstack browse absent and playwright not installed — 22 of 25 checks cannot run"
    [ -n "${GITHUB_ACTIONS:-}" ] && \
      echo "::error title=Smoke incomplete::No browser harness available; 22 of 25 smoke checks did not run."
    exit 1
  fi
fi
cleanup(){ [ -n "$CIB" ] && { $B stop >/dev/null 2>&1; kill "$CIB" 2>/dev/null; rm -f .ci-browse-port; }; }
trap cleanup EXIT

echo "── runtime ──────────────────────────────────────────"
$B viewport 1440x900 >/dev/null 2>&1
$B goto "file://$(pwd)/index.html" >/dev/null 2>&1

boots=$($B js "typeof S==='object'&&typeof render==='function'" 2>/dev/null | tr -d '[:space:]')
[ "$boots" = "true" ] && pass "host script boots" || { fail "host script did not boot"; exit 1; }

# Every route a visitor can reach without auth.
ROUTES="home explore product trust companies pricing coachinfo map assistant saved bookings messages timeline"
# A JS error is a code defect and fails the build. A failed external resource
# is an architecture problem (this page is meant to survive a CSP that blocks
# every external request) but it is pre-existing and environmental, so it warns
# rather than blocking a change that did not cause it.
RESWARN=0
for r in $ROUTES; do
  $B console --clear >/dev/null 2>&1
  $B js "S.auth={status:'guest'};S.portal='family';S.route={name:'$r',arg:null};render();'ok'" >/dev/null 2>&1
  log=$($B console --errors 2>&1)
  js=$(printf '%s' "$log" | grep "\[error\]" | grep -vc "Failed to load resource")
  res=$(printf '%s' "$log" | grep -c "Failed to load resource")
  [ "$js" -eq 0 ] || fail "JS errors on route '$r' ($js)"
  [ "$res" -eq 0 ] || { printf "  \033[33mWARN\033[0m  %s\n" "route '$r': $res external resource(s) failed to load"; RESWARN=$((RESWARN+res)); }
done
[ "$FAIL" -eq 0 ] && pass "no JS errors across $(echo $ROUTES | wc -w | tr -d ' ') routes"
[ "$RESWARN" -gt 0 ] && printf "  \033[33mWARN\033[0m  %s\n" "$RESWARN external resource(s) failed — the single-file/CSP design says nothing should be fetched externally"

# ── coach portal ────────────────────────────────────────────────────────
# Every route above forces portal='family' and auth=guest, so until now the
# entire coach dashboard — roughly half the product — was never rendered by
# this script at all. Three real contrast defects shipped through a green
# smoke run because of that. The coach surface gets the same treatment.
# Core rail tabs plus every tab contributed by a module (modCoachTabs()):
# mod-notes, mod-media, mod-insights and mod-coachops each register their own.
# Omitting them left 7 of 15 coach surfaces unchecked.
COACHTABS="dashboard schedule bookings roster inbox listings finances reviews \
notes media insights policies waitlist slots messages"
CFAIL=0
for t in $COACHTABS; do
  $B console --clear >/dev/null 2>&1
  $B js "S.auth={status:'verified'};S.portal='coach';S.coachTab='$t';S.route={name:'dashboard',arg:null};render();'ok'" >/dev/null 2>&1
  log=$($B console --errors 2>&1)
  js=$(printf '%s' "$log" | grep "\[error\]" | grep -vc "Failed to load resource")
  [ "$js" -eq 0 ] || { fail "JS errors on coach tab '$t' ($js)"; CFAIL=$((CFAIL+1)); }
done
[ "$CFAIL" -eq 0 ] && pass "no JS errors across $(echo $COACHTABS | wc -w | tr -d ' ') coach tabs"

# ── contrast ────────────────────────────────────────────────────────────
# Structural assertions cannot see whether text is readable. This repo has
# shipped near-black-on-black once and near-white-on-white once; both were
# computed-style defects that only a browser measuring real pixels catches.
#
# The coach portal is held at zero because it was built clean and there is no
# reason to let it rot. The family portal carries 16 pre-existing failures, so
# it is ratcheted instead of gated: the number may fall, never rise. Blocking
# on it today would stop every unrelated change until someone fixes 16 old
# defects, which is how a check gets deleted rather than satisfied.
FAMILY_CONTRAST_BASELINE=16
# Fail closed. If the audit file is missing or the harness returns nothing,
# `${n:-0}` would coerce empty to zero and every assertion below would report
# PASS without measuring a pixel — a check that goes green when it cannot run
# is worse than no check, because it is trusted.
[ -f src/contrast-audit.js ] || { fail "contrast: src/contrast-audit.js missing — gate cannot run"; }
cx_run() { $B eval src/contrast-audit.js 2>/dev/null | tr -d '\r' | tail -1; }
cx_num() {
  n=$(printf '%s' "$1" | sed -n 's/.*"failures":\([0-9]*\).*/\1/p')
  [ -n "$n" ] || { printf 'UNMEASURED'; return; }
  printf '%s' "$n"
}

COACH_CX=0
for t in $COACHTABS; do
  $B js "S.auth={status:'verified'};S.portal='coach';S.coachTab='$t';S.route={name:'dashboard',arg:null};render();'ok'" >/dev/null 2>&1
  out=$(cx_run); n=$(cx_num "$out")
  if [ "$n" = "UNMEASURED" ]; then
    fail "contrast: coach tab '$t' returned no measurement — gate broken"
    COACH_CX=$((COACH_CX+1))
  elif [ "$n" -ne 0 ]; then
    fail "contrast: coach tab '$t' has $n failure(s)"
    printf '        %s\n' "$(printf '%s' "$out" | sed -n 's/.*"list":\[\(.*\)\]}/\1/p' | tr ',' '\n' | head -4)"
    COACH_CX=$((COACH_CX+n))
  fi
done
[ "$COACH_CX" -eq 0 ] && pass "contrast: coach portal clean across $(echo $COACHTABS | wc -w | tr -d ' ') tabs"

FAM_CX=0
for r in home explore product trust; do
  $B js "S.auth={status:'guest'};S.portal='family';S.route={name:'$r',arg:null};render();'ok'" >/dev/null 2>&1
  n=$(cx_num "$(cx_run)")
  [ "$n" = "UNMEASURED" ] && { fail "contrast: family route '$r' returned no measurement — gate broken"; n=0; }
  FAM_CX=$((FAM_CX+n))
done
if [ "$FAM_CX" -gt "$FAMILY_CONTRAST_BASELINE" ]; then
  fail "contrast: family portal regressed to $FAM_CX (baseline $FAMILY_CONTRAST_BASELINE)"
elif [ "$FAM_CX" -lt "$FAMILY_CONTRAST_BASELINE" ]; then
  pass "contrast: family portal improved to $FAM_CX (baseline $FAMILY_CONTRAST_BASELINE — lower it)"
else
  pass "contrast: family portal holding at baseline $FAMILY_CONTRAST_BASELINE"
fi

# ── CSP script hashes ───────────────────────────────────────────────────
# The blast radius here is total: a script-src hash that does not match the
# script it is meant to authorise blocks that script, and blocking the host
# script serves a blank page. Verified by corrupting one hash and watching the
# page fail to boot, so this is not a theoretical failure mode.
#
# build.py regenerates these on every build, so a mismatch means either the
# regex silently failed or vercel.json was hand-edited. Both are worth stopping
# a merge for.
csp=$(python3 - <<'PY'
import base64, hashlib, json, re, sys
page = open("index.html", encoding="utf-8").read()
cfg = json.load(open("vercel.json", encoding="utf-8"))
policy = ""
for rule in cfg.get("headers", []):
    for h in rule.get("headers", []):
        if h.get("key") == "Content-Security-Policy":
            policy = h["value"]
m = re.search(r"script-src ([^;]*);", policy)
if not m:
    print("NOSCRIPTSRC"); sys.exit()
directive = m.group(1)
if "'unsafe-inline'" in directive:
    print("UNSAFEINLINE"); sys.exit()
want = ["'sha256-" + base64.b64encode(hashlib.sha256(s.encode()).digest()).decode() + "'"
        for s in re.findall(r"<script>(.*?)</script>", page, re.S)]
if not want:
    print("NOSCRIPTS"); sys.exit()
missing = [h for h in want if h not in directive]
if missing:
    print("MISMATCH:%d/%d" % (len(missing), len(want))); sys.exit()
# Any inline handler attribute, any quoting, any case. The earlier form listed
# seven names and required double quotes, so onclick='...', onfocus=, ONCLICK=
# and unquoted values all slipped past a check whose whole job is to guarantee
# there are none.
_EVENTS = (r"click|dblclick|submit|reset|change|input|focus|blur|load|error|abort|"
           r"key(down|up|press)|mouse[a-z]+|pointer[a-z]+|touch[a-z]+|drag[a-z]*|drop|"
           r"scroll|resize|select|toggle|wheel|paste|copy|cut|contextmenu|"
           r"animation[a-z]+|transition[a-z]+")
if re.search(r"\son(" + _EVENTS + r")\s*=", page, re.I):
    print("INLINEHANDLER"); sys.exit()
print("OK:%d" % len(want))
PY
)
# The check above can never fail on its own, because smoke runs build.py first
# and build.py regenerates vercel.json — the tamper is repaired before the
# assertion reads it. Verified: corrupting a hash and reintroducing
# 'unsafe-inline' both still passed.
#
# The invariant that actually matters is different. There is no buildCommand,
# so Vercel serves the COMMITTED index.html and vercel.json verbatim. If a
# source change is committed without regenerating them, production serves a
# stale page — and a stale vercel.json means hashes that do not match the
# scripts, which is a blank site. So: after a fresh build, the working tree
# must be clean. If build.py changed anything, what was committed was wrong.
#
# Enforced in CI only. There the tree starts clean at HEAD, so any diff after a
# build means the committed outputs were stale. Locally the outputs differ from
# HEAD by design the moment you edit a source file, so this warns instead of
# failing rather than making the normal edit-build-test loop unusable.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  dirty=$(git status --porcelain -- index.html vercel.json 2>/dev/null)
  if [ -z "$dirty" ]; then
    pass "build outputs in sync with sources"
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    fail "index.html/vercel.json are STALE — a fresh build differs from what is committed, and Vercel serves the committed files verbatim: $(printf '%s' "$dirty" | tr '\n' ' ')"
  else
    printf "  \033[33mWARN\033[0m  %s\n" "build outputs differ from HEAD (expected while editing; enforced in CI)"
  fi
fi

# Exercise the policy for real. Everything above compares strings; none of it
# proves a browser accepts the result, because file:// ignores response headers
# entirely. This serves the built page with the exact vercel.json headers and
# asserts it still boots — the only check that would catch a hash mismatch
# before it blanks production.
CSPPORT=8749
python3 src/csp-serve.py "$(pwd)" "$CSPPORT" >/tmp/csp-serve.log 2>&1 &
CSPPID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$CSPPORT/index.html" && break; sleep 0.25
done
if curl -sI "http://127.0.0.1:$CSPPORT/index.html" | grep -qi "^content-security-policy:"; then
  $B goto "http://127.0.0.1:$CSPPORT/index.html" >/dev/null 2>&1
  booted=$($B js "typeof render==='function'&&typeof S==='object'&&document.getElementById('app').children.length>0" 2>/dev/null | tr -d '[:space:]')
  [ "$booted" = "true" ] \
    && pass "csp: page boots under the real policy (hashes accepted by the browser)" \
    || fail "csp: page did NOT boot under the real policy — a script hash is rejected; production would be BLANK"

  # The backend is reachable UNDER THE REAL POLICY. This is the check that
  # catches connect-src: a perfectly correct API layer still fails silently if
  # the policy forbids the origin — the browser blocks the request before it
  # leaves, and the only symptom is a console entry nobody reads. It must run
  # here, on the header-serving port, because file:// has no CSP at all and
  # would pass while production blocks every call.
  api=$($B js "typeof window.SporveAPI==='object'&&typeof window.SporveAPI.ping==='function'" 2>/dev/null | tr -d '[:space:]')
  [ "$api" = "true" ] \
    && pass "api: SporveAPI is present in the built page" \
    || fail "api: SporveAPI missing — mod-api.js did not inline"

  # The auth layer must be present and wired to the API layer. `onUnauthorized`
  # being registered is the load-bearing bit: without it an expired token is a
  # dead end for the user, which is the single most likely real-world failure.
  auth=$($B js "typeof window.SporveAuth==='object'&&typeof window.SporveAuth.signIn==='function'&&typeof window.SporveAuth.restore==='function'" 2>/dev/null | tr -d '[:space:]')
  [ "$auth" = "true" ] \
    && pass "auth: SporveAuth is present in the built page" \
    || fail "auth: SporveAuth missing — mod-auth.js did not inline"

  # A signed-out visitor must read as guest, never as verified. If this ever
  # says true with no session, every auth-gated surface is open to everyone.
  guest=$($B js "window.SporveAuth.isSignedIn()===false&&window.SporveAuth.userId()===null" 2>/dev/null | tr -d '[:space:]')
  [ "$guest" = "true" ] \
    && pass "auth: no session reads as signed-out (fails closed)" \
    || fail "auth: isSignedIn() is true with no session — auth-gated surfaces would be open"

  # Wrong credentials must reject with a human-readable message, not a raw code
  # and not a silent resolve. Uses a deliberately non-existent account.
  badlogin=$($B js "window.SporveAuth.signIn('nobody-'+Date.now()+'@gmail.com','wrongpassword123').then(()=>'FAIL:accepted').catch(e=>'OK:'+(e.code||'?')+':'+(e.message||'').slice(0,40))" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$badlogin" | tr -d '[:space:]')" in
    OK:invalid_credentials:*) pass "auth: wrong credentials rejected with a usable message" ;;
    FAIL:*) fail "auth: a bad password was ACCEPTED" ;;
    *) fail "auth: unexpected sign-in failure shape — $badlogin" ;;
  esac

  # FIX 1 — one store owns identity. If S.auth is persisted to sessionStorage
  # alongside the real token in localStorage, the two disagree the moment a tab
  # closes: UI signed-out, transport still authenticated (or the reverse).
  onestore=$($B js "(()=>{S.auth={status:'verified',user:{id:'x'}};saveState();const r=JSON.parse(sessionStorage.getItem('sporve:state:v1')||'{}');S.auth={status:'guest',user:null};return !('auth' in (r.s||r));})()" 2>/dev/null | tr -d '[:space:]')
  [ "$onestore" = "true" ] \
    && pass "auth: identity is NOT mirrored into sessionStorage (one store owns it)" \
    || fail "auth: S.auth is persisted as well as the token — two identity sources with different lifetimes"

  # FIX 2 — an intent must survive a full-page OAuth redirect. A closure cannot;
  # a descriptor can. This is the difference between returning from Google to
  # your booking and returning to the explore grid with it silently lost.
  intent=$($B js "(()=>{S.pendingIntent={kind:'book',programId:'p1'};saveState();const r=JSON.parse(sessionStorage.getItem('sporve:state:v1')||'{}');const st=r.s||r;S.pendingIntent=null;return !!(st.pendingIntent&&st.pendingIntent.kind==='book'&&st.pendingIntent.programId==='p1');})()" 2>/dev/null | tr -d '[:space:]')
  [ "$intent" = "true" ] \
    && pass "auth: a parked intent survives serialisation (OAuth-safe)" \
    || fail "auth: pendingIntent does not survive a reload — every deferred booking is lost through OAuth"

  # FIX 3 — a failed sign-in must leave somewhere to show why. The mock closed
  # the sheet unconditionally, which with a real backend means a wrong password
  # dismisses the modal and reports nothing.
  failpath=$($B js "typeof authFail==='function'&&typeof doSignIn==='function'&&typeof runIntent==='function'" 2>/dev/null | tr -d '[:space:]')
  [ "$failpath" = "true" ] \
    && pass "auth: sign-in has a failure branch and an intent replayer" \
    || fail "auth: authFail/doSignIn/runIntent missing — a failed sign-in has nowhere to report"

  ping=$($B js "window.SporveAPI.ping().then(r=>'OK:'+r.programs).catch(e=>'ERR:'+e.status+':'+e.message)" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$ping" | tr -d '[:space:]')" in
    OK:0)  fail "api: reached the backend but zero published programs — the marketplace has no inventory" ;;
    OK:*)  pass "api: reached Supabase under the real CSP and read live programs" ;;
    ERR:0:*) fail "api: request blocked before leaving the browser — connect-src does not allow the Supabase origin" ;;
    ERR:*) fail "api: backend rejected the request — $ping" ;;
    *)     fail "api: liveness probe returned nothing (harness or network problem)" ;;
  esac

  # ── PHASE C1 · the live catalogue ─────────────────────────────────────────
  # These run HERE, on the CSP-serving origin, and nowhere else. Every content
  # assertion in this file (no emoji, no exclamation marks, the 8-step type
  # scale, the contrast ratchet) measures a file:// page, where mod-catalog.js
  # deliberately never hydrates — so a coach writing "Let's go!" in a listing
  # title can never turn this build red. Structure is asserted against live
  # data; content is asserted against the seed.

  # A default page load now goes live — that is the product. An ordinary
  # visitor on the real origin must get real, bookable inventory.
  bydefault=$($B js "window.SporveCatalog.ready.then(live=>'OK:'+live+':'+document.documentElement.getAttribute('data-catalog')+':'+PROGRAMS.length).catch(e=>'THREW:'+e.message)" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$bydefault" | tr -d '[:space:]')" in
    OK:true:live:*) pass "catalog: a default load serves the live catalogue ($(printf '%s' "$bydefault" | cut -d: -f4) listings)" ;;
    OK:false:seed:*) fail "catalog: a default load fell back to sample data — the marketplace is showing listings nobody can book" ;;
    THREW:*)        fail "catalog: hydration threw — $bydefault" ;;
    *)              fail "catalog: unexpected default state ($bydefault)" ;;
  esac

  # The escape hatch must keep working: ?live=0 is how you get a deterministic
  # page for a screenshot or a side-by-side comparison.
  $B goto "http://127.0.0.1:$CSPPORT/index.html?live=0" >/dev/null 2>&1
  forced=$($B js "window.SporveCatalog.ready.then(live=>'OK:'+live+':'+document.documentElement.getAttribute('data-catalog')+':'+PROGRAMS.length)" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$forced" | tr -d '[:space:]')" in
    OK:false:seed:30) pass "catalog: ?live=0 forces the seeded catalogue" ;;
    *)                fail "catalog: ?live=0 did not pin the seed ($forced)" ;;
  esac

  # ?live=1 must reach production data and REPLACE the array in place. Array
  # identity is the whole migration strategy: ten modules captured this object,
  # so a reassignment would leave half the page reading a catalogue that no
  # longer updates. Captured before, compared after.
  $B goto "http://127.0.0.1:$CSPPORT/index.html?live=1" >/dev/null 2>&1
  livecat=$($B js "(function(){var before=PROGRAMS;return window.SporveCatalog.ready.then(function(live){
    if(!live) return 'FELLBACK:'+document.documentElement.getAttribute('data-catalog');
    if(PROGRAMS!==before) return 'REASSIGNED';
    if(!PROGRAMS.length) return 'EMPTY';
    var bad=PROGRAMS.filter(function(p){return !p.id||!p.title||!p.sport||typeof p.price!=='number'||!p.biz;});
    if(bad.length) return 'MALFORMED:'+bad.length;
    if(PROGRAMS.some(function(p){return !p.live;})) return 'MIXED';
    return 'OK:'+PROGRAMS.length;
  });})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$livecat" | tr -d '[:space:]')" in
    OK:*)        pass "catalog: ?live=1 replaced the catalogue in place with ${livecat#*OK:} live listings" ;;
    REASSIGNED)  fail "catalog: PROGRAMS was REASSIGNED, not mutated — every module that captured it is now stale" ;;
    EMPTY)       fail "catalog: hydrated to an empty catalogue — the grid would render nothing" ;;
    MALFORMED:*) fail "catalog: ${livecat#*MALFORMED:} live rows are missing a field the renderer reads" ;;
    MIXED)       fail "catalog: seed and live rows are both present — the page has two realities" ;;
    FELLBACK:*)  fail "catalog: ?live=1 could not reach the backend and fell back ($livecat)" ;;
    *)           fail "catalog: live hydration returned nothing ($livecat)" ;;
  esac

  # A live listing must resolve REAL session slots. The seeded fallback derives
  # its dates by parsing an integer out of "prog_7"; a uuid parses to NaN and
  # toISOString() throws RangeError, so this is the assertion standing between
  # a live catalogue and every card rendering Invalid Date.
  # EVERY live listing, not just the first, and every slot must be a real row.
  # A slot without live:true came from the generated fallback — three
  # plausible, bookable-looking dates for sessions that do not exist, which
  # fail at the insert after the family has picked a time and reached checkout.
  liveslots=$($B js "(function(){try{
    /* Shape is not enough: /^\d{4}-\d{2}-\d{2}\$/ accepts 2026-02-30 and
       2026-13-01, and Date() silently normalises both to a DIFFERENT day — so
       the check would pass while a card showed the wrong date. Round-trip
       through UTC and require the components to come back unchanged. */
    var validDate=function(v){
      var m=/^(\d{4})-(\d{2})-(\d{2})\$/.exec(String(v));
      if(!m) return false;
      var d=new Date(v+'T00:00:00Z');
      return d.getUTCFullYear()===+m[1] && d.getUTCMonth()+1===+m[2] && d.getUTCDate()===+m[3];
    };
    if(validDate('2026-02-30')||validDate('2026-13-01')||!validDate('2026-02-28')) return 'SELFTEST';
    var total=0, empty=0;
    for(var i=0;i<PROGRAMS.length;i++){
      var s=slotsFor(PROGRAMS[i].id);
      if(!s||!s.length){ empty++; continue; }
      if(s.some(function(x){return !x.live;})) return 'FABRICATED:'+PROGRAMS[i].id;
      if(s.some(function(x){return !validDate(x.date);})) return 'BADDATE:'+PROGRAMS[i].id;
      total+=s.length;
    }
    if(empty===PROGRAMS.length) return 'NOSLOTS';
    return 'OK:'+total+':'+empty;
  }catch(e){return 'THREW:'+e.name+':'+e.message;}})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$liveslots" | tr -d '[:space:]')" in
    OK:*:0)      pass "catalog: every live listing resolves real sessions ($(printf '%s' "$liveslots" | cut -d: -f2) in total)" ;;
    OK:*)        pass "catalog: live sessions resolve; $(printf '%s' "$liveslots" | cut -d: -f3) listing(s) correctly show no openings" ;;
    NOSLOTS)     fail "catalog: no live listing has a bookable session — nothing on the page can be booked" ;;
    FABRICATED:*) fail "catalog: a live listing was given INVENTED session dates (${liveslots#*FABRICATED:}) — it would fail at checkout" ;;
    BADDATE:*)   fail "catalog: a live slot carries an impossible or unparseable date (${liveslots#*BADDATE:})" ;;
    SELFTEST)    fail "catalog: the date validator itself is wrong — it accepted 2026-02-30 or rejected a real date" ;;
    THREW:*)     fail "catalog: slotsFor threw on a live listing — $liveslots" ;;
    *)           fail "catalog: slot probe returned nothing ($liveslots)" ;;
  esac

  # The coach portal is still sample data and must stay pinned to it. Without
  # DEMO_CATALOGUE this returns [] and the modules' fallbacks hand the demo
  # coach a real provider's listing to manage.
  coachpin=$($B js "(function(){try{
    var mine=DEMO_CATALOGUE.filter(function(p){return S.listings.indexOf(p.id)>=0;});
    if(!mine.length) return 'ORPHANED';
    if(PROGRAMS.some(function(p){return S.listings.indexOf(p.id)>=0;})) return 'LEAKED';
    return 'OK:'+mine.length;
  }catch(e){return 'THREW:'+e.name;}})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$coachpin" | tr -d '[:space:]')" in
    OK:*)     pass "catalog: the coach portal stays on its own ${coachpin#*OK:} demo listings" ;;
    ORPHANED) fail "catalog: the coach's listings resolve to nothing — the whole portal empties out" ;;
    LEAKED)   fail "catalog: a live listing matched S.listings — the demo coach is being shown a real provider's business" ;;
    THREW:*)  fail "catalog: coach-listing probe threw — $coachpin" ;;
    *)        fail "catalog: coach-listing probe returned nothing ($coachpin)" ;;
  esac

  # Every map pin must land ON the canvas. The bbox was hardcoded to Miami
  # under a comment claiming Chicago; real coordinates projected to
  # left:-3154%, top:-7456% and the map rendered empty under a header counting
  # ten programs. Bounds are derived now, so this asserts the derivation.
  mappins=$($B js "(function(){try{
    S.route={name:'map',arg:null}; render();
    var pins=[].slice.call(document.querySelectorAll('[style*=left]')).map(function(e){return e.style.left;})
      .filter(function(v){return /%\$/.test(v);}).map(parseFloat).filter(function(n){return !isNaN(n);});
    var b=mapBounds(PROGRAMS);
    var xs=PROGRAMS.map(function(p){return ((p.lng-b.LNG[0])/(b.LNG[1]-b.LNG[0]))*100;});
    var ys=PROGRAMS.map(function(p){return (1-(p.lat-b.LAT[0])/(b.LAT[1]-b.LAT[0]))*100;});
    var bad=xs.concat(ys).filter(function(n){return !isFinite(n)||n<0||n>100;});
    return bad.length?'OFFCANVAS:'+bad.length+':'+Math.round(bad[0]):'OK:'+xs.length;
  }catch(e){return 'THREW:'+e.message;}})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$mappins" | tr -d '[:space:]')" in
    OK:*)         pass "catalog: all $(printf '%s' "$mappins" | cut -d: -f2) live map pins project onto the canvas" ;;
    OFFCANVAS:*)  fail "catalog: $(printf '%s' "$mappins" | cut -d: -f2) map coordinate(s) land off-canvas (first at $(printf '%s' "$mappins" | cut -d: -f3)%) — the bbox does not match the data" ;;
    THREW:*)      fail "catalog: map projection threw — $mappins" ;;
    *)            fail "catalog: map probe returned nothing ($mappins)" ;;
  esac

  # No band may render a heading over a permanent empty state. Production has
  # only solo providers, so camps and teams must not appear at all — a promise
  # the inventory cannot keep is worse than an honest single band.
  deadband=$($B js "(function(){try{
    S.route={name:'explore',arg:null}; render();
    var empties=document.querySelectorAll('.kindrow-empty').length;
    var bands=document.querySelectorAll('.kind-band').length;
    if(!bands) return 'NOBANDS';
    return empties?'DEAD:'+empties:'OK:'+bands;
  }catch(e){return 'THREW:'+e.message;}})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$deadband" | tr -d '[:space:]')" in
    OK:*)    pass "catalog: browse renders $(printf '%s' "$deadband" | cut -d: -f2) band(s), none of them empty" ;;
    DEAD:*)  fail "catalog: $(printf '%s' "$deadband" | cut -d: -f2) band(s) render a heading over 'No matching programs' — a category the catalogue cannot fill" ;;
    NOBANDS) fail "catalog: browse rendered no bands at all — the grid is empty" ;;
    *)       fail "catalog: band probe returned nothing ($deadband)" ;;
  esac

  # Real listings must not be labelled as samples.
  provenance=$($B js "(function(){S.route={name:'explore',arg:null};render();
    return 'live='+catalogueIsLive()+' pills='+document.querySelectorAll('.kind-band .demo-pill').length;})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$provenance" | tr -d '[:space:]')" in
    live=truepills=0) pass "catalog: live listings carry no 'Demo data' label" ;;
    *)                fail "catalog: provenance label disagrees with the data source ($provenance)" ;;
  esac

  # Nothing above is worth anything if the live render throws.
  $B console --clear >/dev/null 2>&1
  $B js "S.route={name:'explore',arg:null};render();S.route={name:'home',arg:null};render();S.route={name:'map',arg:null};render();1" >/dev/null 2>&1
  liveerr=$($B console 2>/dev/null | grep -c "error" || true)
  [ "$liveerr" = "0" ] \
    && pass "catalog: home, explore and map render clean against live data" \
    || fail "catalog: $liveerr console error(s) rendering live data"

  # Leave the harness on a file:// page so later checks are unaffected.
  $B goto "file://$(pwd)/index.html" >/dev/null 2>&1
else
  fail "csp: local header server did not serve a policy — check could not run"
fi
{ kill "$CSPPID"; wait "$CSPPID"; } >/dev/null 2>&1

case "$csp" in
  OK:*)          pass "csp: ${csp#OK:} script hashes match the built page, no 'unsafe-inline'" ;;
  UNSAFEINLINE)  fail "csp: script-src still allows 'unsafe-inline' — the policy does not stop XSS" ;;
  MISMATCH:*)    fail "csp: ${csp#MISMATCH:} script hashes do not match the built page — production would serve a BLANK page" ;;
  INLINEHANDLER) fail "csp: an inline event-handler attribute is back; hashes cannot cover it and it will be blocked" ;;
  NOSCRIPTSRC)   fail "csp: no script-src directive found in vercel.json" ;;
  NOSCRIPTS)     fail "csp: no inline scripts found in the built page — the check has gone blind" ;;
  *)             fail "csp: $csp" ;;
esac

# ── session persistence ─────────────────────────────────────────────────
# Two invariants, both verified against a real browser rather than by reading
# the code. The page is loaded over file:// here, where sessionStorage is
# available but origin-scoped, which is enough to exercise save and restore.
#
# The second assertion is the one that matters: cmdPending is an unconfirmed
# broadcast to every family on a roster, and it must never come back after a
# reload. Persisting it would resurrect a message the coach never approved.
persist=$($B js "
(()=>{try{
  if(typeof saveState!=='function'||typeof loadState!=='function')return 'NOAPI';
  /* Snapshot and restore everything this check touches. Later assertions
     render marketing pages and would otherwise find the coach dashboard,
     and a snapshot left in sessionStorage would be restored by any later
     reload. A test that leaks state fails its neighbours, not itself. */
  const _p=S.portal,_t=S.coachTab,_r=S.route;
  S.portal='coach';S.coachTab='inbox';
  S.messages['__smoke']=[{id:'x',me:false,text:'persisted',at:TODAY}];
  S.cmdPending={convId:'__smoke',body:'MUST NOT SURVIVE',restated:'x'};
  saveState();
  const raw=sessionStorage.getItem('sporve:state:v1');
  if(!raw)return 'NOWRITE';
  const snap=JSON.parse(raw);
  const dataKept = snap.messages && snap.messages['__smoke'] && snap.messages['__smoke'][0].text==='persisted';
  const ephemeralDropped = !('cmdPending' in snap) && !('modal' in snap);
  /* Round-trip, not just write. A regression that drops data on RESTORE would
     leave the snapshot perfect and still lose the user's work, so wipe the
     in-memory value and prove loadState puts it back. */
  delete S.messages['__smoke'];
  loadState();
  const restored = !!(S.messages['__smoke'] && S.messages['__smoke'][0].text==='persisted');
  /* A hostile snapshot must not be able to replace S prototype: JSON.parse
     makes __proto__ an own key, and an in-operator guard is true by
     inheritance, so the naive loop would assign it.
     NOTE: no backticks anywhere in this block. It is interpolated inside a
     double-quoted shell string, where a backtick is command substitution --
     bash runs it and splices the output into the JavaScript. */
  /* The payload MUST be a raw JSON string. Writing {__proto__:{...}} as an
     object literal sets the prototype instead of creating an own key, so
     JSON.stringify drops it entirely and the test becomes vacuous — it passed
     against a knowingly vulnerable loader before this was fixed. */
  sessionStorage.setItem('sporve:state:v1', '{\"__proto__\":{\"PWN\":1},\"portal\":\"coach\"}');
  loadState();
  const protoSafe = Object.getPrototypeOf(S)===Object.prototype && S.PWN===undefined;
  delete S.messages['__smoke'];S.cmdPending=null;
  S.portal=_p;S.coachTab=_t;S.route=_r;
  try{sessionStorage.removeItem('sporve:state:v1')}catch(_){}
  render();
  if(!dataKept)return 'DATALOST';
  if(!restored)return 'RESTOREFAILED';
  if(!protoSafe)return 'PROTO_POLLUTION';
  if(!ephemeralDropped)return 'EPHEMERAL_PERSISTED';
  return 'OK';
}catch(e){return 'THREW:'+e.message}})()" 2>/dev/null | tr -d '"\r')
case "$persist" in
  OK)                  pass "persistence: data saved, ephemeral state dropped" ;;
  NOAPI)               fail "persistence: saveState/loadState missing" ;;
  NOWRITE)             fail "persistence: nothing written to sessionStorage" ;;
  DATALOST)            fail "persistence: data did not survive the snapshot" ;;
  RESTOREFAILED)       fail "persistence: snapshot written but loadState did not restore it — work is still lost" ;;
  PROTO_POLLUTION)     fail "persistence: a hostile snapshot replaced S's prototype or widened S" ;;
  EPHEMERAL_PERSISTED) fail "persistence: cmdPending or modal was persisted — an unconfirmed broadcast can resurrect" ;;
  *)                   fail "persistence: $persist" ;;
esac

# ── platform fee: one source, one rendered value ────────────────────────
# The 12% rate was authored in five places and partially migrated twice, so it
# was fixed three times and still shipped wrong. Two tripwires, because the two
# failure modes are different: a module re-declaring the constant shadows the
# host and drifts silently, and a hardcoded percentage in copy drifts without
# any constant being involved at all.
# Modules must not re-declare the rate, and NOTHING may hardcode the decimal.
# The earlier version grepped only src/mod-*.js, so a bare 0.12 in the host --
# exactly what the ported coach-portal work introduced -- slipped through. The
# runtime check could not catch it either: that surface renders "$45 gross ·
# $5 platform fee", a dollar figure with no percent sign for the scan to find.
redecl=$(grep -cE "^\s*const (FEE_RATE|FEE_PCT|PLATFORM_FEE)\s*=" src/mod-*.js 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
# Geometry and style also multiply by 0.12 -- an SVG circle radius at
# mod-companies.js:149 is not a platform fee -- so those lines are excluded by
# shape rather than by line number, which would rot on the next edit.
hardcoded=$(grep -nE "\*\s*0\.12\b" src/sporve-web.html src/sporve-web.host.html src/mod-*.js 2>/dev/null \
  | grep -vE "Math\.(min|max)\(|opacity|circle|rgba|scale\(|translate" | wc -l | tr -d ' ')
[ "$hardcoded" -eq 0 ] || fail "fee: $hardcoded hardcoded 0.12 literal(s) in source — use FEE_RATE"
[ "$redecl" -eq 0 ] && pass "fee: no module re-declares the rate" \
  || fail "fee: a module re-declares the rate — it shadows the host and will drift"

feep=$($B js "
(()=>{const pcts=new Set();
 const scan=()=>{const t=document.getElementById('app').innerText;const re=/(\d{1,2})%/g;let m;
   while((m=re.exec(t))){const c=t.slice(Math.max(0,m.index-45),m.index+30).toLowerCase();
     if(c.includes('fee')||c.includes('sporve'))pcts.add(m[1])}};
 S.auth={status:'verified'};S.portal='family';
 ['wallet','pricing','coachinfo','bookings'].forEach(r=>{try{S.route={name:r,arg:null};render();scan()}catch(e){}});
 S.portal='coach';['dashboard','finances','listings'].forEach(t=>{try{S.coachTab=t;render();scan()}catch(e){}});
 const a=[...pcts];
 if(typeof FEE_PCT==='undefined')return 'NOFEECONST';
 if(!a.length)return 'NONE';
 return a.length===1&&a[0]===String(FEE_PCT)?'OK:'+a[0]:'MIXED:'+a.join(',')})()" 2>/dev/null | tr -d '"\r')
case "$feep" in
  OK:*)        pass "fee: every rendered percentage is ${feep#OK:}%" ;;
  NOFEECONST)  fail "fee: FEE_PCT is not defined in the host — the single source is gone" ;;
  NONE)        fail "fee: no fee percentage rendered anywhere — the check has gone blind" ;;
  *)           fail "fee: rendered percentages disagree — $feep" ;;
esac

# ── §9 sweep — permanent bans, enforced so they cannot silently regress ──
# Any rule that is only an instruction eventually gets undone by a helpful edit;
# these are the tripwires. picsum is a URL, not documentation, so a static grep
# is right; the banned hues are checked on the RENDERED DOM (a dormant token or a
# colour-law comment mentioning #C2410C must not trip this, only a painted use).
c=$(grep -oc "picsum" index.html 2>/dev/null); c=${c:-0}
[ "$c" -eq 0 ] && pass "built index free of 'picsum'" || fail "'picsum' present in built index ($c)"
# Per marketing page: zero emoji codepoints, zero decorative svg inside a band
# (svg is allowed only in functional chrome), zero scaffolds, and no painted
# #C2410C (rgb 194,65,12) or #38BDF8 (rgb 56,189,248).
PAGES="what-is background-checks search map-search instant-booking messaging bookings-receipts saved athlete-progress scheduling payments roster session-notes media-consent insights ai-coach"
# Reset the portal EXPLICITLY before reloading. This used to be implicit: a
# reload wiped S back to defaults, so the coach checks above could not leak
# into the marketing-page checks below. Session persistence deliberately ends
# that — a reload now restores the previous state, which is the entire point of
# the feature — so the reset has to be stated rather than assumed. Set it
# before the goto, because `pagehide` snapshots whatever is in memory as the
# page unloads and that snapshot is what the next load restores.
$B js "S.portal='family';S.auth={status:'guest'};S.coachTab='dashboard';render();'reset'" >/dev/null 2>&1
$B goto "file://$(pwd)/index.html" >/dev/null 2>&1
sweep=$($B js "
(()=>{const em=/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}]/gu;const bad=[];
const banned=c=>c.includes('194, 65, 12')||c.includes('56, 189, 248');
'$PAGES'.split(' ').forEach(id=>{S.route={name:'page',arg:id};render();const a=document.querySelector('#app');if(!a)return;
 const e=(a.innerText.match(em)||[]).length;
 const svg=[...a.querySelectorAll('.pgband svg')].filter(s=>!s.closest('button,a,nav,input,select,label')).length;
 const scaf=a.textContent.includes('This page is being built')?1:0;
 let orange=0;a.querySelectorAll('*').forEach(el=>{const st=getComputedStyle(el);if(banned(st.color)||banned(st.backgroundColor))orange++});
 if(e>0||svg>0||scaf>0||orange>0)bad.push(id+'(emoji='+e+' svg='+svg+' scaffold='+scaf+' orange='+orange+')')});
return bad.length?bad.join(' '):'CLEAN'})()" 2>/dev/null)
sweepc=${sweep//\"/}; sweepc=$(printf '%s' "$sweepc" | tr -d '\r')
if [ "$(printf '%s' "$sweepc" | tr -d '[:space:]')" = "CLEAN" ]; then
  pass "17 pages: zero emoji, zero decorative in-band svg, zero scaffolds"
elif [ -z "$(printf '%s' "$sweepc" | tr -d '[:space:]')" ]; then
  printf "  \033[33mWARN\033[0m  %s\n" "§9 sweep did not return — re-run"
else fail "§9 sweep: $sweep"; fi
# Home + explore: zero emoji. Rails are now ALLOWED here: the owner overrode the
# no-rails §6.4 rule via the six-task spec 2026-08-08; the explore kind bands
# (.kindrow, T4) are intentional horizontal rows, so a rail no longer fails this
# check. Emoji stay banned; the rail count is dropped from the fail condition.
he=$($B js "
(()=>{const em=/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}]/gu;const o=[];
['home','explore'].forEach(r=>{S.route={name:r,arg:null};render();const a=document.querySelector('#app');
 const e=(a.innerText.match(em)||[]).length;
 if(e>0)o.push(r+'(emoji='+e+')')});return o.length?o.join(' '):'CLEAN'})()" 2>/dev/null)
[ "$(printf '%s' "${he//\"/}" | tr -d '[:space:]')" = "CLEAN" ] && pass "home + explore: zero emoji (rails allowed per six-task override)" || fail "home/explore sweep: $he"

# §1 — horizontal headlines: 40–54px, ≤3 rendered lines, ≥55% of the shell.
$B viewport 1440x900 >/dev/null 2>&1
$B goto "file://$(pwd)/index.html" >/dev/null 2>&1
t1=$($B js "
(()=>{const bad=[];'$PAGES'.split(' ').forEach(id=>{S.route={name:'page',arg:id};render();
 const h=document.querySelector('.pg-h1');const sh=document.querySelector('.pg-hero .shell');if(!h||!sh)return;
 const fs=parseFloat(getComputedStyle(h).fontSize);const lh=parseFloat(getComputedStyle(h).lineHeight);
 const lines=Math.round(h.clientHeight/lh);const w=Math.round(h.clientWidth/sh.clientWidth*100);
 if(fs<40||fs>54||lines>3||w<55)bad.push(id+'('+fs.toFixed(0)+'px,'+lines+'ln,'+w+'%)')});
return bad.length?bad.join(' '):'CLEAN'})()" 2>/dev/null)
[ "$(printf '%s' "${t1//\"/}" | tr -d '[:space:]')" = "CLEAN" ] && pass "17 heroes: horizontal, 40–54px, ≤3 lines, ≥55% width" || fail "§1 type: $t1"

# §4/§5 — every page owns exactly its own sig-<id>; no page shows a foreign one.
sm=$($B js "
(()=>{const ids='$PAGES'.split(' ');let own=0,leak=[];
ids.forEach(id=>{S.route={name:'page',arg:id};render();const a=document.querySelector('#app');
 if(!a.querySelector('.sig-'+id))leak.push(id+':own-missing');
 else own++;
 ids.forEach(o=>{if(o!==id&&a.querySelector('.sig-'+o))leak.push(id+':has-'+o)})});
return leak.length?leak.join(' '):('OK '+own)})()" 2>/dev/null)
case "$(printf '%s' "${sm//\"/}")" in
  *OK\ 16*) pass "16 unique signatures: each present on its own page, zero foreign leaks";;
  *) fail "§5 signatures: $sm";;
esac

# 100-point #88 — the <head> is finished (title in head, OG image, favicon).
head=$(awk 'BEGIN{p=1} /<\/head>/{print; exit} p' index.html)
{ printf '%s' "$head" | grep -q '<title>Sporve' && printf '%s' "$head" | grep -q 'og:image' && printf '%s' "$head" | grep -q 'rel="icon"'; } \
  && pass "#88 head finished (title · og:image · favicon)" || fail "#88 head incomplete"
# 100-point #58 — zero exclamation marks in rendered copy across routes + pages.
ex=$($B js "
(()=>{let n=0;'$ROUTES'.split(' ').forEach(r=>{S.auth={status:'guest'};S.route={name:r,arg:null};render();n+=(document.querySelector('#app').innerText.match(/!/g)||[]).length});
'$PAGES'.split(' ').forEach(id=>{S.route={name:'page',arg:id};render();n+=(document.querySelector('#app').innerText.match(/!/g)||[]).length});return n})()" 2>/dev/null | tr -d '[:space:]"')
[ "${ex:-x}" = "0" ] && pass "#58 zero exclamation marks in rendered copy" || fail "#58 exclamation marks in copy: $ex"

# §2 — darker slate present, the near-white grey retired.
grep -q "E9EEF4" index.html && pass "slate #E9EEF4 present" || fail "slate #E9EEF4 missing"
r=$(grep -oc "247, *248, *250\|247,248,250" index.html 2>/dev/null); r=${r:-0}
[ "$r" -eq 0 ] && pass "old near-white slate rgb(247,248,250) retired" || fail "old slate rgb(247,248,250) still present ($r)"

# The dark-ground invariant. Resolves the PAINTED background through
# transparent ancestors -- both historic contrast failures were inherited.
#
# Reload first. This runs after a 13-route loop, and evaluating a long script
# against a page left in an arbitrary state returned EMPTY often enough to
# produce a false FAIL with a blank violation list -- which is worse than no
# check, because a red build nobody believes gets ignored. Empty is now
# reported as "did not run", distinct from a real violation.
$B goto "file://$(pwd)/index.html" >/dev/null 2>&1
sleep 1
bad=$($B js "
(()=>{const lum=c=>{const v=c.map(x=>{x/=255;return x<=.03928?x/12.92:Math.pow((x+.055)/1.055,2.4)});return .2126*v[0]+.7152*v[1]+.0722*v[2]};
const rgb=s=>{const m=s.match(/[\d.]+/g);return m?m.slice(0,3).map(Number):null};
const al=s=>{const m=s.match(/[\d.]+/g);return m&&m.length>3?Number(m[3]):1};
const bgOf=e=>{while(e){const c=getComputedStyle(e).backgroundColor;if(c&&al(c)>.5)return rgb(c);e=e.parentElement}return [255,255,255]};
const out=[];'$ROUTES'.split(' ').forEach(r=>{S.auth={status:'guest'};S.route={name:r,arg:null};render();
 document.querySelectorAll('body *').forEach(el=>{if(!el.offsetParent)return;
  if(![...el.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()))return;
  const bg=bgOf(el);if(lum(bg)>.18)return;const fg=rgb(getComputedStyle(el).color);if(!fg)return;
  const q=(Math.max(lum(fg),lum(bg))+.05)/(Math.min(lum(fg),lum(bg))+.05);
  if(q<4.5)out.push(r+':'+(el.className||el.tagName)+'@'+q.toFixed(2))})});
return out.length?[...new Set(out)].slice(0,6).join(' | '):'CLEAN'})()" 2>/dev/null)
clean=${bad//\"/}; clean=$(printf '%s' "$clean" | tr -d '[:space:]')
if [ "$clean" = "CLEAN" ]; then pass "dark grounds carry white or slate text"
elif [ -z "$clean" ]; then printf "  \033[33mWARN\033[0m  %s\n" "dark-ground check did not return — re-run; not treated as a failure"
else fail "dark-ground violations: $bad"; fi

# Layout must never scroll horizontally.
for vp in 1440x900 768x1024 390x844; do
  $B viewport "$vp" >/dev/null 2>&1
  $B goto "file://$(pwd)/index.html" >/dev/null 2>&1
  # Reports the overshoot and the widest culprit rather than a bare boolean.
  # Text shaping differs between platforms, so a sub-pixel difference can round
  # a passing layout into a failing one; knowing whether it is 1px or 40px is
  # the difference between a tolerance and a real bug.
  o=$($B js "S.route={name:'home',arg:null};render();
(()=>{const b=document.body,over=b.scrollWidth-b.clientWidth;
 if(over<=1)return 'CLEAN:'+over;
 // An element only widens the page if nothing between it and <body> clips it.
 // A marquee inside overflow:hidden sticks out thousands of px and is
 // harmless; reporting it buries the element that actually scrolls the page.
 const clipped=el=>{for(let n=el.parentElement;n&&n!==b;n=n.parentElement){
   const o=getComputedStyle(n).overflowX; if(o!=='visible')return true} return false};
 const hits=[];document.querySelectorAll('#app *').forEach(el=>{
   if(clipped(el))return;
   const r=el.getBoundingClientRect();const x=Math.round(r.right-b.clientWidth);
   if(x>0)hits.push({x,el})});
 hits.sort((a,c)=>c.x-a.x);
 const id=h=>{const e=h.el,p=e.parentElement;
   return '+'+h.x+'px '+e.tagName+(e.className?'.'+String(e.className).split(' ')[0]:'')
     +' w='+Math.round(e.getBoundingClientRect().width)
     +' in '+(p?p.tagName+(p.className?'.'+String(p.className).split(' ')[0]:''):'?')
     +' ['+e.outerHTML.slice(0,60).replace(/\s+/g,' ')+']'};
 return 'OVER:'+over+' '+(hits.length?hits.slice(0,2).map(id).join(' || ')
   :'no unclipped culprit — sub-pixel accumulation')})()" 2>/dev/null | tr -d '\r')
  case "$(printf '%s' "$o" | tr -d '"')" in
    CLEAN*) pass "no horizontal overflow at $vp" ;;
    *)      fail "horizontal overflow at $vp — $o" ;;
  esac
done

# Type scale. 21/22px are the documented unboxed-glyph exceptions.
off=$($B js "
(()=>{const ok=[10.5,12,13,14.5,15.5,21,22];const bad=new Set();
document.querySelectorAll('body *').forEach(el=>{if(!el.offsetParent)return;
 if(![...el.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()))return;
 const s=parseFloat(getComputedStyle(el).fontSize);
 if(ok.includes(s))return;
 if(s>16&&s<20)return;      // --text-lg clamp
 if(s>=21&&s<=27)return;    // --text-xl clamp
 if(s>=24&&s<=32)return;    // --text-2xl clamp
 if(s>=32&&s<=54)return;    // --text-hero clamp
 bad.add(s)});
return bad.size?[...bad].join(','):'CLEAN'})()" 2>/dev/null)
[ "${off//\"/}" = "CLEAN" ] && pass "every rendered size is on the 8-step scale" \
  || fail "off-scale font sizes: $off"

echo "─────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ] && echo "  SMOKE PASSED" || echo "  SMOKE FAILED -- revert, do not push"
exit $FAIL
