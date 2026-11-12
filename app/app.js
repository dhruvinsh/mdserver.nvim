"use strict";
const PREFIX = "/_mdserver/";
const $ = (sel) => document.querySelector(sel);
const docEl = $("#doc"), treeEl = $("#tree"), scrollEl = $("#scroll");

const state = {
  files: [],          // root-relative document paths: markdown and HTML
  index: new Map(),   // lower-cased path -> path
  current: null,      // path being shown
  loaded: false,
  htmlRe: /\.html?$/i, // HTML pages, from the server's html_extensions
};

// ---------------------------------------------------------------- paths

const dirname = (p) => p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "";
const encodePath = (p) => p.split("/").map(encodeURIComponent).join("/");
const urlFor = (p) => "/" + encodePath(p);

function pathFromUrl(url) {
  let p = url.pathname;
  try { p = decodeURIComponent(p); } catch {}
  return p.replace(/^\/+/, "").replace(/\/+$/, "");
}

const isMarkdownPath = (p) => /\.(md|markdown|mdx)$/i.test(p);
const isHtmlPath = (p) => typeof p === "string" && state.htmlRe.test(p);
const basename = (p) => p.slice(p.lastIndexOf("/") + 1);

const INDEX_NAMES = ["readme.md", "index.md", "readme.markdown", "index.markdown", "index.html", "index.htm"];

/** Document for a root-relative path: exact, without extension, or a directory index. */
function resolveDoc(p) {
  const key = p.toLowerCase();
  for (const cand of [key, key + ".md", key + ".markdown", key + ".html"]) {
    if (state.index.has(cand)) return state.index.get(cand);
  }
  const prefix = key ? key + "/" : "";
  for (const name of INDEX_NAMES) {
    if (state.index.has(prefix + name)) return state.index.get(prefix + name);
  }
  // Directory without an index: its first markdown file.
  if (!key) return state.files[0] ?? null;
  return state.files.find((f) => f.toLowerCase().startsWith(prefix)) ?? null;
}

/**
 * Document to show for a path. HTML pages missing from the tree (git ignored,
 * like generated reports) are still shown: the server knows whether they exist.
 */
const docFor = (p) => resolveDoc(p) ?? (isHtmlPath(p) ? p : null);

// ---------------------------------------------------------------- tree

function buildTree(files) {
  const root = { dirs: new Map(), files: [] };
  for (const f of files) {
    const parts = f.split("/");
    let node = root;
    for (const part of parts.slice(0, -1)) {
      if (!node.dirs.has(part)) node.dirs.set(part, { dirs: new Map(), files: [] });
      node = node.dirs.get(part);
    }
    node.files.push(f);
  }
  return root;
}

const openDirs = new Set(JSON.parse(sessionStorage.getItem("mdserver.open") || "[]"));
const saveOpen = () => sessionStorage.setItem("mdserver.open", JSON.stringify([...openDirs]));

function renderTree() {
  const q = $("#filter").value.trim().toLowerCase();
  const files = q ? state.files.filter((f) => f.toLowerCase().includes(q)) : state.files;
  treeEl.replaceChildren();
  if (!files.length) {
    treeEl.innerHTML = `<div class="empty">${state.files.length ? "No match" : "No markdown or HTML files"}</div>`;
    return;
  }
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const base = basename;

  const walk = (node, prefix) => {
    const ul = document.createElement("ul");
    for (const name of [...node.dirs.keys()].sort(collator.compare)) {
      const dir = prefix + name;
      const li = document.createElement("li");
      li.className = "dir" + (q || openDirs.has(dir) ? "" : " closed");
      li.dataset.dir = dir;
      li.innerHTML = `<div class="row"><span class="icon"></span><span class="name"></span></div>`;
      li.querySelector(".name").textContent = name;
      li.append(walk(node.dirs.get(name), dir + "/"));
      ul.append(li);
    }
    for (const f of node.files.sort((a, b) => collator.compare(base(a), base(b)))) {
      const li = document.createElement("li");
      li.className = "file";
      li.innerHTML = `<a class="row"><span class="icon">${isHtmlPath(f) ? "◇" : "•"}</span><span class="name"></span></a>`;
      const a = li.firstChild;
      a.href = urlFor(f);
      a.dataset.path = f;
      a.title = f;
      a.querySelector(".name").textContent = base(f);
      ul.append(li);
    }
    return ul;
  };
  treeEl.append(walk(buildTree(files), ""));
  updateDirIcons();
  markActive();
}

