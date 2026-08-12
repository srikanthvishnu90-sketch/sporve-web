"use strict";
/* ═══════════════════════════════════════════════════════════════════
   MOD_SEARCH — advanced filtering, sorting, saved searches, compare.
   Additive module for sporve-web.html. Defines exactly one global,
   window.MOD_SEARCH, and never redefines a host symbol. It reads the
   host globals (S, PROGRAMS, esc, money, fmtDate, isVerified, render,
   toast, requireAuth, slotsFor, sportColor, sportGlyph, visiblePrograms,
   cardHTML, ICON) and stores its own data on S.adv / S.savedSearches /
   S.compareIds.

   The host's exploreHTML() knows nothing about this module, so the
   toolbar is injected into the live DOM at the end of every render and
   the existing card nodes are shown / hidden / reordered in place —
   the host's own click bindings on those cards survive untouched.
   A host that wants the filtering server-side can instead call
   MOD_SEARCH.applyAdvanced(list) from visiblePrograms(); it is pure.
   ═══════════════════════════════════════════════════════════════════ */
(function(){

/* the app's "now" — same anchor the host uses inside ageOf() */
const TODAY="2026-08-03";

/* Search origin. Chicago, IL — the launch city every seeded listing is labelled
   for. The lat/lng below are the demo reference frame (origin and listings share
   it, so haversine distances stay correct); only labels are user-visible.
   placeholder in the host's location field. Distances below are measured
   from here with a real haversine against each listing's lat/lng. */
const ORIGIN={lat:41.8781,lng:-87.6298,label:"Chicago, IL"};
const EARTH_MI=3958.7613;                 /* mean earth radius, miles */

/* pricing-model wording (local copy — the host's modelLabel is not part
   of the module contract, so this module carries its own) */
const MODEL_LABEL={single_session:"per session",monthly:"per month",package:"per package",seasonal:"per season"};
const MODEL_ORDER=["single_session","monthly","package","seasonal"];
const SKILL_ORDER=["Beginner","Intermediate","Advanced","All Levels"];
const POLICY_LABEL={flexible:"Flexible",moderate:"Moderate",strict:"Strict"};

/* ── date helpers (no library, no network) ───────────────────────── */
const parseISO=d=>{const[y,m,dd]=String(d).split("-").map(Number);return new Date(y,m-1,dd);};
const toISO=dt=>`${dt.getFullYear()}-${String(dt.getMonth()+1).padStart(2,"0")}-${String(dt.getDate()).padStart(2,"0")}`;
const addDays=(d,n)=>{const t=parseISO(d);t.setDate(t.getDate()+n);return toISO(t);};

/* ── numeric compare that never returns NaN ──────────────────────── */
const asc=(x,y)=>{x=Number.isFinite(x)?x:Infinity;y=Number.isFinite(y)?y:Infinity;return x===y?0:(x<y?-1:1);};
const desc=(x,y)=>{x=Number.isFinite(x)?x:-Infinity;y=Number.isFinite(y)?y:-Infinity;return x===y?0:(x>y?-1:1);};

/* ═══════════════════ haversine ═══════════════════
   Great-circle distance in statute miles. Not an approximation of the
   grid on the map screen — the real thing, on the listing's own lat/lng. */
const rad=d=>d*Math.PI/180;
function haversineMi(aLat,aLng,bLat,bLng){
  const la1=Number(aLat),ln1=Number(aLng),la2=Number(bLat),ln2=Number(bLng);
  if(![la1,ln1,la2,ln2].every(Number.isFinite)) return Infinity;
  const dLat=rad(la2-la1),dLng=rad(ln2-ln1);
  const h=Math.sin(dLat/2)*Math.sin(dLat/2)+
    Math.cos(rad(la1))*Math.cos(rad(la2))*Math.sin(dLng/2)*Math.sin(dLng/2);
  return 2*EARTH_MI*Math.asin(Math.min(1,Math.sqrt(h)));
}
const distanceOf=p=>p?haversineMi(ORIGIN.lat,ORIGIN.lng,p.lat,p.lng):Infinity;
const miles=n=>Number.isFinite(n)?`${n.toFixed(1)} mi`:"Location unknown";

/* ═══════════════════ state plumbing ═══════════════════ */
const DEFAULT_ADV={
  priceMin:null,priceMax:null,   /* null on either end = that end unbounded */
  age:null,                      /* athlete age; matches minAge <= age <= maxAge */
  skill:[],                      /* multi-select over the published level     */
  models:[],                     /* multi-select over the pricing model       */
  distance:null,                 /* miles from ORIGIN                          */
  minRating:null,                /* 3 | 4 | 4.5                                */
  availDays:null,                /* has a published slot within N days of TODAY */
  bgOnly:false,                  /* background-checked providers only          */
  openOnly:false,                /* enrolled < cap                             */
  sort:"recommended",
};
const clone=v=>JSON.parse(JSON.stringify(v));
/* fallback used only if the module is loaded without the host's S */
const LOCAL={adv:clone(DEFAULT_ADV),savedSearches:[],compareIds:[]};

function ensure(){
  if(typeof S==="undefined"||!S) return;
  if(!S.adv||typeof S.adv!=="object") S.adv=clone(DEFAULT_ADV);
  for(const k of Object.keys(DEFAULT_ADV)) if(!(k in S.adv)) S.adv[k]=clone(DEFAULT_ADV[k]);
  if(!Array.isArray(S.adv.skill)) S.adv.skill=[];
  if(!Array.isArray(S.adv.models)) S.adv.models=[];
  if(!Array.isArray(S.savedSearches)) S.savedSearches=[];
  if(!Array.isArray(S.compareIds)) S.compareIds=[];
}
const host=()=>(typeof S!=="undefined"&&S)?S:LOCAL;
const adv=()=>{ensure();return host().adv||LOCAL.adv;};
const saved=()=>{ensure();return host().savedSearches||LOCAL.savedSearches;};
const compareIds=()=>{ensure();return host().compareIds||LOCAL.compareIds;};
/* A saved search or compare list persisted before the catalogue went live
   still holds seeded ids, so fall back rather than resolve to undefined. */
const prog=id=>PROGRAMS.find(p=>p.id===id)||DEMO_CATALOGUE.find(p=>p.id===id);
const catalogue=()=>(typeof PROGRAMS!=="undefined"&&Array.isArray(PROGRAMS))?PROGRAMS:[];

/* ── bounds derived from the catalogue, never hardcoded ──────────── */
function priceBounds(){
  const ps=catalogue().map(p=>Number(p.price)).filter(Number.isFinite);
  if(!ps.length) return {lo:0,hi:1};
  const lo=Math.floor(Math.min.apply(null,ps));
  const hi=Math.ceil(Math.max.apply(null,ps));
  return {lo,hi:hi>lo?hi:lo+1};
}
function ageBounds(){
  const lo=catalogue().map(p=>Number(p.minAge)).filter(Number.isFinite);
  const hi=catalogue().map(p=>Number(p.maxAge)).filter(Number.isFinite);
  return {lo:lo.length?Math.min.apply(null,lo):0,hi:hi.length?Math.max.apply(null,hi):99};
}
const countWhere=fn=>catalogue().filter(fn).length;

/* ── availability, read straight off the published schedule ──────── */
function slotsOf(id){
  try{ const s=slotsFor(id); return Array.isArray(s)?s:[]; }catch(e){ return []; }
}
function hasSlotWithin(id,days){
  const end=addDays(TODAY,days);
  return slotsOf(id).some(s=>s.date>=TODAY&&s.date<=end);
}
function nextSession(id){
  const list=slotsOf(id);
  const up=list.filter(s=>s.date>=TODAY).sort((a,b)=>a.date.localeCompare(b.date));
  if(up.length) return {upcoming:true,slot:up[0]};
  const past=list.slice().sort((a,b)=>b.date.localeCompare(a.date))[0]||null;
  return {upcoming:false,slot:past};
}
/* the last date anything is on the books for — used to explain an
   availability window that legitimately matches nothing */
function scheduleHorizon(){
  let max=null;
  catalogue().forEach(p=>slotsOf(p.id).forEach(s=>{if(!max||s.date>max) max=s.date;}));
  return max;
}
const anyUpcoming=()=>catalogue().some(p=>slotsOf(p.id).some(s=>s.date>=TODAY));

/* ═══════════════════ 2 · sort ═══════════════════
   Every comparator is total and the sort is stabilised by the item's
   original index, so equal rows never shuffle between renders.
   "Recommended" is rating first, then the number of ratings behind it —
   a 4.8 from 40 families is better evidence than a 4.8 from 7. It is
   not a hidden promotion of featured or paid listings. */
const SORTS={
  recommended:(a,b)=>desc(Number(a.rating),Number(b.rating))||desc(Number(a.reviews),Number(b.reviews)),
  price_asc:(a,b)=>asc(Number(a.price),Number(b.price)),
  price_desc:(a,b)=>desc(Number(a.price),Number(b.price)),
  rating:(a,b)=>desc(Number(a.rating),Number(b.rating)),
  distance:(a,b)=>asc(distanceOf(a),distanceOf(b)),
  reviews:(a,b)=>desc(Number(a.reviews),Number(b.reviews)),
};
const SORT_LABEL={
  recommended:"Recommended",
  price_asc:"Price: low to high",
  price_desc:"Price: high to low",
  rating:"Rating",
  distance:"Distance from "+ORIGIN.label,
  reviews:"Most reviewed",
};
function sortList(list,key){
  const cmp=SORTS[key]||SORTS.recommended;
  return list.map((p,i)=>({p,i}))
    .sort((x,y)=>{const d=cmp(x.p,y.p);return d!==0?d:x.i-y.i;})
    .map(x=>x.p);
}

/* ═══════════════════ 1 · the filter itself ═══════════════════
   Pure: reads the declared filter set, returns a new array, mutates
   nothing. Safe for the host to call from visiblePrograms(). */
function applyAdvanced(list){
  const a=adv();
  const {lo,hi}=priceBounds();
  let out=(Array.isArray(list)?list:catalogue()).slice();

  if(a.priceMin!=null||a.priceMax!=null){
    const min=a.priceMin==null?lo:Number(a.priceMin);
    const max=a.priceMax==null?hi:Number(a.priceMax);
    out=out.filter(p=>Number(p.price)>=min&&Number(p.price)<=max);
  }
  if(a.age!=null&&a.age!==""&&Number.isFinite(Number(a.age))){
    const age=Number(a.age);
    out=out.filter(p=>Number(p.minAge)<=age&&age<=Number(p.maxAge));
  }
  if(a.skill&&a.skill.length)   out=out.filter(p=>a.skill.indexOf(p.skill)>=0);
  if(a.models&&a.models.length) out=out.filter(p=>a.models.indexOf(p.model)>=0);
  if(a.distance!=null)          out=out.filter(p=>distanceOf(p)<=Number(a.distance));
  if(a.minRating!=null)         out=out.filter(p=>Number(p.rating)>=Number(a.minRating));
  if(a.availDays!=null)         out=out.filter(p=>hasSlotWithin(p.id,Number(a.availDays)));
  if(a.bgOnly)                  out=out.filter(p=>p.verified===true);
  if(a.openOnly)                out=out.filter(p=>Number(p.enrolled)<Number(p.cap));

  return sortList(out,a.sort);
}

/* how many controls are away from their default */
function activeCount(){
  const a=adv();let n=0;
  if(a.priceMin!=null||a.priceMax!=null)n++;
  if(a.age!=null)n++;
  if(a.skill.length)n++;
  if(a.models.length)n++;
  if(a.distance!=null)n++;
  if(a.minRating!=null)n++;
  if(a.availDays!=null)n++;
  if(a.bgOnly)n++;
  if(a.openOnly)n++;
  return n;
}
const baseList=()=>{
  try{ return (typeof visiblePrograms==="function")?visiblePrograms():catalogue().slice(); }
  catch(e){ return catalogue().slice(); }
};
const matchCount=()=>applyAdvanced(baseList()).length;

/* human-readable summary of the live filter set */
function summaryParts(){
  const a=adv(),{lo,hi}=priceBounds(),out=[];
  if(a.priceMin!=null||a.priceMax!=null)
    out.push(["Price",`${money(a.priceMin==null?lo:a.priceMin)} to ${money(a.priceMax==null?hi:a.priceMax)}`]);
  if(a.age!=null) out.push(["Athlete age",String(a.age)]);
  if(a.skill.length) out.push(["Skill level",a.skill.join(", ")]);
  if(a.models.length) out.push(["Pricing",a.models.map(m=>MODEL_LABEL[m]||m).join(", ")]);
  if(a.distance!=null) out.push(["Distance",`within ${a.distance} mi of ${ORIGIN.label}`]);
  if(a.minRating!=null) out.push(["Rating",`${a.minRating.toFixed(1)} and up`]);
  if(a.availDays!=null) out.push(["Availability",`a session within ${a.availDays} days`]);
  if(a.bgOnly) out.push(["Background check","cleared providers only"]);
  if(a.openOnly) out.push(["Capacity","open spots only"]);
  const h=host();
  if(h.sport) out.push(["Sport",String(h.sport)]);
  if(h.query&&String(h.query).trim()) out.push(["Search",String(h.query).trim()]);
  if(h.filters&&h.filters.verifiedOnly) out.push(["Quick filter","background-checked"]);
  if(h.filters&&h.filters.maxPrice!=null) out.push(["Quick filter",`under ${money(h.filters.maxPrice)}`]);
  if(h.filters&&h.filters.model) out.push(["Quick filter",MODEL_LABEL[h.filters.model]||h.filters.model]);
  out.push(["Sorted by",SORT_LABEL[a.sort]||a.sort]);
  return out;
}
function suggestName(){
  const h=host(),a=adv(),bits=[];
  if(h.sport) bits.push(String(h.sport));
  if(h.query&&String(h.query).trim()) bits.push(`"${String(h.query).trim()}"`);
  if(a.age!=null) bits.push(`age ${a.age}`);
  if(a.priceMax!=null) bits.push(`up to ${money(a.priceMax)}`);
  if(a.minRating!=null) bits.push(`${a.minRating.toFixed(1)}+`);
  if(a.distance!=null) bits.push(`within ${a.distance} mi`);
  if(a.bgOnly) bits.push("background-checked");
  return bits.length?bits.join(" · "):"All programs";
}

/* ═══════════════════ shared markup helpers ═══════════════════ */
function wrap(title,body){
  return `<div class="scrim" data-scrim="1"><div class="modal wide" role="dialog" aria-modal="true" aria-label="${esc(title)}"><div class="modal-head"><b>${esc(title)}</b><button class="x" data-close="1" aria-label="Close">${ICON.x}</button></div><div class="modal-body">${body}</div></div></div>`;
}
function clearBtn(group,label,on){
  return `<button type="button" class="se-clear ${on?"":"hide"}" data-seclear="${esc(group)}"
    aria-label="Clear the ${esc(label)} filter">Clear</button>`;
}
function checkOpt(attr,value,label,tail,on){
  const id=`se_${attr}_${String(value).replace(/[^A-Za-z0-9]/g,"")}`;
  return `<label class="se-opt" for="${id}">
    <input type="checkbox" id="${id}" data-${esc(attr)}="${esc(value)}"${on?" checked":""}>
    <span>${esc(label)}</span>${tail?`<i class="num">${esc(tail)}</i>`:""}</label>`;
}
function radioOpt(attr,name,value,label,on){
  const id=`se_${attr}_${String(value).replace(/[^A-Za-z0-9]/g,"")||"any"}`;
  return `<label class="se-opt" for="${id}">
    <input type="radio" id="${id}" name="${esc(name)}" value="${esc(value)}" data-${esc(attr)}="${esc(value)}"${on?" checked":""}>
    <span>${esc(label)}</span></label>`;
}

/* ═══════════════════ 1 · filters modal ═══════════════════ */
function filtersModal(){
  ensure();
  const a=adv();
  const {lo,hi}=priceBounds();
  const ab=ageBounds();
  const pmin=a.priceMin==null?lo:a.priceMin;
  const pmax=a.priceMax==null?hi:a.priceMax;
  const horizon=scheduleHorizon();
  const upcoming=anyUpcoming();

  const priceNote=(a.priceMin==null&&a.priceMax==null)
    ? `Full catalogue range, ${money(lo)} to ${money(hi)}`
    : `${money(pmin)} to ${money(pmax)}`;

  return wrap("Filters",`
    <p class="se-lede">Every control below reads the published listing data. Nothing is inferred, and a
      program is never shown as available or background-checked unless its own record says so.</p>

    <fieldset class="se-fs">
      <legend>Price</legend>
      ${clearBtn("price","price",a.priceMin!=null||a.priceMax!=null)}
      <div class="se-dual">
        <div class="se-track" aria-hidden="true"><span class="se-fill" id="sePriceFill"></span></div>
        <label class="se-sr" for="sePriceLo">Minimum price</label>
        <input type="range" id="sePriceLo" class="se-range" data-seprice="lo"
          min="${lo}" max="${hi}" step="1" value="${pmin}"
          aria-valuemin="${lo}" aria-valuemax="${hi}" aria-valuenow="${pmin}"
          aria-valuetext="Minimum ${money(pmin)}">
        <label class="se-sr" for="sePriceHi">Maximum price</label>
        <input type="range" id="sePriceHi" class="se-range" data-seprice="hi"
          min="${lo}" max="${hi}" step="1" value="${pmax}"
          aria-valuemin="${lo}" aria-valuemax="${hi}" aria-valuenow="${pmax}"
          aria-valuetext="Maximum ${money(pmax)}">
      </div>
      <p class="se-val num" id="sePriceVal">${esc(priceNote)}</p>
      <p class="se-hint">Both handles take arrow keys. Listed prices are what the provider charges for
        their own tier — the model differs per listing, so compare the model too.</p>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Athlete age</legend>
      ${clearBtn("age","athlete age",a.age!=null)}
      <div class="se-inline">
        <label class="se-sr" for="seAge">Athlete age in years</label>
        <input type="number" id="seAge" class="se-num" inputmode="numeric"
          min="${ab.lo}" max="${ab.hi}" step="1" placeholder="Any age"
          value="${a.age==null?"":esc(String(a.age))}">
        <span class="se-hint">years old</span>
      </div>
      <p class="se-hint">Keeps only the listings whose own published range contains that age
        (${ab.lo}–${ab.hi} across the catalogue).</p>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Skill level</legend>
      ${clearBtn("skill","skill level",a.skill.length>0)}
      <div class="se-opts">
        ${SKILL_ORDER.map(s=>{
          const n=countWhere(p=>p.skill===s);
          return checkOpt("seskill",s,s,n?`${n}`:"none listed",a.skill.indexOf(s)>=0);
        }).join("")}
      </div>
      <p class="se-hint">Counts are catalogue-wide. This matches the level a listing publishes —
        "All Levels" is its own option rather than a wildcard.</p>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Pricing model</legend>
      ${clearBtn("models","pricing model",a.models.length>0)}
      <div class="se-opts">
        ${MODEL_ORDER.map(m=>{
          const n=countWhere(p=>p.model===m);
          return checkOpt("semodel",m,MODEL_LABEL[m],n?`${n}`:"none listed",a.models.indexOf(m)>=0);
        }).join("")}
      </div>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Distance</legend>
      ${clearBtn("distance","distance",a.distance!=null)}
      <div class="se-inline">
        <label for="seDistance">From ${esc(ORIGIN.label)}</label>
        <select id="seDistance" class="se-select">
          <option value=""${a.distance==null?" selected":""}>Any distance</option>
          ${[5,10,25,50].map(d=>`<option value="${d}"${Number(a.distance)===d?" selected":""}>Within ${d} miles</option>`).join("")}
        </select>
      </div>
      <p class="se-hint num">Great-circle distance from ${esc(ORIGIN.lat.toFixed(4))}, ${esc(ORIGIN.lng.toFixed(4))}
        to each listing's own coordinates. Straight-line, not driving time.</p>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Rating</legend>
      ${clearBtn("minRating","rating",a.minRating!=null)}
      <div class="se-opts">
        ${radioOpt("serating","seRating","","Any rating",a.minRating==null)}
        ${[3,4,4.5].map(v=>radioOpt("serating","seRating",String(v),`${v.toFixed(1)} and up`,Number(a.minRating)===v)).join("")}
      </div>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Availability</legend>
      ${clearBtn("availDays","availability",a.availDays!=null)}
      <div class="se-opts">
        ${radioOpt("seavail","seAvail","","Any time",a.availDays==null)}
        ${[7,14,30].map(d=>radioOpt("seavail","seAvail",String(d),`A session in the next ${d} days`,Number(a.availDays)===d)).join("")}
      </div>
      <p class="se-hint">Measured from today, ${esc(fmtDate(TODAY))}, against each listing's published
        session dates.${upcoming?"":` No listing currently publishes a session on or after today${
          horizon?` — the latest published session is ${esc(fmtDate(horizon))}`:""}, so these windows
          match nothing until new sessions go up. The filter is not broken; the schedule is empty.`}</p>
    </fieldset>

    <fieldset class="se-fs">
      <legend>Trust and capacity</legend>
      ${clearBtn("flags","trust and capacity",a.bgOnly||a.openOnly)}
      <div class="se-opts se-opts-1">
        ${checkOpt("sebg","1","Background-checked providers only",
          `${countWhere(p=>p.verified===true)}`,a.bgOnly)}
        ${checkOpt("seopen","1","Has open spots",
          `${countWhere(p=>Number(p.enrolled)<Number(p.cap))}`,a.openOnly)}
      </div>
      <p class="se-hint">Open spots compares the listing's enrolled count against its own capacity.</p>
    </fieldset>

    <div class="se-foot">
      <p class="se-count num" id="seCount" role="status" aria-live="polite"></p>
      <div class="se-footbtns">
        <button type="button" class="btn ghost" data-seclearall="1">Clear all</button>
        <button type="button" class="btn" id="seApply" data-seapply="1">Show results</button>
      </div>
    </div>`);
}

/* ═══════════════════ 3 · save-this-search modal ═══════════════════ */
function saveSearchModal(){
  ensure();
  const list=saved();
  const n=matchCount();
  return wrap("Save this search",`
    <p class="se-lede">A saved search stores every control exactly as it stands now — sport, text,
      the quick filters, all nine advanced controls, and the sort order. Re-applying restores all of them.</p>
    <form id="seSaveForm" novalidate>
      <div class="field">
        <label for="seSaveName">Name this search</label>
        <input id="seSaveName" name="name" maxlength="60" value="${esc(suggestName())}"
          placeholder="Weeknight soccer under $50" required>
      </div>
      <div class="se-sum">
        <span class="eyebrow">What gets stored</span>
        <dl class="se-dl">
          ${summaryParts().map(([k,v])=>`<div class="linerow"><dt>${esc(k)}</dt><dd class="num">${esc(v)}</dd></div>`).join("")}
        </dl>
        <p class="se-count num" role="status" aria-live="polite">${n} program${n===1?"":"s"} match right now</p>
      </div>
      <div id="seSaveErr" class="err hide" style="margin:2px 0 10px"></div>
      <button class="btn wide" type="submit">Save search</button>
    </form>
    ${list.length?`<div class="se-sum" style="margin-top:20px">
      <span class="eyebrow">Saved searches</span>
      <div class="se-chips" style="margin-top:10px">
        ${list.map(s=>`<span class="se-chip">
          <button type="button" class="se-chip-b" data-seuse="${esc(s.id)}">${esc(s.name)} <i class="num">${s.count}</i></button>
          <button type="button" class="se-chip-x" data-sedrop="${esc(s.id)}" aria-label="Delete the saved search ${esc(s.name)}">${ICON.x}</button>
        </span>`).join("")}
      </div>
      <p class="se-hint">The count next to each name is the number of matches at the moment it was saved,
        not a live figure.</p>
    </div>`:""}`);
}

/* ═══════════════════ 4 · compare view ═══════════════════ */
function nav(){
  return (typeof subnavHTML==="function"&&typeof S!=="undefined"&&S.portal!=="coach")?subnavHTML():"";
}
const CAP=3;

/* A row is highlightable only where "better" is a fact rather than a
   preference: the lower price (and only when the pricing model is the
   same on every column), the higher rating, the shorter distance.
   Review count, ages, skill, capacity, policy and background-check
   status get no mark — they are differences, not rankings. */
function compareRows(picks){
  const sameModel=picks.every(p=>p.model===picks[0].model);
  return [
    {label:"Price",best:sameModel?"min":null,
     val:p=>Number(p.price),
     cell:p=>`<b class="num">${money(p.price)}</b> <span class="se-dim">${esc(MODEL_LABEL[p.model]||p.model)}</span>`,
     note:sameModel?"":"Prices are not directly comparable — these listings bill on different models."},
    {label:"Pricing model",best:null,val:()=>null,
     cell:p=>esc(MODEL_LABEL[p.model]||p.model)},
    {label:"Rating",best:"max",val:p=>Number(p.rating),
     cell:p=>`<span class="num">${ICON.star} ${esc(String(p.rating))}</span>`},
    {label:"Ratings behind it",best:null,val:()=>null,
     cell:p=>`<span class="num">${esc(String(p.reviews))}</span>`,
     note:"More ratings means firmer evidence, not a better program — no winner is marked."},
    {label:"Ages",best:null,val:()=>null,
     cell:p=>`<span class="num">${esc(String(p.minAge))}–${esc(String(p.maxAge))}</span>`},
    {label:"Skill level",best:null,val:()=>null,cell:p=>esc(p.skill)},
    {label:"Capacity",best:null,val:()=>null,
     cell:p=>{const left=Number(p.cap)-Number(p.enrolled);
       return `<span class="num">${esc(String(p.enrolled))} of ${esc(String(p.cap))} enrolled</span><br>`+
         (left>0?`<span class="pill good">${left} spot${left===1?"":"s"} open</span>`
                :`<span class="pill warn">Full</span>`);}},
    {label:"Distance",best:"min",val:p=>distanceOf(p),
     cell:p=>`<span class="num">${esc(miles(distanceOf(p)))}</span><br><span class="se-dim">from ${esc(ORIGIN.label)}</span>`},
    {label:"Cancellation policy",best:null,val:()=>null,
     cell:p=>esc(POLICY_LABEL[p.cancellationPolicy]||p.cancellationPolicy||"Not published")},
    {label:"Background check",best:null,val:()=>null,
     cell:p=>p.verified===true
       ? `<span class="pill gold">${ICON.shield} Cleared</span>`
       : `<span class="pill warn">${ICON.shield} Pending</span>`},
    {label:"Next available session",best:null,val:()=>null,
     cell:p=>{const n=nextSession(p.id);
       if(n.upcoming) return `<span class="num">${esc(fmtDate(n.slot.date))}</span><br><span class="se-dim">${esc(n.slot.startTime)} ${esc(n.slot.tz||"")}</span>`;
       return `<span class="se-dim">No upcoming session published</span>`+
         (n.slot?`<br><span class="num se-dim">last was ${esc(fmtDate(n.slot.date))}</span>`:"");}},
  ];
}
function bestSet(row,picks){
  if(!row.best) return null;
  const vals=picks.map(row.val).filter(Number.isFinite);
  if(vals.length<2) return null;
  const b=row.best==="min"?Math.min.apply(null,vals):Math.max.apply(null,vals);
  if(vals.every(v=>v===b)) return null;      /* no differentiation to report */
  return b;
}
function compareView(){
  ensure();
  const picks=compareIds().slice(0,CAP).map(prog).filter(Boolean);
  const head=`${nav()}<main class="shell" style="padding-bottom:72px">
    <div class="sec-head"><div>
      <h1>Compare</h1>
      <p class="se-lede" style="margin-top:6px">Up to ${CAP} programs, row by row, on the data each
        provider publishes. A row is only marked when "better" is a fact.</p>
    </div><button class="btn ghost sm" data-nav="explore">Back to Explore</button></div>`;

  if(!picks.length) return head+`<div class="empty">
      <h2>Nothing selected yet</h2>
      <p style="margin-top:8px">Use the Compare button on any program card to add it here. Three at a time.</p>
      <button class="btn" data-nav="explore" style="margin-top:20px">Browse programs</button>
    </div></main>`;

  const rows=compareRows(picks);
  const cols=picks.length;
  return head+`
    <div class="tblwrap se-cmpwrap">
      <table class="tbl se-cmp">
        <caption class="se-sr">Side-by-side comparison of ${cols} program${cols===1?"":"s"}</caption>
        <thead><tr>
          <th scope="col"><span class="se-sr">Attribute</span></th>
          ${picks.map(p=>`<th scope="col" class="se-col">
            <span class="pill" style="background:${sportColor(p.sport)}1A;color:${sportColor(p.sport)}">${sportGlyph(p.sport)} ${esc(p.sport)}</span>
            <b>${esc(p.title)}</b>
            <span class="se-dim">${esc(p.biz)}</span>
          </th>`).join("")}
        </tr></thead>
        <tbody>
          ${rows.map(r=>{
            const b=bestSet(r,picks);
            return `<tr>
              <th scope="row" class="se-rowlbl">${esc(r.label)}${
                r.note?`<span class="se-rownote">${esc(r.note)}</span>`:""}</th>
              ${picks.map(p=>{
                const v=r.val(p);
                const win=b!=null&&Number.isFinite(v)&&v===b;
                return `<td class="${win?"se-best":""}">${r.cell(p)}${
                  win?`<span class="se-bestmark">${r.best==="min"?(r.label==="Distance"?"Nearest":"Lowest"):"Highest"}</span>`:""}</td>`;
              }).join("")}
            </tr>`;
          }).join("")}
          <tr>
            <th scope="row" class="se-rowlbl">Actions</th>
            ${picks.map(p=>`<td>
              <button class="btn ghost sm" data-open="${esc(p.id)}">View</button>
              <button class="btn ghost sm" data-sedropcmp="${esc(p.id)}" style="margin-top:8px">Remove</button>
            </td>`).join("")}
          </tr>
        </tbody>
      </table>
    </div>
    ${cols<2?`<p class="se-hint" style="margin-top:14px">Add at least one more program to see a comparison.</p>`:""}
    <p class="se-hint" style="margin-top:16px;max-width:78ch">Distances are straight-line miles from
      ${esc(ORIGIN.label)}. Session dates are the ones the provider has published; where a listing has
      nothing on the books, that is what the row says rather than an estimate.</p>
  </main>`;
}

/* ═══════════════════ injected explore toolbar ═══════════════════ */
function toolbarHTML(){
  const a=adv(),n=activeCount(),list=saved(),cmp=compareIds().length;
  return `<div class="se-bar-in">
    <button type="button" class="btn ghost sm" data-sefilters="1" aria-haspopup="dialog">
      Filters${n?` <span class="se-badge num">${n}</span>`:""}</button>
    <span class="se-inline">
      <label class="se-lbl" for="seSort">Sort</label>
      <select id="seSort" class="se-select se-select-sm">
        ${Object.keys(SORT_LABEL).map(k=>`<option value="${k}"${a.sort===k?" selected":""}>${esc(SORT_LABEL[k])}</option>`).join("")}
      </select>
    </span>
    <button type="button" class="btn ghost sm" data-sesave="1">Save this search</button>
    ${cmp?`<button type="button" class="btn ghost sm" data-secompare="1">Compare <span class="se-badge num">${cmp}</span></button>
      <button type="button" class="x se-x" data-secmpclear="1" aria-label="Clear the compare selection">${ICON.x}</button>`:""}
    <span class="se-live num" id="seLive" role="status" aria-live="polite"></span>
  </div>
  ${list.length?`<div class="se-chips">
    <span class="eyebrow">Saved</span>
    ${list.map(s=>`<span class="se-chip">
      <button type="button" class="se-chip-b" data-seuse="${esc(s.id)}">${esc(s.name)} <i class="num">${s.count}</i></button>
      <button type="button" class="se-chip-x" data-sedrop="${esc(s.id)}" aria-label="Delete the saved search ${esc(s.name)}">${ICON.x}</button>
    </span>`).join("")}
  </div>`:""}`;
}

/* ═══════════════════ wire ═══════════════════ */
let lastModal=null;        /* modal type at the end of the previous render */
let returnFocus=null;      /* selector to hand focus back to when it closes */
let pendingFocus=null;     /* selector to focus once, after this render     */

const $=s=>Array.prototype.slice.call(document.querySelectorAll(s));
const mine=t=>t==="filters"||t==="savesearch";
const openModal=(type,from)=>{returnFocus=from||null;host().modal={type};render();};

/* ── explore toolbar ─────────────────────────────────────────────── */
function injectToolbar(){
  if(document.getElementById("seBar")) return document.getElementById("seBar");
  const anchor=document.querySelector('[data-filter="verified"]');
  if(!anchor||!anchor.parentElement||!anchor.parentElement.parentElement) return null;
  const row=anchor.parentElement;
  const bar=document.createElement("div");
  bar.id="seBar";
  bar.className="se-bar";
  bar.innerHTML=toolbarHTML();
  row.parentElement.insertBefore(bar,row.nextSibling);
  return bar;
}
function injectCompareButtons(grid){
  grid.querySelectorAll(".card").forEach(card=>{
    if(card.querySelector("[data-secmp]")) return;
    const open=card.querySelector("[data-open]");
    if(!open) return;
    const id=open.dataset.open,p=prog(id);
    if(!p) return;
    const on=compareIds().indexOf(id)>=0;
    const b=document.createElement("button");
    b.type="button";
    b.className="se-cmp"+(on?" on":"");
    b.setAttribute("data-secmp",id);
    b.setAttribute("aria-pressed",on?"true":"false");
    b.setAttribute("aria-label",`${on?"Remove":"Add"} ${p.title} ${on?"from":"to"} the comparison`);
    b.textContent=on?"In compare":"Compare";
    card.appendChild(b);
  });
}
/* Show / hide / reorder the host's own card nodes. Never re-creates them,
   so every binding the host attached in its wire() survives. */
function repaintGrid(bar){
  const main=bar.parentElement;
  const grid=main.querySelector(".grid");
  if(!grid) return {kept:0,base:0};
  /* T3/§5: cards carry no per-card Compare button — their actions are the
     whole-card link + View slots. (Compare feature dormant, not removed.) */
  // injectCompareButtons(grid);

  const cards=Array.prototype.slice.call(grid.querySelectorAll(".card"));
  const byId=new Map(),order=[];
  cards.forEach(c=>{
    const o=c.querySelector("[data-open]");
    if(o&&o.dataset.open&&!byId.has(o.dataset.open)){byId.set(o.dataset.open,c);order.push(o.dataset.open);}
  });
  const base=order.map(prog).filter(Boolean);
  const kept=applyAdvanced(base);
  const keepIds=new Set(kept.map(p=>p.id));

  byId.forEach((el,id)=>{el.style.display=keepIds.has(id)?"":"none";});
  kept.forEach(p=>{const el=byId.get(p.id);if(el) grid.appendChild(el);});

  /* empty state, ours, kept out of the grid so it never gets reordered */
  const old=document.getElementById("seEmpty");
  if(!kept.length&&base.length){
    if(!old){
      const d=document.createElement("div");
      d.id="seEmpty";
      d.className="empty";
      d.innerHTML=`<h3>No programs match those filters</h3>
        <p style="margin-top:6px">${esc(String(base.length))} program${base.length===1?"":"s"} match the sport and
          quick filters, but none clear the advanced filters on top.</p>
        <button type="button" class="btn ghost sm" data-seclearall="1" style="margin-top:18px">Clear advanced filters</button>`;
      grid.parentElement.insertBefore(d,grid.nextSibling);
    }
  } else if(old&&old.parentElement){ old.parentElement.removeChild(old); }

  /* keep the host's own "N of M programs" line truthful */
  if(activeCount()){
    const host_count=bar.previousElementSibling&&bar.previousElementSibling.querySelector("span.num");
    if(host_count) host_count.textContent=`${kept.length} of ${catalogue().length} programs`;
  }
  return {kept:kept.length,base:base.length};
}
function paintLive(counts){
  const el=document.getElementById("seLive");
  if(!el) return;
  const a=adv(),n=activeCount();
  /* T4 kind-band layout has no single .grid, so applyFilters returns 0/0;
     fall back to the catalogue total so the line stays truthful. */
  const base=counts.base||catalogue().length;
  const kept=counts.base?counts.kept:base;
  el.textContent=`${kept} of ${base} shown · sorted by ${SORT_LABEL[a.sort]||a.sort}`+
    (n?` · ${n} advanced filter${n===1?"":"s"}`:"");
}

/* ── filters-modal painting, in place (no render on drag or keystroke) ── */
function paintModal(){
  const a=adv(),{lo,hi}=priceBounds();
  const loEl=document.getElementById("sePriceLo");
  const hiEl=document.getElementById("sePriceHi");
  const fill=document.getElementById("sePriceFill");
  const val=document.getElementById("sePriceVal");
  if(loEl&&hiEl){
    const pmin=Number(loEl.value),pmax=Number(hiEl.value);
    loEl.setAttribute("aria-valuenow",String(pmin));
    hiEl.setAttribute("aria-valuenow",String(pmax));
    loEl.setAttribute("aria-valuetext",`Minimum ${money(pmin)}`);
    hiEl.setAttribute("aria-valuetext",`Maximum ${money(pmax)}`);
    if(fill){
      const span=hi-lo||1;
      fill.style.left=((pmin-lo)/span*100).toFixed(2)+"%";
      fill.style.right=((hi-pmax)/span*100).toFixed(2)+"%";
    }
    if(val) val.textContent=(a.priceMin==null&&a.priceMax==null)
      ? `Full catalogue range, ${money(lo)} to ${money(hi)}`
      : `${money(pmin)} to ${money(pmax)}`;
  }
  paintClears();
  const n=matchCount(),total=baseList().length;
  const c=document.getElementById("seCount");
  if(c) c.textContent=`${n} of ${total} program${total===1?"":"s"} match`;
  const ap=document.getElementById("seApply");
  if(ap) ap.textContent=n?`Show ${n} program${n===1?"":"s"}`:"Show results";
}
function paintClears(){
  const a=adv();
  const on={
    price:a.priceMin!=null||a.priceMax!=null,
    age:a.age!=null,
    skill:a.skill.length>0,
    models:a.models.length>0,
    distance:a.distance!=null,
    minRating:a.minRating!=null,
    availDays:a.availDays!=null,
    flags:a.bgOnly||a.openOnly,
  };
  $("[data-seclear]").forEach(b=>{
    const k=b.dataset.seclear;
    if(k in on) b.classList.toggle("hide",!on[k]);
  });
}
function clearGroup(k){
  const a=adv();
  if(k==="price"){a.priceMin=null;a.priceMax=null;}
  else if(k==="flags"){a.bgOnly=false;a.openOnly=false;}
  else if(k==="skill"||k==="models") a[k]=[];
  else a[k]=null;
}
function clearAll(){
  const a=adv(),sort=a.sort;
  Object.keys(DEFAULT_ADV).forEach(k=>{a[k]=clone(DEFAULT_ADV[k]);});
  a.sort=sort;                          /* sort is a view choice, not a filter */
}

/* ── focus trap ──────────────────────────────────────────────────── */
const FOCUSABLE='a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
function trapFocus(modal){
  modal.onkeydown=e=>{
    if(e.key!=="Tab") return;
    const els=Array.prototype.slice.call(modal.querySelectorAll(FOCUSABLE))
      .filter(el=>el.offsetWidth>0||el.offsetHeight>0||el===document.activeElement);
    if(!els.length) return;
    const first=els[0],last=els[els.length-1];
    if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
    else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
  };
}

function wire(){
  ensure();
  const h=host();
  const modalType=(h.modal&&h.modal.type)||null;

  /* ── explore toolbar + grid ── */
  const bar=injectToolbar();
  if(bar){
    const counts=repaintGrid(bar);
    paintLive(counts);

    const sort=document.getElementById("seSort");
    if(sort) sort.onchange=()=>{adv().sort=sort.value;pendingFocus="#seSort";render();};

    $("[data-sefilters]").forEach(b=>b.onclick=()=>openModal("filters","[data-sefilters]"));
    $("[data-sesave]").forEach(b=>b.onclick=()=>openModal("savesearch","[data-sesave]"));
    $("[data-secompare]").forEach(b=>b.onclick=()=>{h.route={name:"compare",arg:null};window.scrollTo(0,0);render();});
    $("[data-secmpclear]").forEach(b=>b.onclick=()=>{h.compareIds=[];render();toast("Compare cleared");});

    $("[data-secmp]").forEach(b=>b.onclick=()=>{
      const id=b.dataset.secmp,p=prog(id);
      const ids=compareIds();
      if(ids.indexOf(id)>=0){h.compareIds=ids.filter(x=>x!==id);}
      else if(ids.length>=CAP){toast(`Compare holds ${CAP} programs — remove one first`);return;}
      else h.compareIds=ids.concat([id]);
      pendingFocus=`[data-secmp="${id}"]`;
      render();
      if(p&&compareIds().indexOf(id)>=0) toast(`${p.title} added to compare`);
    });
  }

  /* ── saved searches (toolbar and modal share the hooks) ── */
  $("[data-seuse]").forEach(b=>b.onclick=()=>{
    const s=saved().find(x=>x.id===b.dataset.seuse);
    if(!s) return;
    const snap=s.snapshot||{};
    h.sport=snap.sport==null?null:snap.sport;
    h.query=snap.query||"";
    if(snap.filters) h.filters={maxPrice:snap.filters.maxPrice,verifiedOnly:!!snap.filters.verifiedOnly,model:snap.filters.model||null};
    h.adv=clone(Object.assign(clone(DEFAULT_ADV),snap.adv||{}));
    h.modal=null;
    h.route={name:"explore",arg:null};
    render();
    toast(`Applied "${s.name}"`);
  });
  $("[data-sedrop]").forEach(b=>b.onclick=()=>{
    const s=saved().find(x=>x.id===b.dataset.sedrop);
    h.savedSearches=saved().filter(x=>x.id!==b.dataset.sedrop);
    render();
    if(s) toast(`Deleted "${s.name}"`);
  });
  $("[data-sedropcmp]").forEach(b=>b.onclick=()=>{
    h.compareIds=compareIds().filter(x=>x!==b.dataset.sedropcmp);
    render();
  });

  /* ── clear buttons (a click, so a full render is fine) ── */
  $("[data-seclear]").forEach(b=>b.onclick=()=>{
    clearGroup(b.dataset.seclear);
    pendingFocus=modalType==="filters"?"#seApply":null;
    render();
  });
  $("[data-seclearall]").forEach(b=>b.onclick=()=>{
    clearAll();
    pendingFocus=modalType==="filters"?"[data-seclearall]":null;
    render();
    toast("Advanced filters cleared");
  });

  /* ── filters modal, repainted in place ── */
  if(modalType==="filters"){
    const a=adv(),{lo,hi}=priceBounds();
    const loEl=document.getElementById("sePriceLo");
    const hiEl=document.getElementById("sePriceHi");
    const slide=()=>{
      if(!loEl||!hiEl) return;
      let pmin=Number(loEl.value),pmax=Number(hiEl.value);
      if(pmin>pmax){ if(document.activeElement===loEl){pmax=pmin;hiEl.value=String(pmax);} else {pmin=pmax;loEl.value=String(pmin);} }
      a.priceMin=pmin<=lo?null:pmin;
      a.priceMax=pmax>=hi?null:pmax;
      paintModal();
    };
    if(loEl){loEl.oninput=slide;loEl.onchange=slide;}
    if(hiEl){hiEl.oninput=slide;hiEl.onchange=slide;}

    const age=document.getElementById("seAge");
    if(age) age.oninput=()=>{
      const v=age.value.trim();
      const n=Number(v);
      a.age=(v===""||!Number.isFinite(n))?null:Math.round(n);
      paintModal();
    };
    $("[data-seskill]").forEach(el=>el.onchange=()=>{
      const v=el.dataset.seskill;
      a.skill=el.checked?a.skill.concat([v]).filter((x,i,arr)=>arr.indexOf(x)===i):a.skill.filter(x=>x!==v);
      paintModal();
    });
    $("[data-semodel]").forEach(el=>el.onchange=()=>{
      const v=el.dataset.semodel;
      a.models=el.checked?a.models.concat([v]).filter((x,i,arr)=>arr.indexOf(x)===i):a.models.filter(x=>x!==v);
      paintModal();
    });
    const dist=document.getElementById("seDistance");
    if(dist) dist.onchange=()=>{a.distance=dist.value===""?null:Number(dist.value);paintModal();};
    $("[data-serating]").forEach(el=>el.onchange=()=>{
      a.minRating=el.value===""?null:Number(el.value);paintModal();});
    $("[data-seavail]").forEach(el=>el.onchange=()=>{
      a.availDays=el.value===""?null:Number(el.value);paintModal();});
    $("[data-sebg]").forEach(el=>el.onchange=()=>{a.bgOnly=el.checked;paintModal();});
    $("[data-seopen]").forEach(el=>el.onchange=()=>{a.openOnly=el.checked;paintModal();});
    $("[data-seapply]").forEach(b=>b.onclick=()=>{h.modal=null;render();});
    paintModal();
  }

  /* ── save-search form ── */
  const sf=document.getElementById("seSaveForm");
  if(sf) sf.onsubmit=e=>{
    e.preventDefault();
    const err=document.getElementById("seSaveErr");
    const show=m=>{if(err){err.textContent=m;err.classList.remove("hide");}};
    const name=String((new FormData(sf)).get("name")||"").trim();
    if(name.length<2) return show("Give the search a name you'll recognise later.");
    if(saved().some(s=>s.name.toLowerCase()===name.toLowerCase()))
      return show("You already have a saved search with that name.");
    const a=adv();
    h.savedSearches=[{
      id:"ss_"+Date.now(),name,at:TODAY,
      time:new Date().toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"}),
      count:matchCount(),
      snapshot:{
        sport:h.sport||null,
        query:h.query||"",
        filters:h.filters?{maxPrice:h.filters.maxPrice,verifiedOnly:!!h.filters.verifiedOnly,model:h.filters.model||null}:null,
        adv:clone(a),
      },
    }].concat(saved());
    h.modal=null;
    render();
    toast(`Saved "${name}"`);
  };

  /* ── modal focus: trap on open, hand it back on close ── */
  const scrimModal=document.querySelector(".scrim .modal");
  if(mine(modalType)&&scrimModal){
    trapFocus(scrimModal);
    if(!mine(lastModal)){                              /* just opened */
      const first=scrimModal.querySelector(FOCUSABLE);
      if(first) first.focus();
    }
  }
  if(mine(lastModal)&&!mine(modalType)&&returnFocus){
    const back=document.querySelector(returnFocus);
    if(back) back.focus();
    returnFocus=null;
  }
  if(pendingFocus){
    const el=document.querySelector(pendingFocus);
    if(el) el.focus();
    pendingFocus=null;
  }
  lastModal=modalType;
}

/* ═══════════════════ css ═══════════════════ */
const CSS=`
/* ── MOD_SEARCH ──────────────────────────────────────────────────── */
.se-lede{color:var(--muted);font-size:var(--text-base);line-height:1.55;max-width:72ch}
.se-hint{color:var(--faint);font-size:var(--text-sm);line-height:1.5;margin-top:9px;max-width:70ch}
.se-dim{color:var(--muted);font-size:var(--text-sm)}
.se-sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}

/* explore toolbar (injected after the host's quick-filter row) */
.se-bar{padding:14px 0 0;display:flex;flex-direction:column;gap:11px}
.se-bar-in{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.se-badge{display:inline-grid;place-items:center;min-width:18px;height:18px;padding:0 5px;margin-left:2px;
  border-radius:999px;background:var(--slate-tint);color:var(--slate);font-size:var(--text-xs);font-weight:700}
.se-live{color:var(--muted);font-size:var(--text-sm);margin-left:auto;text-align:right}
.se-inline{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
.se-lbl{font-size:var(--text-xs);font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.se-select{padding:9px 12px;border:1px solid var(--rule-strong);border-radius:var(--r-s);
  background:var(--paper);color:var(--ink);font:inherit;font-size:var(--text-base)}
.se-select-sm{font-size:var(--text-sm);padding:8px 10px}
.se-num{width:110px;padding:9px 12px;border:1px solid var(--rule-strong);border-radius:var(--r-s);
  background:var(--paper);color:var(--ink);font:inherit;font-size:var(--text-base);font-variant-numeric:tabular-nums}
.se-x{width:30px;height:30px;border:1px solid var(--rule);flex:0 0 auto}

/* saved-search chips */
.se-chips{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.se-chip{display:inline-flex;align-items:center;border:1px solid var(--rule-strong);border-radius:999px;overflow:hidden}
.se-chip-b{padding:6px 4px 6px 13px;font-size:var(--text-sm);font-weight:700;color:var(--ink-2)}
.se-chip-b:hover{color:var(--slate)}
.se-chip-b i{font-style:normal;color:var(--faint);font-size:var(--text-sm);margin-left:4px}
.se-chip-x{display:grid;place-items:center;width:26px;height:26px;margin-right:3px;border-radius:999px;color:var(--faint)}
.se-chip-x:hover{background:var(--raise2);color:var(--danger)}
.se-chip-x svg{width:12px;height:12px}

/* compare toggle on a card */
.se-cmp{align-self:flex-start;margin-top:2px;padding:5px 11px;border:1px solid var(--rule-strong);
  border-radius:999px;font-size:var(--text-sm);font-weight:700;color:var(--muted);transition:.14s}
.se-cmp:hover{border-color:var(--ink-2);color:var(--ink)}
.se-cmp.on{border-color:var(--slate);background:var(--slate-tint);color:var(--slate)}

/* filter modal */
.se-fs{border:0;padding:18px 0 0;margin:0;position:relative;border-top:1px solid var(--rule)}
.se-fs:first-of-type{border-top:0;padding-top:14px}
.se-fs legend{font-size:var(--text-xs);font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:0}
.se-clear{position:absolute;right:0;top:14px;font-size:var(--text-sm);font-weight:700;color:var(--slate);
  padding:3px 8px;border-radius:var(--r-s)}
.se-clear:hover{background:var(--slate-tint)}
.se-val{margin-top:4px;font-size:var(--text-base);font-weight:700;color:var(--ink)}
.se-opts{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:8px;margin-top:12px}
.se-opts-1{grid-template-columns:1fr}
.se-opt{display:flex;align-items:center;gap:9px;padding:10px 12px;border:1px solid var(--rule);
  border-radius:var(--r-m);font-size:var(--text-base);color:var(--ink-2);cursor:pointer;transition:.14s}
.se-opt:hover{border-color:var(--rule-strong);background:var(--raise)}
.se-opt input{width:16px;height:16px;flex:0 0 auto;accent-color:var(--slate);margin:0}
.se-opt span{min-width:0}
.se-opt i{font-style:normal;margin-left:auto;font-size:var(--text-xs);color:var(--faint);white-space:nowrap}
.se-opt:has(input:checked){border-color:var(--slate);background:var(--slate-tint)}

/* dual-handle price range */
.se-dual{position:relative;height:34px;margin-top:14px}
.se-track{position:absolute;left:0;right:0;top:15px;height:4px;border-radius:999px;background:var(--raise2)}
.se-fill{position:absolute;top:0;bottom:0;border-radius:999px;background:var(--slate)}
.se-range{position:absolute;left:0;top:0;width:100%;height:34px;margin:0;background:none;
  pointer-events:none;-webkit-appearance:none;appearance:none}
.se-range:focus{outline:none}
.se-range::-webkit-slider-thumb{-webkit-appearance:none;pointer-events:auto;width:20px;height:20px;
  border-radius:999px;background:var(--paper);border:2px solid var(--slate);cursor:pointer}
.se-range::-moz-range-thumb{pointer-events:auto;width:18px;height:18px;border-radius:999px;
  background:var(--paper);border:2px solid var(--slate);cursor:pointer}
.se-range:focus-visible::-webkit-slider-thumb{outline:2px solid var(--slate);outline-offset:2px}
.se-range:focus-visible::-moz-range-thumb{outline:2px solid var(--slate);outline-offset:2px}

.se-foot{margin-top:22px;padding-top:16px;border-top:1px solid var(--rule);
  display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.se-footbtns{display:flex;gap:10px;margin-left:auto;flex-wrap:wrap}
.se-count{color:var(--ink-2);font-size:var(--text-base);font-weight:700}
.se-sum{margin-top:18px;padding:16px;border:1px solid var(--rule);border-radius:var(--r-m);background:var(--raise)}
.se-dl{margin:10px 0 0}
.se-dl dt{color:var(--muted);font-size:var(--text-sm)}
.se-dl dd{margin:0;color:var(--ink-2);font-size:var(--text-sm);text-align:right}
.se-sum .linerow{padding:6px 0}

/* compare table */
.se-cmpwrap{border:1px solid var(--rule);border-radius:var(--r-l);padding:6px 14px 14px;margin-top:6px}
/* Scoped to the wrapper: se-cmp names TWO different things — the compare
   table here, and the per-card compare button built at :611 (styled as a
   button at :940). Unscoped, min-width:640px landed on all 30 card buttons
   and rendered them as blank 640px capsules bleeding out of every card. */
.se-cmpwrap .se-cmp{min-width:640px}
.se-cmpwrap .se-cmp th,.se-cmpwrap .se-cmp td{vertical-align:top}
.se-col{min-width:190px}
.se-col b{display:block;font-size:var(--text-base);letter-spacing:-.015em;margin-top:7px;color:var(--ink);
  text-transform:none;font-weight:700}
.se-col .se-dim{display:block;margin-top:2px}
.se-rowlbl{white-space:normal;min-width:150px;padding:13px 12px !important;border-top:1px solid var(--rule);
  color:var(--muted);font-size:var(--text-xs);letter-spacing:.08em;text-transform:uppercase;font-weight:700}
.se-rownote{display:block;margin-top:6px;font-size:var(--text-xs);letter-spacing:0;text-transform:none;
  font-weight:500;color:var(--faint);line-height:1.45}
.se-best{background:var(--good-tint);border-radius:var(--r-s)}
.se-bestmark{display:inline-block;margin-top:6px;padding:2px 8px;border-radius:999px;
  background:var(--good);color:var(--paper);font-size:var(--text-xs);font-weight:700;letter-spacing:.02em}

@media(max-width:760px){
  .se-live{margin-left:0;text-align:left;width:100%}
  .se-foot{align-items:stretch}
  .se-footbtns{margin-left:0;width:100%}
  .se-footbtns .btn{flex:1}
  .se-opts{grid-template-columns:1fr}
}
`;

/* ═══════════════════ export ═══════════════════ */
window.MOD_SEARCH={
  css:CSS,
  views:{compare:compareView},
  modals:{filters:filtersModal,savesearch:saveSearchModal},
  wire:wire,
  state:{adv:clone(DEFAULT_ADV),savedSearches:[],compareIds:[]},
  applyAdvanced:applyAdvanced,
};

})();
