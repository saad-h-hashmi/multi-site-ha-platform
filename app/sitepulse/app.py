#!/usr/bin/env python3
"""
SitePulse: demonstration web application for the multi-site HA platform.

Standard library only (no pip packages), so the image is small and builds offline.

Endpoints
  GET  /              HTML dashboard (auto-refreshes; shows which pod/site served you)
  GET  /api/info      JSON: this instance, its node/site, health, visit counter
  GET  /api/replicas  JSON: every SitePulse pod, read from the Kubernetes API (RBAC: pods get/list)
  GET  /healthz       liveness probe: 200 unless a liveness failure was injected
  GET  /readyz        readiness probe: 200 when ready to receive traffic
  GET  /metrics       Prometheus metrics
  POST /chaos/liveness   make /healthz fail -> kubelet restarts the container   (CHAOS_ENABLED only)
  POST /chaos/readiness  toggle readiness   -> pod removed from Service endpoints (CHAOS_ENABLED only)
"""
import json
import os
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_NAME = os.environ.get("APP_NAME", "SitePulse")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
WELCOME = os.environ.get("WELCOME_MESSAGE", "Multi-Site HA Platform")
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
POD_NAMESPACE = os.environ.get("POD_NAMESPACE", "default")
POD_IP = os.environ.get("POD_IP", "unknown")
NODE_NAME = os.environ.get("NODE_NAME", "unknown")
APP_LABEL = os.environ.get("APP_LABEL", "app.kubernetes.io/name=sitepulse")
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
CHAOS_ENABLED = os.environ.get("CHAOS_ENABLED", "false").lower() == "true"
PORT = int(os.environ.get("PORT", "8000"))
# Node names follow "<site>-<role>", e.g. "site-b-agent" -> "site-b"
SITE = os.environ.get("SITE") or ("-".join(NODE_NAME.split("-")[:2]) if NODE_NAME.startswith("site-") else "unknown")

STARTED = time.time()
state = {"live": True, "ready": True, "shutting_down": False}
metrics_lock = threading.Lock()
request_counts = {}   # (path, code) -> count


# --------------------------------------------------------------------------- Redis
class RedisError(Exception):
    pass


def redis_cmd(*args, timeout=0.5):
    """Send one command using the Redis wire protocol (RESP) and return the reply."""
    def encode(parts):
        out = [f"*{len(parts)}\r\n".encode()]
        for p in parts:
            b = str(p).encode()
            out.append(f"${len(b)}\r\n".encode() + b + b"\r\n")
        return b"".join(out)

    with socket.create_connection((REDIS_HOST, REDIS_PORT), timeout=timeout) as s:
        f = s.makefile("rb")
        if REDIS_PASSWORD:
            s.sendall(encode(["AUTH", REDIS_PASSWORD]))
            _read_reply(f)
        s.sendall(encode(args))
        return _read_reply(f)


def _read_reply(f):
    line = f.readline()
    if not line:
        raise RedisError("connection closed")
    kind, body = line[:1], line[1:].strip()
    if kind == b"+":
        return body.decode()
    if kind == b"-":
        raise RedisError(body.decode())
    if kind == b":":
        return int(body)
    if kind == b"$":
        n = int(body)
        if n < 0:
            return None
        data = f.read(n + 2)
        return data[:-2].decode()
    raise RedisError(f"unexpected reply {line!r}")


def visits(increment):
    try:
        value = redis_cmd("INCR" if increment else "GET", "sitepulse:visits")
        return {"ok": True, "visits": int(value or 0)}
    except (OSError, RedisError) as e:
        return {"ok": False, "visits": None, "error": str(e)}


# --------------------------------------------------------------- Kubernetes API
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def list_replicas():
    """Read SitePulse pods from the Kubernetes API using this pod's service account."""
    try:
        with open(f"{SA_DIR}/token") as fh:
            token = fh.read().strip()
        ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        url = (f"https://{host}:{port}/api/v1/namespaces/{POD_NAMESPACE}/pods"
               f"?labelSelector={urllib.request.quote(APP_LABEL)}")
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, context=ctx, timeout=2) as r:
            data = json.load(r)
    except Exception as e:  # noqa: BLE001 - report any API problem on the page
        return {"ok": False, "error": str(e), "pods": []}
    pods = []
    for p in data.get("items", []):
        conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
        node = p.get("spec", {}).get("nodeName", "")
        restarts = sum(cs.get("restartCount", 0) for cs in p.get("status", {}).get("containerStatuses", []))
        pods.append({
            "name": p["metadata"]["name"],
            "node": node,
            "site": "-".join(node.split("-")[:2]) if node.startswith("site-") else "unknown",
            "phase": p.get("status", {}).get("phase"),
            "ready": conds.get("Ready") == "True",
            "restarts": restarts,
            "ip": p.get("status", {}).get("podIP"),
            "terminating": p["metadata"].get("deletionTimestamp") is not None,
        })
    pods.sort(key=lambda x: x["name"])
    return {"ok": True, "pods": pods}