function updateDirIcons() {
  for (const li of treeEl.querySelectorAll("li.dir")) {
    li.firstChild.firstChild.textContent = li.classList.contains("closed") ? "▶" : "▼";
  }
}

function markActive() {
  let active = null;
  for (const a of treeEl.querySelectorAll("a.row")) {
    const on = a.dataset.path === state.current;
    a.classList.toggle("active", on);
    if (on) active = a;
  }
  if (!active) return;
  // Unfold the parents of the current file.
  for (let li = active.parentElement.parentElement.closest("li.dir"); li; li = li.parentElement.closest("li.dir")) {
    li.classList.remove("closed");
    openDirs.add(li.dataset.dir);
  }
  saveOpen();
  updateDirIcons();
  const r = active.getBoundingClientRect(), t = treeEl.getBoundingClientRect();
  if (r.top < t.top || r.bottom > t.bottom) active.scrollIntoView({ block: "center" });
}

treeEl.addEventListener("click", (e) => {
  const row = e.target.closest(".row");
  if (!row) return;
  const li = row.parentElement;
  if (li.classList.contains("dir")) {
    li.classList.toggle("closed");
    li.classList.contains("closed") ? openDirs.delete(li.dataset.dir) : openDirs.add(li.dataset.dir);
    saveOpen();
    updateDirIcons();
  } else if (!(e.ctrlKey || e.metaKey || e.shiftKey || e.button)) {
    e.preventDefault();
    navigate(row.dataset.path, "", true);
  }
});

async function loadTree() {
  const res = await fetch(PREFIX + "tree");
  const data = await res.json();
  const exts = (data.html_extensions ?? []).map((e) => e.replace(/[^\w]/g, ""));
  state.htmlRe = exts.length ? new RegExp(`\\.(${exts.join("|")})$`, "i") : /(?!)/;
  state.files = data.files;
  state.index = new Map(data.files.map((f) => [f.toLowerCase(), f]));
  $("#project").textContent = data.name;
  $("#project").title = data.root;
  state.mermaidUrl = data.mermaid;
  state.missing = data.missing;
  renderTree();
}

// ---------------------------------------------------------------- rendering

/** GitHub style heading ids. */
function slugger() {
  const seen = new Map();
  return (text) => {
    let slug = text.trim().toLowerCase()
      .replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "")
      .replace(/ /g, "-");
    const n = seen.get(slug);
    seen.set(slug, (n ?? -1) + 1);
    return n === undefined ? slug : `${slug}-${n + 1}`;
  };
}

function splitFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n(---|\.\.\.)\r?\n/);
  return m ? [m[1], text.slice(m[0].length)] : [null, text];
}

