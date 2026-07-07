#!/usr/bin/env python3
"""Downloads Organizer - read-only observability dashboard.

Self-contained, dependency-free (Python 3.9+ standard library only).
Reports the live state of the macOS "Downloads Organizer" tool:
  - per-category file counts and sizes inside ~/Downloads
  - loose (unsorted) files still sitting in ~/Downloads
  - whether the launchd agent is loaded
  - recent "moved" activity parsed from the organizer log

This server is OBSERVE-ONLY. It never moves, deletes, edits, or otherwise
mutates any file, and it never touches the organizer or launchd. There are
no mutate endpoints.

Run:    python3 dashboard.py        (binds 127.0.0.1:8770, override via $PORT)
"""

import json
import os
import re
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import splitport

# ---------------------------------------------------------------------------
# Configuration / facts about the organizer
# ---------------------------------------------------------------------------

DOWNLOADS_DIR = Path.home() / "Downloads"
LOG_FILE = Path.home() / "Library" / "Logs" / "organize-downloads.log"
# The launchd label install.sh registers the agent under (see install.sh /
# com.organize-downloads.plist.template).
LAUNCHD_LABEL = "local.organize-downloads"
LAUNCHD_LABELS = [LAUNCHD_LABEL]


def _discover_categories():
    """Every top-level directory in ~/Downloads is a category.

    The organizer creates folders dynamically (user rules in
    ~/.config/organize-downloads/rules.conf plus auto-created per-extension
    folders), so the definitive category list is whatever directories exist.
    """
    names = []
    try:
        for entry in os.scandir(DOWNLOADS_DIR):
            try:
                if entry.name.startswith("."):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    names.append(entry.name)
            except OSError:
                pass
    except OSError:
        pass
    return sorted(names)

DEFAULT_PORT = 8770

# Matches the "moved" log lines produced by organize-downloads.sh, e.g.:
#   ... moved: foo.png -> Images/
#   ... moved (dup): bar.png -> Images/
#   ... moved dir: stuff -> Folders/
#   ... moved dir (dup): stuff -> Folders/
# "kind" captures the optional " dir"/" (dup)"/" dir (dup)" segment between
# "moved" and ":"; the dup flag is derived from whether "(dup)" appears in it.
_MOVE_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[organize-downloads\s+\d+\]\s+"
    r"moved(?P<kind>(?:\s+dir)?(?:\s*\(dup\))?):\s+"
    r"(?P<file>.+?)\s+->\s+(?P<dest>[^/\s]+)/?\s*$"
)


# ---------------------------------------------------------------------------
# Helpers (all defensive: never raise on missing paths)
# ---------------------------------------------------------------------------

def _scan_categories():
    """Return list of dicts for existing category folders.

    count = number of files directly inside the folder (top-level).
    bytes = recursive total size of the folder (best-effort, fast-ish).
    """
    out = []
    for name in _discover_categories():
        folder = DOWNLOADS_DIR / name
        try:
            if not folder.is_dir():
                continue
        except OSError:
            continue

        count = 0
        total = 0
        try:
            for entry in os.scandir(folder):
                try:
                    if entry.is_file(follow_symlinks=False):
                        count += 1
                except OSError:
                    pass
        except OSError:
            pass

        # Recursive size, best-effort.
        try:
            for root, _dirs, files in os.walk(folder):
                for fn in files:
                    try:
                        total += os.path.getsize(os.path.join(root, fn))
                    except OSError:
                        pass
        except OSError:
            pass

        out.append({"name": name, "count": count, "bytes": total})
    return out


def _count_loose():
    """Count files sitting directly in ~/Downloads (not yet sorted).

    Only top-level regular files; category folders and other dirs are
    excluded. Hidden dotfiles (e.g. .DS_Store) are ignored.
    """
    loose = 0
    try:
        for entry in os.scandir(DOWNLOADS_DIR):
            try:
                if entry.name.startswith("."):
                    continue
                if entry.is_file(follow_symlinks=False):
                    loose += 1
            except OSError:
                pass
    except OSError:
        return 0
    return loose


