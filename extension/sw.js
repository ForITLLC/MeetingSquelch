// sw.js: the extension's background. It keeps one WebSocket to the Mac app on this computer, passes
// each meeting tab's state to it, and passes the app's presses back to that tab.
// Protocol "forit.call" v1, JSON text frames:
//   to the app:   {t:"hello", proto, v, ext}  {t:"call", id, site, mic, camera, share}  {t:"end", id}  {t:"ping"}
//   from the app: {t:"do", id, what}  what = mic | camera | share | leave | front
// id is "<tab>:<frame>". mic true = muted, camera true = on, share true = presenting, null = unknown.
// The socket is only opened while a tab is in a call, and closes when the worker sleeps.
const PORT = 47213; // the app's default (defaults key extensionPort)
const calls = new Map(); // id -> { tab, frame, win, at, msg }
let ws = null;
let ready = false;
let wait = 1000;
let retry = null;
let ping = null;

function post(m) {
  if (ready) ws.send(JSON.stringify(m));
}

function connect() {
  if (ws || retry) return;
  try {
    ws = new WebSocket(`ws://127.0.0.1:${PORT}/`);
  } catch {
    ws = null;
    return later();
  }
  ws.onopen = () => {
    ready = true;
    wait = 1000;
    post({ t: "hello", proto: "forit.call", v: 1, ext: chrome.runtime.getManifest().version });
    for (const c of calls.values()) post(c.msg);
    ping = setInterval(() => post({ t: "ping" }), 20000); // also keeps the worker awake
  };
  ws.onmessage = (e) => {
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    if (m && m.t === "do") act(m);
  };
  ws.onclose = () => {
    ws = null;
    ready = false;
    clearInterval(ping);
    if (calls.size) later();
  };
}

function later() {
  retry = setTimeout(() => { retry = null; connect(); }, wait);
  wait = Math.min(wait * 2, 30000);
}

function newest() {
  let best = null;
  for (const c of calls.values()) if (!best || c.at > best.at) best = c;
  return best;
}

function act(m) {
  const c = calls.get(m.id) || newest();
  if (!c) return;
  if (m.what === "front") {
    chrome.tabs.update(c.tab, { active: true }).catch(() => {});
    chrome.windows.update(c.win, { focused: true }).catch(() => {});
    return;
  }
  chrome.tabs.sendMessage(c.tab, { t: "do", what: m.what }, { frameId: c.frame }).catch(() => {});
}

function end(id) {
  if (calls.delete(id)) post({ t: "end", id });
}

chrome.runtime.onMessage.addListener((m, sender) => {
  if (sender.id !== chrome.runtime.id || !sender.tab) return;
  const id = `${sender.tab.id}:${sender.frameId}`;
  if (m.t === "call") {
    const msg = { t: "call", id, site: m.site, mic: m.mic, camera: m.camera, share: m.share };
    calls.set(id, { tab: sender.tab.id, frame: sender.frameId, win: sender.tab.windowId, at: Date.now(), msg });
    post(msg);
    connect();
  } else if (m.t === "end") {
    end(id);
  }
});

chrome.tabs.onRemoved.addListener((tab) => {
  for (const [id, c] of calls) if (c.tab === tab) end(id);
});