/** Render into #doc. Resolves once the mermaid diagrams are drawn. */
function renderMarkdown(path, text) {
  const [front, body] = splitFrontmatter(text);
  if (!window.marked) {
    docEl.innerHTML = `<p class="notfound">The markdown renderer is not installed. Run
      <code>:Lazy build mdserver</code> or <code>:MdServer install</code> in Neovim, then reload.</p>`;
    return Promise.resolve();
  }
  docEl.innerHTML = marked.parse(body, { gfm: true });
  if (front) {
    const details = document.createElement("details");
    details.className = "frontmatter";
    details.innerHTML = `<summary>front matter</summary><pre><code class="language-yaml"></code></pre>`;
    details.querySelector("code").textContent = front;
    docEl.prepend(details);
  }

  embedMedia();

  const slug = slugger();
  for (const h of docEl.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    h.id = slug(h.textContent);
    const a = document.createElement("a");
    a.className = "anchor";
    a.href = "#" + h.id;
    a.textContent = "#";
    a.setAttribute("aria-hidden", "true");
    h.append(a);
  }

  for (const a of docEl.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href");
    let url;
    try { url = new URL(href, location.href); } catch { continue; }
    if (url.origin !== location.origin) {
      a.target = "_blank";
      a.rel = "noopener noreferrer";
    } else if (!href.startsWith("#")) {
      const p = pathFromUrl(url);
      if (isMarkdownPath(p) && !resolveDoc(p)) a.classList.add("missing"); // not HTML: may be git ignored
    }
  }
  // Task list checkboxes are read only.
  for (const box of docEl.querySelectorAll("input[type=checkbox]")) box.disabled = true;

  highlightCode();
  return renderDiagrams();
}

// ---------------------------------------------------------------- video and audio

const VIDEO = /\.(mp4|m4v|webm|ogv|mov)$/i;
const AUDIO = /\.(mp3|m4a|wav|ogg|oga|opus|flac)$/i;

function mediaKind(src) {
  let path;
  try { path = new URL(src, location.href).pathname; } catch { return null; }
  return VIDEO.test(path) ? "video" : AUDIO.test(path) ? "audio" : null;
}

function mediaPlayer(kind, src, title) {
  const el = document.createElement(kind);
  el.src = src;
  el.controls = true;
  el.preload = "metadata";
  if (title) el.title = title;
  return el;
}

/** YouTube / Vimeo page URL -> embeddable player URL. */
function embedUrl(href) {
  let url;
  try { url = new URL(href); } catch { return null; }
  const host = url.hostname.replace(/^(www|m)\./, "");
  let id = null;
  if (host === "youtu.be") id = url.pathname.slice(1);
  else if (host === "youtube.com" || host === "youtube-nocookie.com") {
    id = url.searchParams.get("v") || url.pathname.match(/^\/(?:embed|shorts|live)\/([\w-]+)/)?.[1];
  } else if (host === "vimeo.com") {
    const vimeo = url.pathname.match(/^\/(\d+)/)?.[1];
    return vimeo ? `https://player.vimeo.com/video/${vimeo}` : null;
  }
  if (!id || !/^[\w-]{6,}$/.test(id)) return null;
  const embed = new URL(`https://www.youtube-nocookie.com/embed/${id}`);
  const start = url.searchParams.get("t") || url.searchParams.get("start");
  const seconds = start && (/^\d+$/.test(start) ? start
    : (start.match(/^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/) || []).slice(1).reduce((s, n, i) => s + (+n || 0) * [3600, 60, 1][i], 0));
  if (seconds) embed.searchParams.set("start", seconds);
  return embed.href;
}

function embedFrame(src, title) {
  const div = document.createElement("div");
  div.className = "embed";
  const frame = document.createElement("iframe");
  frame.src = src;
  frame.title = title;
  frame.loading = "lazy";
  frame.allow = "encrypted-media; picture-in-picture; fullscreen";
  frame.referrerPolicy = "strict-origin-when-cross-origin";
  div.append(frame);
  return div;
}

/**
 * Players for media that markdown has no syntax for:
 * - `![title](clip.mp4)`: image syntax pointing at a video or audio file
 * - a URL alone in its paragraph (like GitHub does for video attachments):
 *   video/audio files get a player, YouTube and Vimeo pages their embedded player.
 * `<video>`/`<audio>` HTML is rendered as it is.
 */