def _launchd_loaded():
    """Best-effort check whether the launchd agent is loaded (any known label)."""
    uid = os.getuid()
    # Preferred: launchctl print gui/<uid>/<label>
    for label in LAUNCHD_LABELS:
        try:
            r = subprocess.run(
                ["launchctl", "print", f"gui/{uid}/{label}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if r.returncode == 0:
                return True
        except (OSError, subprocess.SubprocessError):
            pass
    # Fallback: launchctl list, look for any known label.
    try:
        r = subprocess.run(
            ["launchctl", "list"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=5,
        )
        if r.returncode == 0:
            text = r.stdout.decode("utf-8", "replace")
            if any(label in text for label in LAUNCHD_LABELS):
                return True
    except (OSError, subprocess.SubprocessError):
        pass
    return False


def _read_recent_moves(limit=50):
    """Parse recent 'moved' lines from the log. Newest first."""
    moves = []
    last_run = None
    try:
        if not LOG_FILE.is_file():
            return [], None
    except OSError:
        return [], None

    try:
        with open(LOG_FILE, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            read_from = max(0, size - 262144)
            if read_from:
                fh.seek(read_from)
                fh.readline()
            else:
                fh.seek(0)
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return [], None

    if lines:
        # last_run = timestamp of the newest log line (any type), if parseable.
        for raw in reversed(lines):
            tok = raw.strip().split(" ", 1)
            if tok and _looks_like_ts(tok[0]):
                last_run = tok[0]
                break

    for raw in reversed(lines):
        m = _MOVE_RE.match(raw.strip())
        if not m:
            continue
        kind = m.group("kind") or ""
        moves.append({
            "ts": m.group("ts"),
            "file": m.group("file"),
            "dest": m.group("dest"),
            "dup": "(dup)" in kind,
        })
        if len(moves) >= limit:
            break

    return moves, last_run


def _looks_like_ts(s):
    return bool(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", s))


# ---------------------------------------------------------------------------
# State builder (exposed at module level for validation/testing)
# ---------------------------------------------------------------------------

def build_state():
    """Build the full dashboard state dict. Never raises on missing paths."""
    categories = _scan_categories()
    organized_files = sum(c["count"] for c in categories)
    total_bytes = sum(c["bytes"] for c in categories)
    moves, last_run = _read_recent_moves(50)

    return {
        "downloads_dir": str(DOWNLOADS_DIR),
        "generated_at": int(datetime.now(timezone.utc).timestamp()),
        "categories": categories,
        "totals": {
            "organized_files": organized_files,
            "categories": len(categories),
            "bytes": total_bytes,
        },
        "loose_in_downloads": _count_loose(),
        "launchd_loaded": _launchd_loaded(),
        "recent_moves": moves,
        "last_run": last_run,
    }


# ---------------------------------------------------------------------------
# HTML dashboard (embedded, dark, vanilla JS polling)
# ---------------------------------------------------------------------------

INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Downloads Organizer</title>
<style>
  :root{
    --bg:#0d1014; --panel:#161b22; --panel2:#1c232c; --border:#2a323d;
    --txt:#e6edf3; --muted:#8b97a7; --accent:#4cc2ff; --accent2:#7ee787;
    --warn:#f0883e; --dup:#d29922; --bar:#2d3a47;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);
    font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
  .wrap{max-width:1080px;margin:0 auto;padding:24px 20px 60px}
  header{display:flex;align-items:center;justify-content:space-between;
    flex-wrap:wrap;gap:12px;margin-bottom:22px}
  .title{display:flex;align-items:baseline;gap:12px}
  h1{font-size:20px;margin:0;font-weight:600;letter-spacing:.2px}
  .sub{color:var(--muted);font-size:12px}
  .status{display:flex;align-items:center;gap:18px;flex-wrap:wrap}
  .pill{display:flex;align-items:center;gap:7px;font-size:12px;color:var(--muted)}
  .dot{width:9px;height:9px;border-radius:50%;background:#555;
    box-shadow:0 0 0 0 rgba(0,0,0,0)}
  .dot.on{background:var(--accent2);box-shadow:0 0 8px rgba(126,231,135,.6)}
  .dot.off{background:var(--warn)}
  .live{position:relative}
  .live .dot{background:var(--accent);animation:pulse 1.6s ease-out infinite}
  @keyframes pulse{0%{box-shadow:0 0 0 0 rgba(76,194,255,.5)}
    70%{box-shadow:0 0 0 7px rgba(76,194,255,0)}100%{box-shadow:0 0 0 0 rgba(76,194,255,0)}}

  .strip{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:26px}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px}
  .card .k{font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted)}
  .card .v{font-size:26px;font-weight:600;margin-top:6px}
  .card .v.warn{color:var(--warn)}

  h2{font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);
    margin:26px 0 12px;font-weight:600}

  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px}
  .cat{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px}
  .cat .row{display:flex;justify-content:space-between;align-items:baseline}
  .cat .name{font-weight:600}
  .cat .cnt{font-size:12px;color:var(--muted)}
  .cat .size{font-size:12px;color:var(--muted);margin-top:2px}
  .track{height:6px;background:var(--bar);border-radius:4px;margin-top:10px;overflow:hidden}
  .fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));
    border-radius:4px;width:0;transition:width .4s ease}

  .feed{background:var(--panel);border:1px solid var(--border);border-radius:10px;overflow:hidden}
  .move{display:flex;align-items:center;gap:10px;padding:10px 14px;
    border-top:1px solid var(--border);font-size:13px}
  .move:first-child{border-top:none}
  .move .t{color:var(--muted);font-size:12px;min-width:84px;font-variant-numeric:tabular-nums}
  .move .f{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .move .arrow{color:var(--muted)}
  .move .d{color:var(--accent);font-weight:600}
  .badge{font-size:10px;background:var(--dup);color:#1a1207;border-radius:4px;
    padding:1px 6px;font-weight:700;text-transform:uppercase;letter-spacing:.4px}
  .empty{padding:18px 14px;color:var(--muted);font-size:13px}
  footer{margin-top:30px;color:var(--muted);font-size:11px;text-align:center}
  code{background:var(--panel2);padding:1px 6px;border-radius:4px;color:var(--muted)}
  @media(max-width:640px){.strip{grid-template-columns:repeat(2,1fr)}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="title">
      <h1>Downloads Organizer</h1>
      <span class="sub" id="dir"></span>
    </div>
    <div class="status">
      <span class="pill live"><span class="dot"></span><span id="live">live</span></span>
      <span class="pill"><span class="dot" id="ld-dot"></span><span id="ld-txt">launchd …</span></span>
      <span class="pill" id="lastrun-pill">last run <span id="lastrun" style="color:var(--txt)"></span></span>
    </div>
  </header>

  <div class="strip">
    <div class="card"><div class="k">Organized files</div><div class="v" id="t-files">-</div></div>
    <div class="card"><div class="k">Categories</div><div class="v" id="t-cats">-</div></div>
    <div class="card"><div class="k">Total size</div><div class="v" id="t-size">-</div></div>
    <div class="card"><div class="k">Loose / unsorted</div><div class="v" id="t-loose">-</div></div>
  </div>

  <h2>Categories</h2>
  <div class="grid" id="grid"></div>

  <h2>Recent moves</h2>
  <div class="feed" id="feed"></div>

  <footer>Read-only dashboard &middot; polls <code>/api/state</code> every 3s &middot; never modifies files</footer>
</div>

<script>
function humanBytes(n){
  if(!n||n<0) return "0 B";
  const u=["B","KB","MB","GB","TB"]; let i=0; let v=n;
  while(v>=1024 && i<u.length-1){v/=1024;i++;}
  return (i===0? v : v.toFixed(v<10?1:0)) + " " + u[i];
}
function relTime(iso){
  if(!iso) return "never";
  // Parse "2026-05-30T14:35:00+0200" -> normalise tz colon for JS
  let s=iso.replace(/([+-]\d{2})(\d{2})$/,"$1:$2");
  const d=new Date(s);
  if(isNaN(d)) return iso;
  const sec=Math.round((Date.now()-d.getTime())/1000);
  if(sec<0) return "just now";
  if(sec<60) return sec+"s ago";
  const m=Math.round(sec/60); if(m<60) return m+"m ago";
  const h=Math.round(m/60); if(h<24) return h+"h ago";
  const dy=Math.round(h/24); return dy+"d ago";
}
function clockTime(iso){
  let s=iso.replace(/([+-]\d{2})(\d{2})$/,"$1:$2");
  const d=new Date(s);
  if(isNaN(d)) return iso.slice(11,19)||iso;
  return d.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit",second:"2-digit"});
}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));}

