// extension-harness.js: runs the extension's real sw.js and calls.js in Node against the real Squelch app,
// with fake Meet / Teams / Zoom pages and fake chrome.* APIs. Run on a Mac where Squelch is running:
//   node extension-harness.js <extension dir>   (exit 2 = a call or recording is live; nothing pressed)
// It connects as the extension the app lets in: ForIT's ID by default (ForIT's key; the app pins it), or
// SQUELCH_EXTENSION_ID=<id> for an extension packed with another key and named in the app's extensionIDs default.
const vm = require("vm");
const fs = require("fs");
const { execSync } = require("child_process");
const EXT = process.argv[2];
const PORT = 47213;
const EXT_ID = process.env.SQUELCH_EXTENSION_ID || "hnaihkcljcmkkkoblpgffnkdneaneama";
if (!/^[a-p]{32}$/.test(EXT_ID)) { console.log(`SQUELCH_EXTENSION_ID is not an extension ID: ${EXT_ID}`); process.exit(64); }
const ORIGIN = `chrome-extension://${EXT_ID}`;
const STATUS = `${process.env.HOME}/Library/Application Support/Squelch/status.json`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? "  " + detail : ""}`); };
const status = () => JSON.parse(fs.readFileSync(STATUS, "utf8"));
async function until(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { const v = fn(); if (v) return v; } catch {} await sleep(100); }
  return null;
}
const url = (u) => execSync(`open -g '${u}'`);

// --- a tiny DOM: just what calls.js touches ---
const clicks = [];
class El {
  constructor(label, attrs = {}, onclick = null) { this.attrs = { "aria-label": label, ...attrs }; this.textContent = ""; this.title = ""; this.isConnected = true; this.onclick = onclick; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  hasAttribute(k) { return k in this.attrs; }
  set(k, v) { this.attrs[k] = String(v); }
  click() { clicks.push(this.attrs["aria-label"]); if (this.onclick) this.onclick(this); }
}
function toggler(a, b, attr) { // label a <-> b on click; attr flips with it
  return (el) => { const on = el.attrs["aria-label"] === a; el.set("aria-label", on ? b : a); if (attr) el.set(attr, on ? attr === "data-is-muted" ? "true" : "x" : "false"); };
}

// --- fake chrome: one background, several tabs ---
const swListeners = [];
const tabListeners = {};
const removed = [];
const log = [];
const manifest = JSON.parse(fs.readFileSync(`${EXT}/manifest.json`, "utf8"));
const swChrome = {
  runtime: { id: "ext", getManifest: () => manifest, onMessage: { addListener: (f) => swListeners.push(f) } },
  tabs: {
    sendMessage: (tab, msg) => { (tabListeners[tab] || []).forEach((f) => f(msg, { id: "ext" })); return Promise.resolve(); },
    update: (tab, p) => { log.push(`tabs.update ${tab} ${JSON.stringify(p)}`); return Promise.resolve(); },
    onRemoved: { addListener: (f) => removed.push(f) },
  },
  windows: { update: (w, p) => { log.push(`windows.update ${w} ${JSON.stringify(p)}`); return Promise.resolve(); } },
};
class ExtWS extends WebSocket { constructor(u) { super(u, { headers: { origin: ORIGIN } }); } }
const timers = { setTimeout, clearTimeout, setInterval, clearInterval, console };
vm.runInNewContext(fs.readFileSync(`${EXT}/sw.js`, "utf8"), { ...timers, chrome: swChrome, WebSocket: ExtWS });

const pageTimers = [];
function openTab(tab, host, els) {
  const ctx = {
    console, setTimeout, clearTimeout,
    setInterval: (f, ms) => { const t = setInterval(f, ms); pageTimers.push(t); return t; }, clearInterval,
    location: { hostname: host },
    document: {
      querySelectorAll: () => els.filter((e) => e.isConnected),
      getElementById: (id) => els.find((e) => e.attrs.id === id && e.isConnected) || null,
    },
    addEventListener: () => {},
    chrome: {
      runtime: {
        sendMessage: (m) => { swListeners.forEach((f) => f(m, { id: "ext", tab: { id: tab, windowId: 100 + tab }, frameId: 0 })); return Promise.resolve(); },
        onMessage: { addListener: (f) => (tabListeners[tab] ||= []).push(f) },
      },
    },
  };
  vm.runInNewContext(fs.readFileSync(`${EXT}/calls.js`, "utf8"), ctx);
}
const hangUp = (els) => () => els.forEach((e) => (e.isConnected = false));

async function rawSocket(origin, hello) { // for the refusal checks
  return new Promise((res) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/`, origin ? { headers: { origin } } : undefined);
    ws.onopen = () => { if (hello) ws.send(JSON.stringify(hello)); setTimeout(() => res(ws.readyState === 1 ? "open" : "closed"), 600); };
    ws.onclose = () => res("closed");
    ws.onerror = () => res("refused");
  });
}