function embedMedia() {
  for (const img of docEl.querySelectorAll("img[src]")) {
    const kind = mediaKind(img.getAttribute("src"));
    if (kind) img.replaceWith(mediaPlayer(kind, img.getAttribute("src"), img.alt));
  }
  for (const p of docEl.querySelectorAll("p")) {
    const a = p.children.length === 1 && p.firstElementChild;
    if (!a || a.tagName !== "A" || p.textContent.trim() !== a.textContent.trim()) continue;
    const href = a.getAttribute("href");
    if (a.textContent.trim() !== href) continue; // [text](url) stays a link
    const kind = mediaKind(href);
    const embed = !kind && embedUrl(href);
    if (kind) p.replaceWith(mediaPlayer(kind, href));
    else if (embed) p.replaceWith(embedFrame(embed, href));
  }
}

// ---------------------------------------------------------------- code and diagrams

const codeLanguage = (code) =>
  [...code.classList].find((c) => c.startsWith("language-"))?.slice("language-".length).toLowerCase();

function highlightCode() {
  if (!window.hljs) return;
  for (const code of docEl.querySelectorAll("pre > code")) {
    const lang = codeLanguage(code);
    // Like GitHub: only fenced blocks with a known language are highlighted.
    if (lang && lang !== "mermaid" && hljs.getLanguage(lang)) hljs.highlightElement(code);
  }
}

const darkScheme = matchMedia("(prefers-color-scheme: dark)");
const diagramCache = new Map(); // theme + source -> svg, keeps live editing from flickering
let mermaidLoad = null;
let diagramQueue = Promise.resolve(); // mermaid.render is not safe to run concurrently
let diagramSeq = 0;

function loadMermaid() {
  mermaidLoad ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = state.mermaidUrl;
    script.onload = () => resolve(window.mermaid);
    script.onerror = () => {
      script.remove();
      mermaidLoad = null;
      reject(new Error("mermaid is not installed: run :Lazy build mdserver or :MdServer install in Neovim."));
    };
    document.head.append(script);
  });
  return mermaidLoad;
}

function diagramError(div, message) {
  div.className = "mermaid error";
  div.innerHTML = `<pre><code></code></pre><div class="msg"></div>`;
  div.querySelector("code").textContent = div.dataset.source;
  div.querySelector(".msg").textContent = message;
}

function renderDiagrams() {
  const blocks = [...docEl.querySelectorAll("pre > code")].filter((c) => codeLanguage(c) === "mermaid");
  if (!blocks.length) return Promise.resolve();
  const theme = darkScheme.matches ? "dark" : "default";
  const pending = [];
  for (const code of blocks) {
    const div = document.createElement("div");
    div.className = "mermaid";
    div.dataset.source = code.textContent;
    const svg = diagramCache.get(theme + "\n" + div.dataset.source);
    if (svg) {
      div.innerHTML = svg;
    } else {
      div.classList.add("pending");
      div.textContent = "Rendering diagram…";
      pending.push(div);
    }
    code.parentElement.replaceWith(div);
  }
  if (!pending.length) return Promise.resolve();

  diagramQueue = diagramQueue.then(async () => {
    if (!pending.some((div) => div.isConnected)) return; // re-rendered meanwhile
    let mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (err) {
      pending.forEach((div) => diagramError(div, err.message));
      return;
    }
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme });
    for (const div of pending) {
      if (!div.isConnected) continue;
      const id = "mermaid-" + ++diagramSeq;
      try {
        const { svg } = await mermaid.render(id, div.dataset.source);
        if (diagramCache.size > 100) diagramCache.delete(diagramCache.keys().next().value);
        diagramCache.set(theme + "\n" + div.dataset.source, svg);
        div.className = "mermaid";
        div.innerHTML = svg;
      } catch (err) {
        document.getElementById("d" + id)?.remove(); // mermaid leaves its error graphic behind
        diagramError(div, err?.message ?? String(err));
      }
    }
  });
  return diagramQueue;
}