def info(increment=False):
    return {
        "app": APP_NAME,
        "version": APP_VERSION,
        "message": WELCOME,
        "pod": POD_NAME,
        "namespace": POD_NAMESPACE,
        "pod_ip": POD_IP,
        "node": NODE_NAME,
        "site": SITE,
        "uptime_seconds": int(time.time() - STARTED),
        "health": {"live": state["live"], "ready": state["ready"] and not state["shutting_down"]},
        "counter": visits(increment),
        "python": sys.version.split()[0],
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


# ----------------------------------------------------------------------- HTTP
PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>SitePulse</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--fg:#e2e8f0;--mut:#94a3b8;--ok:#22c55e;--bad:#ef4444;--a:#38bdf8;--b:#a78bfa;--c:#f59e0b}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:980px;margin:0 auto;padding:24px 16px}h1{margin:0;font-size:26px}p.sub{margin:4px 0 20px;color:var(--mut)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.card{background:var(--card);border-radius:10px;padding:14px 16px}.k{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.v{font-size:18px;font-weight:600;word-break:break-all}.site-a{color:var(--a)}.site-b{color:var(--b)}.site-c{color:var(--c)}
table{width:100%;border-collapse:collapse;margin-top:8px}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid #334155;font-size:14px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}.up{background:var(--ok)}.down{background:var(--bad)}
#log{font:12px ui-monospace,monospace;color:var(--mut);max-height:150px;overflow:auto;white-space:pre}
h2{font-size:16px;margin:22px 0 6px}footer{margin-top:24px;color:var(--mut);font-size:12px}
</style></head><body><main>
<h1>SitePulse</h1><p class="sub" id="msg"></p>
<div class="grid">
 <div class="card"><div class="k">Served by pod</div><div class="v" id="pod">…</div></div>
 <div class="card"><div class="k">Node</div><div class="v" id="node">…</div></div>
 <div class="card"><div class="k">Site</div><div class="v" id="site">…</div></div>
 <div class="card"><div class="k">Edge backend (HAProxy)</div><div class="v" id="edge">…</div></div>
 <div class="card"><div class="k">Health</div><div class="v" id="health">…</div></div>
 <div class="card"><div class="k">Visits (Redis, persistent)</div><div class="v" id="visits">…</div></div>
</div>
<h2>Replicas (live from the Kubernetes API)</h2>
<div class="card"><table><thead><tr><th>Pod</th><th>Node</th><th>Site</th><th>Status</th><th>Restarts</th></tr></thead><tbody id="pods"></tbody></table></div>
<h2>Request log (each refresh may be served by a different replica)</h2><div class="card"><div id="log"></div></div>
<footer>Single-host lab: sites are simulated on one VM. Refreshes every 2 s.</footer>
</main><script>
const $=id=>document.getElementById(id);const cls=s=>/^site-[abc]$/.test(s)?s:'';
async function tick(){
 try{const r=await fetch('/api/info?count=1',{cache:'no-store'});const d=await r.json();
  $('msg').textContent=d.app+' v'+d.version+': '+d.message;$('pod').textContent=d.pod;$('node').textContent=d.node;
  $('site').innerHTML='<span class="'+cls(d.site)+'">'+d.site+'</span>';$('edge').textContent=r.headers.get('X-Edge-Backend')||'direct';
  $('health').innerHTML='<span class="dot '+(d.health.ready?'up':'down')+'"></span>'+(d.health.ready?'ready':'not ready');
  $('visits').textContent=d.counter.ok?d.counter.visits:'Redis unavailable';
  const l=$('log');l.textContent=new Date().toLocaleTimeString()+'  '+d.site.padEnd(7)+' '+d.node.padEnd(14)+' '+d.pod+'\\n'+l.textContent.slice(0,4000);
 }catch(e){$('log').textContent=new Date().toLocaleTimeString()+'  request failed: '+e+'\\n'+$('log').textContent}
 try{const p=await (await fetch('/api/replicas',{cache:'no-store'})).json();
  $('pods').innerHTML=p.pods.map(x=>'<tr><td>'+x.name+'</td><td>'+x.node+'</td><td class="'+cls(x.site)+'">'+x.site+'</td><td><span class="dot '+(x.ready&&!x.terminating?'up':'down')+'"></span>'+(x.terminating?'terminating':x.ready?'ready':x.phase)+'</td><td>'+x.restarts+'</td></tr>').join('')||'<tr><td colspan=5>'+(p.error||'none')+'</td></tr>';
 }catch(e){}
}
tick();setInterval(tick,2000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "SitePulse"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # one JSON line per request -> easy to grep in kubectl logs
        if self.path not in ("/healthz", "/readyz", "/metrics"):
            sys.stdout.write(json.dumps({"ts": time.strftime("%H:%M:%S"), "pod": POD_NAME,
                                         "req": self.requestline, "code": args[1] if len(args) > 1 else ""}) + "\n")
            sys.stdout.flush()

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else (json.dumps(body, indent=2) if ctype == "application/json" else body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Served-By-Pod", POD_NAME)
        self.send_header("X-Served-By-Node", NODE_NAME)
        self.end_headers()
        self.wfile.write(data)
        path = self.path.split("?")[0]
        with metrics_lock:
            request_counts[(path, code)] = request_counts.get((path, code), 0) + 1

    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path == "/":
            self._send(200, PAGE, "text/html")
        elif path == "/api/info":
            self._send(200, info(increment="count=1" in self.path))
        elif path == "/api/replicas":
            self._send(200, list_replicas())
        elif path == "/healthz":
            self._send(200 if state["live"] else 500, {"status": "ok" if state["live"] else "failing", "pod": POD_NAME})
        elif path == "/readyz":
            ok = state["ready"] and not state["shutting_down"]
            self._send(200 if ok else 503, {"status": "ready" if ok else "not-ready", "pod": POD_NAME})
        elif path == "/metrics":
            self._send(200, self._metrics(), "text/plain; version=0.0.4")
        else:
            self._send(404, {"error": "not found", "path": path})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0]
        if not CHAOS_ENABLED:
            self._send(403, {"error": "chaos endpoints disabled"})
        elif path == "/chaos/liveness":
            state["live"] = False
            self._send(200, {"pod": POD_NAME, "live": False, "note": "kubelet will restart this container"})
        elif path == "/chaos/readiness":
            state["ready"] = not state["ready"]
            self._send(200, {"pod": POD_NAME, "ready": state["ready"]})
        else:
            self._send(404, {"error": "not found"})

    def _metrics(self):
        r = visits(False)
        lines = [
            "# HELP sitepulse_info Static information about this instance.",
            "# TYPE sitepulse_info gauge",
            f'sitepulse_info{{version="{APP_VERSION}",pod="{POD_NAME}",node="{NODE_NAME}",site="{SITE}"}} 1',
            "# HELP sitepulse_up 1 when the instance is live.",
            "# TYPE sitepulse_up gauge",
            f"sitepulse_up {1 if state['live'] else 0}",
            "# HELP sitepulse_ready 1 when the instance is ready.",
            "# TYPE sitepulse_ready gauge",
            f"sitepulse_ready {1 if state['ready'] and not state['shutting_down'] else 0}",
            "# HELP sitepulse_redis_up 1 when Redis is reachable.",
            "# TYPE sitepulse_redis_up gauge",
            f"sitepulse_redis_up {1 if r['ok'] else 0}",
            "# HELP sitepulse_visits_total Visit counter stored in Redis.",
            "# TYPE sitepulse_visits_total counter",
            f"sitepulse_visits_total {r['visits'] or 0}",
            "# HELP sitepulse_uptime_seconds Seconds since this instance started.",
            "# TYPE sitepulse_uptime_seconds gauge",
            f"sitepulse_uptime_seconds {int(time.time() - STARTED)}",
            "# HELP sitepulse_http_requests_total HTTP requests by path and status code.",
            "# TYPE sitepulse_http_requests_total counter",
        ]
        with metrics_lock:
            for (p, c), n in sorted(request_counts.items()):
                lines.append(f'sitepulse_http_requests_total{{path="{p}",code="{c}"}} {n}')
        return "\n".join(lines) + "\n"


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True

    def shutdown(signum, _frame):
        # Graceful shutdown: fail readiness first so traffic drains, then stop.
        print(json.dumps({"event": "shutdown", "signal": signum, "pod": POD_NAME}), flush=True)
        state["shutting_down"] = True
        threading.Timer(3.0, server.shutdown).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(json.dumps({"event": "start", "app": APP_NAME, "version": APP_VERSION, "pod": POD_NAME,
                      "node": NODE_NAME, "site": SITE, "port": PORT}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