(async () => {
  const s0 = status();
  if (s0.call || (s0.recording || []).some((r) => r !== "com.rogueamoeba.arkaudiod")) { console.log("ABORT: a call or recording is live", s0.call, s0.recording); process.exit(2); }
  check("app listening on the new port", s0.web && s0.web.listening === true && s0.web.port === PORT, JSON.stringify(s0.web));

  check("web page origin refused", (await rawSocket("https://example.com")) !== "open");
  check("no origin refused", (await rawSocket(null)) !== "open");
  check("wrong protocol hello closed", (await rawSocket(ORIGIN, { t: "hello", proto: "other", v: 1 })) !== "open");
  if ((s0.web.pinned || []).length) check("other extension refused (ID pinned)", (await rawSocket("chrome-extension://egphpgddoenbpakmaojmnjpjoflmknjk")) !== "open");

  // --- Meet ---
  const meet = [];
  meet.push(new El("Mute Alice"), new El("Turn off microphone (⌘ + d)", { "data-is-muted": "false" }, toggler("Turn off microphone (⌘ + d)", "Turn on microphone (⌘ + d)", "data-is-muted")));
  meet.push(new El("Turn off camera (⌘ + e)", { "data-is-muted": "false" }, toggler("Turn off camera (⌘ + e)", "Turn on camera (⌘ + e)", "data-is-muted")));
  meet.push(new El("Share screen", {}, toggler("Share screen", "Stop presenting")));
  meet.push(new El("Leave call", {}, hangUp(meet)));
  openTab(1, "meet.google.com", meet);
  let st = await until(() => { const s = status(); return s.call === "Meet" && s; });
  check("Meet call seen by the app", !!st, st ? `call=${JSON.stringify(st.call)} web=${JSON.stringify(st.web)}` : JSON.stringify(status().web));

  url("squelch://toggle");
  st = await until(() => { const s = status(); return s.lastPress && s.lastPress.route === "extension" && s.lastPress.result === "muted" && s; });
  check("toggle mutes the Meet tab", !!st && meet[1].attrs["data-is-muted"] === "true", st ? JSON.stringify(st.lastPress) : `clicks=${clicks}`);
  check("decoy 'Mute Alice' never pressed", !clicks.includes("Mute Alice"));
  url("squelch://toggle");
  st = await until(() => { const s = status(); return s.lastPress && s.lastPress.route === "extension" && s.lastPress.result === "live" && s; });
  check("toggle unmutes it again", !!st && meet[1].attrs["data-is-muted"] === "false", st ? JSON.stringify(st.lastPress) : "");

  execSync("defaults write io.forit.squelch testURLs -bool true");
  try {
    url("squelch://camera");
    await until(() => meet[2].attrs["data-is-muted"] === "true");
    check("camera press turns the Meet camera off", meet[2].attrs["data-is-muted"] === "true");
    st = await until(() => { const s = status(); return /camera off/.test(s.bar || "") && s; });
    check("menu bar strip shows camera off", !!st, st ? st.bar : status().bar);
    url("squelch://share");
    await until(() => meet[3].attrs["aria-label"] === "Stop presenting");
    check("share press starts presenting", meet[3].attrs["aria-label"] === "Stop presenting");
    url("squelch://front");
    await until(() => log.length >= 2);
    check("front raises the tab and window", log.some((l) => l.startsWith("tabs.update 1")) && log.some((l) => l.startsWith("windows.update 101")), log.join(" | "));
    url("squelch://leave");
    st = await until(() => { const s = status(); return !s.call && meet[4].isConnected === false && s; }, 5000);
    check("leave hangs up and the app sees the call end", !!st, `clicks=${clicks.slice(-2)} call=${JSON.stringify(status().call)}`);

    // --- Teams web: buttons by id, decoys around them ---
    const teams = [];
    teams.push(new El("Mute all"), new El("Mute Alice"));
    teams.push(new El("Mute mic (⌘+Shift+M)", { id: "microphone-button" }, toggler("Mute mic (⌘+Shift+M)", "Unmute mic (⌘+Shift+M)")));
    teams.push(new El("Leave (⌘+Shift+H)", { id: "hangup-button" }, hangUp(teams)));
    openTab(2, "teams.microsoft.com", teams);
    st = await until(() => { const s = status(); return s.call === "Teams web" && s; });
    check("Teams web call seen", !!st, st ? JSON.stringify(st.call) : "");
    url("squelch://toggle");
    st = await until(() => { const s = status(); return s.lastPress && s.lastPress.app === "Teams web" && s.lastPress.result === "muted" && s; });
    check("toggle mutes Teams web through #microphone-button", !!st && teams[2].attrs["aria-label"].startsWith("Unmute"), st ? JSON.stringify(st.lastPress) : "");
    check("Teams decoys never pressed", !clicks.includes("Mute all") && !clicks.includes("Mute Alice"));
    url("squelch://leave");
    await until(() => !status().call, 5000);
    check("Teams leave ends the call", !status().call);

    // --- Zoom web: leave asks first; End Meeting for All must never be pressed ---
    const zoom = [];
    zoom.push(new El("mute my microphone", {}, toggler("mute my microphone", "unmute my microphone")));
    zoom.push(new El("Leave", {}, () => {
      zoom.push(new El("End Meeting for All", {}, hangUp(zoom)), new El("Leave Meeting", {}, hangUp(zoom)));
    }));
    openTab(3, "app.zoom.us", zoom);
    st = await until(() => { const s = status(); return s.call === "Zoom web" && s; });
    check("Zoom web call seen", !!st, st ? JSON.stringify(st.call) : "");
    url("squelch://leave");
    await until(() => !status().call, 5000);
    check("Zoom leave confirms with Leave Meeting", clicks.includes("Leave Meeting") && !status().call);
    check("End Meeting for All never pressed", !clicks.includes("End Meeting for All"));
  } finally {
    execSync("defaults delete io.forit.squelch testURLs");
  }
  console.log(`clicks: ${clicks.join(" | ")}`);
  console.log(`${results.filter(Boolean).length}/${results.length} passed`);
  pageTimers.forEach(clearInterval);
  process.exit(results.every(Boolean) ? 0 : 1);
})();