// Diagrams follow the theme; HTML pages see the change themselves.
darkScheme.addEventListener("change", () => isHtmlPath(state.current) || reloadCurrent());

// ---------------------------------------------------------------- HTML pages

// Framed from the raw route, so the page's relative URLs (styles, scripts,
// images, links to its sibling pages) load the files themselves, not this app.
const RAW = PREFIX + "raw/";
const rawUrl = (p) => RAW + encodePath(p);

/** Root-relative path the frame shows, null when it left the project's raw files. */
function framePath(frame) {
  let loc;
  try { loc = frame.contentWindow.location; } catch { return null; } // another origin
  if (loc.origin !== location.origin || !loc.pathname.startsWith(RAW)) return null;
  let p = loc.pathname.slice(RAW.length);
  try { p = decodeURIComponent(p); } catch {}
  return p.replace(/\/+$/, "");
}

function pageFrame(src) {
  const frame = document.createElement("iframe");
  frame.className = "page-frame";
  frame.allowFullscreen = true;
  frame.src = src;
  frame.addEventListener("load", () => pageLoaded(frame));
  return frame;
}

/** A link inside the page led to another page: the URL, tree and toolbar follow it. */
function pageLoaded(frame) {
  if (!frame.isConnected) return;
  const p = framePath(frame);
  if (!p) return;
  if (!isHtmlPath(p)) {
    // a relative link to a markdown document (render it rather than show its
    // source) or to a directory (show its README or index.html); other files stay
    const doc = resolveDoc(p);
    if (doc) navigate(doc, frame.contentWindow.location.hash, true);
    return;
  }
  if (p !== state.current) {
    state.current = p;
    // replace: the frame's navigation already made the history entry
    history.replaceState({}, "", urlFor(p) + frame.contentWindow.location.hash);
    showPath(p);
  }
  document.title = (frame.contentDocument?.title || basename(p)) + " · mdserver";
}

/** Reload the page in place: the new frame replaces the old one once loaded, at the same scroll position. */
function reloadPage() {
  const old = docEl.querySelector(".page-frame:not(.loading)");
  if (!old) return;
  docEl.querySelectorAll(".page-frame.loading").forEach((f) => f.remove()); // superseded reloads
  let src = rawUrl(state.current), x = 0, y = 0;
  if (framePath(old)) {
    const win = old.contentWindow;
    [src, x, y] = [win.location.href, win.scrollX, win.scrollY];
  }
  const frame = pageFrame(src);
  frame.classList.add("loading");
  frame.addEventListener("load", () => {
    try { frame.contentWindow.scrollTo(x, y); } catch {}
    frame.classList.remove("loading");
    old.remove();
  }, { once: true });
  docEl.append(frame);
}

/** Whether the page loaded the project file `path` (a style sheet, script, image, ...). */
function pageUses(path) {
  const frame = docEl.querySelector(".page-frame:not(.loading)");
  let entries;
  try { entries = frame.contentWindow.performance.getEntriesByType("resource"); } catch { return true; }
  return entries.some((e) => {
    let p;
    try { p = decodeURIComponent(new URL(e.name).pathname); } catch { return false; }
    return p === "/" + path || p === RAW + path;
  });
}

function scrollToHash(hash) {
  if (!hash || hash === "#") { scrollEl.scrollTop = 0; return; }
  let id = hash.slice(1);
  try { id = decodeURIComponent(id); } catch {}
  const el = document.getElementById(id) || document.getElementById(id.toLowerCase());
  if (el) el.scrollIntoView(); else scrollEl.scrollTop = 0;
}

function renderCrumbs(path) {
  const crumbs = $("#crumbs");
  crumbs.replaceChildren();
  const parts = path.split("/");
  parts.forEach((part, i) => {
    if (i) crumbs.append(" / ");
    const a = document.createElement("a");
    a.textContent = part;
    a.href = urlFor(parts.slice(0, i + 1).join("/"));
    crumbs.append(a);
  });
}