function render(st){
  document.getElementById("dir").textContent = st.downloads_dir || "";
  document.getElementById("t-files").textContent = st.totals.organized_files;
  document.getElementById("t-cats").textContent  = st.totals.categories;
  document.getElementById("t-size").textContent  = humanBytes(st.totals.bytes);
  const loose=document.getElementById("t-loose");
  loose.textContent = st.loose_in_downloads;
  loose.classList.toggle("warn", st.loose_in_downloads>0);

  const dot=document.getElementById("ld-dot"), txt=document.getElementById("ld-txt");
  dot.className = "dot " + (st.launchd_loaded? "on":"off");
  txt.textContent = st.launchd_loaded? "launchd loaded" : "launchd not loaded";

  document.getElementById("lastrun").textContent = relTime(st.last_run);

  const max=Math.max(1, ...st.categories.map(c=>c.count));
  const grid=document.getElementById("grid");
  if(!st.categories.length){
    grid.innerHTML='<div class="empty">No category folders found in Downloads yet.</div>';
  } else {
    grid.innerHTML = st.categories.map(c=>{
      const pct=Math.round(c.count/max*100);
      return `<div class="cat">
        <div class="row"><span class="name">${esc(c.name)}</span><span class="cnt">${c.count}</span></div>
        <div class="size">${humanBytes(c.bytes)}</div>
        <div class="track"><div class="fill" style="width:${pct}%"></div></div>
      </div>`;
    }).join("");
  }

  const feed=document.getElementById("feed");
  if(!st.recent_moves.length){
    feed.innerHTML='<div class="empty">No moves recorded in the log yet.</div>';
  } else {
    feed.innerHTML = st.recent_moves.map(m=>`
      <div class="move">
        <span class="t" title="${esc(m.ts)}">${esc(clockTime(m.ts))}</span>
        <span class="f">${esc(m.file)}</span>
        <span class="arrow">&rarr;</span>
        <span class="d">${esc(m.dest)}</span>
        ${m.dup? '<span class="badge">dup</span>':''}
      </div>`).join("");
  }
}

