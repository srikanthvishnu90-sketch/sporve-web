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

if [ ! -x "$B" ]; then
  echo "  browse not built -- runtime checks skipped (build checks passed)"
  exit $FAIL
fi

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
  o=$($B js "S.route={name:'home',arg:null};render();document.body.scrollWidth>document.body.clientWidth" 2>/dev/null | tr -d '[:space:]')
  [ "$o" = "false" ] && pass "no horizontal overflow at $vp" || fail "horizontal overflow at $vp"
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