async function fetchDoc(path) {
  const res = await fetch(PREFIX + "raw/" + encodePath(path));
  if (!res.ok) throw new Error(res.status);
  return res.text();
}

/** Title, crumbs, tree and toolbar for the document at `path`. */
function showPath(path) {
  const page = isHtmlPath(path);
  document.body.classList.toggle("page", page);
  if (page) $("#raw").href = rawUrl(path);
  document.title = basename(path) + " · mdserver";
  renderCrumbs(path);
  markActive();
}

/**
 * Show `path` (root-relative markdown or HTML file), then scroll to `hash`.
 * The URL is updated first so relative links and images resolve against the document.
 */
async function navigate(path, hash, push) {
  const target = urlFor(path) + (hash || "");
  if (push && location.pathname + location.hash !== target) history.pushState({}, "", target);
  else if (!push) history.replaceState({}, "", target);

  const page = isHtmlPath(path);
  if (path === state.current && state.loaded) {
    if (!page) scrollToHash(hash);
    else if (hash) try { docEl.querySelector(".page-frame").contentWindow.location.hash = hash; } catch {}
    return;
  }
  state.current = path;
  state.loaded = false;
  showPath(path);
  if (page) {
    // a new frame each time: navigating an existing one adds a history entry of its own
    docEl.replaceChildren(pageFrame(rawUrl(path) + (hash || "")));
    state.loaded = true;
    return;
  }
  let diagrams;
  try {
    diagrams = renderMarkdown(path, await fetchDoc(path));
    state.loaded = true;
  } catch (err) {
    docEl.innerHTML = `<p class="notfound">Cannot load <code></code> (${err.message}).</p>`;
    docEl.querySelector("code").textContent = path;
  }
  scrollToHash(hash);
  // Diagrams change the layout once drawn.
  if (hash && diagrams) diagrams.then(() => state.current === path && scrollToHash(hash));
}

/** Navigate to whatever the current URL points at. */
function route() {
  const p = pathFromUrl(location);
  const doc = docFor(p);
  if (doc) return navigate(doc, location.hash, false);
  state.current = p;
  state.loaded = false;
  document.body.classList.remove("page");
  renderCrumbs(p || "/");
  markActive();
  docEl.innerHTML = state.files.length
    ? `<p class="notfound">No markdown or HTML file at <code></code>.</p>`
    : `<p class="notfound">No markdown or HTML files in this project.</p>`;
  docEl.querySelector("code")?.append(p || "/");
}

async function reloadCurrent() {
  if (!state.current || !state.loaded) return;
  if (isHtmlPath(state.current)) return reloadPage();
  const top = scrollEl.scrollTop;
  try {
    const path = state.current;
    const diagrams = renderMarkdown(path, await fetchDoc(path));
    scrollEl.scrollTop = top;
    diagrams.then(() => { if (state.current === path) scrollEl.scrollTop = top; });
  } catch {}
}

// ---------------------------------------------------------------- links

