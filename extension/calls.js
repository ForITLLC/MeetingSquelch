// calls.js: runs in Meet, Teams, Zoom and Webex pages. It finds the page's own mic, camera, share
// and leave buttons by their labels, tells the background what they show while a call is up, and
// presses one when the Mac app asks. It reads nothing else from the page.
(() => {
  // Each control is a list of [label pattern, state]. Labels are lowercased, with runs of spaces
  // collapsed. mic: true = muted. camera: true = on. share: true = presenting. A page is in a call
  // while its leave button is there. Patterns are anchored so a participant's "Mute <name>" or a
  // "Mute all" button never counts as your own mic.
  const tail = "( \\(.*\\))?$"; // a shortcut hint such as "(⌘ + d)" may follow
  const exact = (s) => new RegExp(`^(${s})${tail}`);
  const SITES = [
    {
      site: "meet",
      host: /^meet\.google\.com$/,
      mic: [[/^turn on microphone/, true], [/^turn off microphone/, false]],
      camera: [[/^turn off camera/, true], [/^turn on camera/, false]],
      share: [[/^stop presenting/, true], [/^(share screen|present now)/, false]],
      leave: [[/^leave call/, null]],
      mutedAttr: true, // Meet's mic and camera buttons also carry data-is-muted
    },
    {
      site: "teams",
      host: /^teams\.(microsoft\.com|live\.com|cloud\.microsoft)$/,
      ids: { mic: "microphone-button", camera: "video-button", share: "screenshare-button", leave: "hangup-button" },
      mic: [[exact("unmute( mic)?"), true], [exact("mute( mic)?"), false]],
      camera: [[/^turn camera off/, true], [/^turn camera on/, false]],
      share: [[/^stop (sharing|presenting)/, true], [exact("share( content)?"), false]],
      leave: [[exact("leave|hang up"), null]],
    },
    {
      site: "zoom",
      host: /(^|\.)zoom\.us$/,
      mic: [[/^unmute my microphone/, true], [/^mute my microphone/, false], [exact("unmute"), true], [exact("mute"), false]],
      camera: [[/^stop (sending )?my video|^stop video/, true], [/^start (sending )?my video|^start video/, false]],
      share: [[/^stop share/, true], [exact("share( screen)?"), false]],
      leave: [[exact("leave|end"), null]],
      confirm: exact("leave meeting"), // never "end meeting for all"
    },
    {
      site: "webex",
      host: /(^|\.)webex\.com$/,
      mic: [[exact("unmute( me)?"), true], [exact("mute( me)?"), false]],
      camera: [[/^stop video/, true], [/^start video/, false]],
      share: [[/^stop shar/, true], [exact("share( content)?"), false]],
      leave: [[exact("leave( meeting)?"), null]],
      confirm: exact("leave meeting"),
    },
  ];
  const S = SITES.find((s) => s.host.test(location.hostname));
  if (!S) return;

  const KINDS = ["mic", "camera", "share", "leave"];
  const cache = {};
  const scanned = {};

  function label(el) {
    const t = el.getAttribute("aria-label") || el.getAttribute("data-tooltip") || el.title || el.textContent || "";
    return t.toLowerCase().replace(/\s+/g, " ").trim();
  }

  function rule(el, rules) {
    const l = label(el);
    return rules.find(([re]) => re.test(l));
  }

  function find(kind) {
    const id = S.ids && S.ids[kind];
    if (id) {
      const el = document.getElementById(id);
      if (el && rule(el, S[kind])) return el;
    }
    for (const el of document.querySelectorAll('button, [role="button"]')) if (rule(el, S[kind])) return el;
    return null;
  }

  // The control and what it shows. A cached button is re-checked each time; a missing one is
  // searched for at most every 2 s, since meeting pages are large.
  function read(kind) {
    let el = cache[kind];
    let r = el && el.isConnected && rule(el, S[kind]);
    if (!r) {
      const now = Date.now();
      if (el || now - (scanned[kind] || 0) > 2000) {
        scanned[kind] = now;
        el = cache[kind] = find(kind);
        r = el && rule(el, S[kind]);
      }
    }
    if (!r) return null;
    let on = r[1];
    if (S.mutedAttr && (kind === "mic" || kind === "camera") && el.hasAttribute("data-is-muted")) {
      const muted = el.getAttribute("data-is-muted") === "true";
      on = kind === "mic" ? muted : !muted;
    }
    return { el, on };
  }

  function state() {
    if (!read("leave")) return null;
    const v = (k) => { const c = read(k); return c ? c.on : null; };
    return { site: S.site, mic: v("mic"), camera: v("camera"), share: v("share") };
  }

  let last = "";
  let sentAt = 0;
  let inCall = false;
  let timer = null;

  function send(m) {
    try {
      chrome.runtime.sendMessage(m).catch(() => {});
    } catch {
      clearInterval(timer); // the extension was reloaded or removed; this copy is orphaned
    }
  }

  function tick() {
    const st = state();
    if (!st) {
      if (inCall) send({ t: "end" });
      inCall = false;
      last = "";
      return;
    }
    const key = JSON.stringify(st);
    const now = Date.now();
    if (key !== last || now - sentAt > 5000) { // every 5 s too, so the app knows the tab is alive
      send({ t: "call", ...st });
      sentAt = now;
      last = key;
    }
    inCall = true;
  }

  function press(el) {
    el.click();
  }

  // Zoom and Webex ask before leaving: press "Leave meeting", never "End meeting for all".
  function confirmLeave() {
    const until = Date.now() + 1500;
    const look = () => {
      for (const el of document.querySelectorAll('button, [role="button"]')) {
        if (S.confirm.test(label(el))) return press(el);
      }
      if (Date.now() < until) setTimeout(look, 100);
    };
    setTimeout(look, 100);
  }

  chrome.runtime.onMessage.addListener((m) => {
    if (!m || m.t !== "do" || !KINDS.includes(m.what)) return;
    const c = read(m.what);
    if (!c) return;
    press(c.el);
    if (m.what === "leave" && S.confirm) confirmLeave();
    for (const ms of [80, 250, 600]) setTimeout(tick, ms); // report the new state quickly
  });

  addEventListener("pagehide", () => { if (inCall) send({ t: "end" }); });
  timer = setInterval(tick, 500);
  tick();
})();