let failures=0;
async function poll(){
  const live=document.getElementById("live");
  try{
    const r=await fetch("/api/state",{cache:"no-store"});
    if(!r.ok) throw new Error(r.status);
    render(await r.json());
    failures=0; live.textContent="live";
  }catch(e){
    failures++; live.textContent = failures>1? "reconnecting…" : "live";
  }
}
poll();
setInterval(poll,3000);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP server (read-only)
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "DownloadsOrganizerDash/1.0"

    def _host_allowed(self):
        host = self.headers.get("Host", "")
        if not host:
            return False
        hostname, port = splitport(host)
        if hostname is None:
            hostname = host
        if hostname.startswith("[") and hostname.endswith("]"):
            hostname = hostname[1:-1]
        hostname = hostname.lower()
        if hostname not in {"localhost", "127.0.0.1"}:
            return False
        if port is None:
            return True
        return port.isdigit()

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if not self._host_allowed():
            self._send(403, '{"error":"forbidden"}', "application/json; charset=utf-8")
            return
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, INDEX_HTML, "text/html; charset=utf-8")
        elif path == "/api/state":
            try:
                payload = json.dumps(build_state())
            except Exception as exc:  # never crash the request
                payload = json.dumps({"error": str(exc)})
                self._send(500, payload, "application/json; charset=utf-8")
                return
            self._send(200, payload, "application/json; charset=utf-8")
        else:
            self._send(404, '{"error":"not found"}', "application/json; charset=utf-8")

    # No do_POST / do_PUT / do_DELETE: server is strictly read-only.

    def log_message(self, fmt, *args):
        # Quiet, single-line access log to stderr.
        try:
            super().log_message(fmt, *args)
        except Exception:
            pass


def main():
    try:
        port = int(os.environ.get("PORT", DEFAULT_PORT))
    except (TypeError, ValueError):
        print(f"Invalid PORT value; falling back to {DEFAULT_PORT}")
        port = DEFAULT_PORT
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Downloads Organizer dashboard (read-only) on http://127.0.0.1:{port}")
    print(f"  downloads: {DOWNLOADS_DIR}")
    print(f"  log:       {LOG_FILE}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