docEl.addEventListener("click", (e) => {
  const a = e.target.closest("a[href]");
  if (!a || e.defaultPrevented || e.button || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
  const href = a.getAttribute("href");
  let url;
  try { url = new URL(href, location.href); } catch { return; }
  if (url.origin !== location.origin) return;              // external: new tab
  if (url.pathname.startsWith(PREFIX)) return;
  const doc = docFor(pathFromUrl(url));
  if (!doc) return;                                        // images, source files, ...: let the browser load them
  e.preventDefault();
  navigate(doc, url.hash, true);
});

$("#crumbs").addEventListener("click", (e) => {
  const a = e.target.closest("a");
  if (!a || e.ctrlKey || e.metaKey) return;
  const doc = docFor(pathFromUrl(new URL(a.href)));
  if (!doc) return;
  e.preventDefault();
  navigate(doc, "", true);
});

window.addEventListener("popstate", route);

// Called by the app page when it finds itself in a frame (index.html): a framed
// page linked to a markdown document, which this app shows instead. True when
// it did; HTML pages and other files stay in their frame.
window.mdserver = {
  open(href) {
    let url;
    try { url = new URL(href); } catch { return false; }
    const p = pathFromUrl(url);
    const doc = !isHtmlPath(p) && resolveDoc(p);
    if (!doc) return false;
    setTimeout(() => navigate(doc, url.hash, true)); // after the calling frame's script
    return true;
  },
};

// ---------------------------------------------------------------- toolbar

$("#edit").addEventListener("click", () => {
  if (state.current && state.loaded) fetch(PREFIX + "edit?path=" + encodeURIComponent(state.current), { method: "POST" });
});

const toggleSide = () => {
  document.body.classList.toggle("collapsed");
  localStorage.setItem("mdserver.collapsed", document.body.classList.contains("collapsed") ? "1" : "");
};
$("#toggle").addEventListener("click", toggleSide);
if (localStorage.getItem("mdserver.collapsed")) document.body.classList.add("collapsed");

$("#filter").addEventListener("input", renderTree);
$("#filter").addEventListener("keydown", (e) => {
  if (e.key === "Escape") { e.target.value = ""; renderTree(); e.target.blur(); }
  if (e.key === "Enter") {
    const first = treeEl.querySelector("a.row");
    if (first) { navigate(first.dataset.path, "", true); e.target.blur(); }
  }
});

document.addEventListener("keydown", (e) => {
  if (e.target.matches("input, textarea") || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key === "/") { e.preventDefault(); $("#filter").focus(); }
  else if (e.key === "t") toggleSide();
  else if (e.key === "e") $("#edit").click();
});

// Resizable sidebar.
{
  const handle = $("#resize");
  const saved = localStorage.getItem("mdserver.width");
  if (saved) document.body.style.setProperty("--side-w", saved);
  handle.addEventListener("pointerdown", (e) => {
    handle.setPointerCapture(e.pointerId);
    handle.classList.add("drag");
    const move = (ev) => document.body.style.setProperty("--side-w", Math.max(160, Math.min(ev.clientX, 700)) + "px");
    const up = () => {
      handle.classList.remove("drag");
      handle.removeEventListener("pointermove", move);
      localStorage.setItem("mdserver.width", document.body.style.getPropertyValue("--side-w"));
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", up, { once: true });
  });
}

// ---------------------------------------------------------------- live updates

function connect() {
  const es = new EventSource(PREFIX + "events");
  const status = $("#status");
  es.onopen = () => {
    const wasDown = document.body.classList.contains("down");
    document.body.classList.remove("down");
    status.classList.remove("down");
    status.textContent = "live";
    if (wasDown) loadTree().then(reloadCurrent);
  };
  es.onerror = () => {
    document.body.classList.add("down");
    status.classList.add("down");
    status.textContent = "stopped";
  };
  es.addEventListener("follow", (e) => {
    const { path } = JSON.parse(e.data);
    if (path !== state.current) {
      if (!state.index.has(path.toLowerCase())) loadTree().then(() => navigate(path, "", true));
      else navigate(path, "", true);
    }
  });
  es.addEventListener("change", (e) => {
    const { path } = JSON.parse(e.data);
    if (path === state.current) reloadCurrent();
  });
  es.addEventListener("tree", () => loadTree());
  es.addEventListener("asset", (e) => {
    const { path } = JSON.parse(e.data);
    if (isHtmlPath(state.current) && state.loaded && pageUses(path)) reloadPage();
  });
}

// Framed (see index.html), the page is on its way somewhere else.
if (window.self === window.top) {
  loadTree().then(route).catch((err) => {
    docEl.textContent = "Cannot reach the Neovim server: " + err.message;
  }).finally(connect);
}
