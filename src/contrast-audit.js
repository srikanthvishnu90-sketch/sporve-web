/* WCAG 2.1 contrast audit for whatever is currently rendered in #app.
 *
 * Run via `browse eval src/contrast-audit.js` after setting up state. Returns
 * JSON: {checked, failures, list}.
 *
 * Why this exists: smoke.sh's other checks assert on structure — a class is
 * present, a size is on the scale. None of them can tell whether text is
 * actually readable, and the repo has shipped both near-black-on-black and
 * near-white-on-white. Those are computed-style defects; only a real browser
 * measuring real pixels catches them.
 *
 * The load-bearing detail is alpha compositing. Sport washes are drawn at 8-10%
 * over a surface, so reading backgroundColor off the nearest ancestor and
 * treating it as opaque compares a colour against itself and scores a
 * meaningless 1.00. Every translucent layer is flattened down to the first
 * opaque ancestor before the ratio is taken.
 */
(() => {
  const parse = (c) => {
    const m = (c || "").match(/[\d.]+/g);
    if (!m) return null;
    return { r: +m[0], g: +m[1], b: +m[2], a: m.length > 3 ? +m[3] : 1 };
  };
  const over = (fg, bg) => ({
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a),
    a: 1,
  });
  const lum = (c) => {
    const a = [c.r, c.g, c.b].map((v) => {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  };
  const bgOf = (el) => {
    const stack = [];
    let n = el;
    while (n && n !== document.documentElement) {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c && c.a > 0) {
        stack.push(c);
        if (c.a === 1) break;
      }
      n = n.parentElement;
    }
    let base =
      stack.length && stack[stack.length - 1].a === 1
        ? stack.pop()
        : { r: 255, g: 255, b: 255, a: 1 };
    while (stack.length) base = over(stack.pop(), base);
    return base;
  };

  const bad = [];
  let checked = 0;
  document.querySelectorAll("#app *").forEach((el) => {
    /* Own text nodes only — otherwise a wrapper is charged for its children's
       text and every failure is reported once per ancestor. */
    const t = Array.from(el.childNodes)
      .filter((n) => n.nodeType === 3 && n.textContent.trim())
      .map((n) => n.textContent.trim())
      .join(" ");
    if (!t) return;
    const cs = getComputedStyle(el);
    /* getComputedStyle reports the element's OWN display, so a child of a
       display:none ancestor still reads "block" and would be audited despite
       never being painted — a source of false failures. getClientRects() is the
       reliable test: empty means the box is not laid out for any reason,
       including a hidden ancestor. It is used in preference to offsetParent,
       which is null for position:fixed elements and would skip the command bar,
       the exact surface a contrast bug was just found on. */
    if (el.getClientRects().length === 0) return;
    if (cs.visibility === "hidden" || cs.opacity === "0") return;
    const bg = bgOf(el);
    const fgRaw = parse(cs.color);
    if (!fgRaw) return;
    const fg = fgRaw.a < 1 ? over(fgRaw, bg) : fgRaw;
    checked++;
    const L1 = lum(fg);
    const L2 = lum(bg);
    const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
    const sz = parseFloat(cs.fontSize);
    const bold = parseInt(cs.fontWeight) >= 700;
    /* WCAG AA: 3.0 for large text (>=24px, or >=18.66px bold), else 4.5. */
    const need = sz >= 24 || (sz >= 18.66 && bold) ? 3 : 4.5;
    if (ratio < need) {
      bad.push(
        `${el.tagName.toLowerCase()}${el.className ? "." + String(el.className).split(" ")[0] : ""} | ` +
          `${cs.color} on rgb(${Math.round(bg.r)},${Math.round(bg.g)},${Math.round(bg.b)}) | ` +
          `${ratio.toFixed(2)} < ${need}`
      );
    }
  });

  return JSON.stringify({
    checked,
    failures: bad.length,
    list: Array.from(new Set(bad)).slice(0, 10),
  });
})()
