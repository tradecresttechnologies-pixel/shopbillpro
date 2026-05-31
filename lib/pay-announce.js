/* ============================================================================
 * lib/pay-announce.js  —  ShopBill Pro v9 "soundbox" announcer
 * Plays a chime + a spoken amount built by CONCATENATING pre-recorded clips
 * (same technique as Paytm/PhonePe soundboxes). Pure client, no dependencies.
 *
 * Clips live at:  /audio/pay/<lang>/<token>.mp3   (see audio/pay/MANIFEST.md)
 * Default lang "en"; pass "hi" for Hindi.
 *
 * window.SBPAnnounce.announce(rupees, lang?)   ->  "₹500 received" out loud
 * window.SBPAnnounce.chime()                   ->  just the alert chime
 * ========================================================================== */
(function () {
  const BASE = "/audio/pay";
  let ctx = null;
  const cache = new Map(); // url -> AudioBuffer

  function audio() {
    if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (ctx.state === "suspended") ctx.resume();
    return ctx;
  }

  async function buf(url) {
    if (cache.has(url)) return cache.get(url);
    const ab = await fetch(url).then((r) => r.arrayBuffer());
    const decoded = await audio().decodeAudioData(ab);
    cache.set(url, decoded);
    return decoded;
  }

  // Synthesized two-tone chime (no asset needed)
  function chime() {
    const a = audio(), t = a.currentTime;
    [880, 1320].forEach((f, i) => {
      const o = a.createOscillator(), g = a.createGain();
      o.frequency.value = f; o.type = "sine";
      g.gain.setValueAtTime(0.0001, t + i * 0.16);
      g.gain.exponentialRampToValueAtTime(0.5, t + i * 0.16 + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.16 + 0.18);
      o.connect(g); g.connect(a.destination);
      o.start(t + i * 0.16); o.stop(t + i * 0.16 + 0.2);
    });
  }

  // Indian-system integer -> token list matching clip filenames.
  // Tokens: 0-9, ten..nineteen, twenty..ninety, hundred, thousand, lakh, crore,
  //         rupees, received   (see MANIFEST.md)
  const ONES = ["zero","one","two","three","four","five","six","seven","eight","nine"];
  const TEENS = ["ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen","eighteen","nineteen"];
  const TENS = ["","","twenty","thirty","forty","fifty","sixty","seventy","eighty","ninety"];

  function twoDigits(n) {            // 0..99
    if (n === 0) return [];
    if (n < 10) return [ONES[n]];
    if (n < 20) return [TEENS[n - 10]];
    const t = Math.floor(n / 10), o = n % 10;
    return o === 0 ? [TENS[t]] : [TENS[t], ONES[o]];
  }
  function threeDigits(n) {          // 0..999
    const h = Math.floor(n / 100), r = n % 100;
    const out = [];
    if (h) out.push(ONES[h], "hundred");
    out.push(...twoDigits(r));
    return out;
  }

  function amountToTokens(rupees) {
    rupees = Math.max(0, Math.floor(rupees));
    if (rupees === 0) return ["zero", "rupees", "received"];
    const out = [];
    const crore = Math.floor(rupees / 10000000); rupees %= 10000000;
    const lakh  = Math.floor(rupees / 100000);   rupees %= 100000;
    const thou  = Math.floor(rupees / 1000);     rupees %= 1000;
    if (crore) { out.push(...threeDigits(crore), "crore"); }
    if (lakh)  { out.push(...twoDigits(lakh),  "lakh"); }   // lakh group is 2-digit
    if (thou)  { out.push(...threeDigits(thou), "thousand"); }
    if (rupees) { out.push(...threeDigits(rupees)); }
    out.push("rupees", "received");
    return out;
  }

  async function announce(rupees, lang = "en") {
    try {
      chime();
      const tokens = amountToTokens(Number(rupees) || 0);
      const a = audio();
      // schedule clips back-to-back after the chime (~0.5s)
      let when = a.currentTime + 0.5;
      for (const tk of tokens) {
        let b;
        try { b = await buf(`${BASE}/${lang}/${tk}.mp3`); }
        catch (_) { continue; }            // missing clip => skip gracefully
        const src = a.createBufferSource();
        src.buffer = b; src.connect(a.destination);
        src.start(when);
        when += b.duration;
      }
    } catch (e) {
      // Audio blocked (no user gesture yet) — caller should also show a toast.
      console.warn("[SBPAnnounce] could not play:", e);
    }
  }

  // Must be called once from a user gesture (e.g. login tap) to unlock audio.
  function unlock() { try { audio(); } catch (_) {} }

  window.SBPAnnounce = { announce, chime, unlock, amountToTokens };
})();
