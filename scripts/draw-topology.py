#!/usr/bin/env python3
"""Draw diagrams/network-topology.svg from ansible/inventory/group_vars/all.yml.

Self-contained SVG (no external renderer or network access needed), so the
diagram always matches the real addressing. Usage: python3 scripts/draw-topology.py
"""
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
cfg = yaml.safe_load((ROOT / "ansible/inventory/group_vars/all.yml").read_text())
sites, wan, edge, dns, reg, wg = cfg["sites"], cfg["wan"], cfg["edge"], cfg["dns"], cfg["registry"], cfg["wireguard"]

W, H = 1100, 720
COL = {"a": "#0284c7", "b": "#7c3aed", "c": "#d97706"}
out = []
add = out.append


def box(x, y, w, h, fill, stroke, rx=10, sw=1.5, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, weight="normal", fill="#0f172a", anchor="middle"):
    add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{s}</text>')


def line(x1, y1, x2, y2, stroke="#64748b", sw=2, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
    'font-family="Segoe UI, Helvetica, Arial, sans-serif">')
add(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
text(W / 2, 32, "Multi-Site HA Platform: network topology", 20, "bold")
text(W / 2, 54, "All components run as containers on one Ubuntu VM (sites are simulated; the network separation is real)", 12, fill="#475569")

# Windows host and VM boundary
box(440, 72, 220, 44, "#f1f5f9", "#334155")
text(550, 92, "Windows host (browser / kubectl)", 12, "bold")
text(550, 108, "VMware NAT -> 192.168.30.128", 11, fill="#475569")
box(20, 130, W - 40, H - 150, "none", "#94a3b8", rx=14, dash="6 4")
text(40, 150, "Ubuntu VM (Docker Engine)", 12, "bold", "#475569", "start")

# WAN segment
wy = 250
box(60, wy - 18, W - 120, 36, "#e2e8f0", "#475569", rx=18)
text(W / 2, wy + 5, f"WAN / transit  {wan['subnet']}   (gateway {wan['gateway']} -> internet via VM NAT)", 13, "bold")

# shared services above the WAN
svc = [("edge (HAProxy)", edge["ip"], ":8080 app  :6443 API  :8404 stats"),
       ("lab DNS (CoreDNS)", dns["ip"], f"zone {dns['zone']}"),
       ("image registry", reg["ip"], ":5000")]
for i, (name, ip, sub) in enumerate(svc):
    x = 200 + i * 270
    box(x, 160, 210, 50, "#f8fafc", "#475569")
    text(x + 105, 180, f"{name}  {ip}", 12, "bold")
    text(x + 105, 198, sub, 11, fill="#475569")
    line(x + 105, 210, x + 105, wy - 18)
line(550, 116, 305, 160, "#334155", 2)

# sites
sx = [70, 405, 740]
ry = 330
for s, x in zip(sites, sx):
    c = COL[s["id"]]
    # router
    box(x + 60, ry, 170, 58, "#ffffff", c, sw=2.5)
    text(x + 145, ry + 20, f"router-{s['id']}", 13, "bold", c)
    text(x + 145, ry + 36, f"WAN {s['router_wan_ip']}", 11)
    text(x + 145, ry + 50, f"wg0 {s['router_wg_ip']} | FW default DROP", 10, fill="#475569")
    line(x + 145, wy + 18, x + 145, ry, c, 2.5)
    # site LAN
    ly = 470
    box(x, ly, 290, 190, "#f8fafc", c, sw=2)
    text(x + 145, ly + 22, f"{s['description']}", 14, "bold", c)
    text(x + 145, ly + 40, f"LAN {s['lan_subnet']}  gateway {s['router_lan_ip']}", 11)
    line(x + 145, ry + 58, x + 145, ly, c, 2.5)
    box(x + 15, ly + 55, 260, 55, "#ffffff", "#334155")
    text(x + 145, ly + 76, f"{s['name']}-server  {s['server_ip']}", 12, "bold")
    text(x + 145, ly + 94, "K3s server: API, scheduler, etcd member", 11, fill="#475569")
    box(x + 15, ly + 120, 260, 55, "#ffffff", "#334155")
    text(x + 145, ly + 141, f"{s['name']}-agent  {s['agent_ip']}", 12, "bold")
    text(x + 145, ly + 159, "K3s agent: workloads (SitePulse ...)", 11, fill="#475569")

# WireGuard mesh between routers (curved paths below the WAN bar)
pts = [(x + 145, ry + 58) for x in sx]
for (i, j) in [(0, 1), (1, 2), (0, 2)]:
    (x1, y1), (x2, y2) = pts[i], pts[j]
    cy = y1 + (55 if j - i == 1 else 85)
    add(f'<path d="M{x1 + (40 if i < j else -40)},{y1 - 10} Q{(x1 + x2) / 2},{cy} {x2 - 40},{y2 - 10}" '
        f'fill="none" stroke="#16a34a" stroke-width="3" stroke-dasharray="8 5"/>')
text(W / 2, ry + 112, f"WireGuard full mesh  {wg['subnet']}  UDP {wg['port']}  MTU {wg['mtu']}  (encrypted site-to-site links)",
     12, "bold", "#16a34a")

add("</svg>")
dest = ROOT / "diagrams/network-topology.svg"
dest.write_text("\n".join(out) + "\n")
print(f"wrote {dest.relative_to(ROOT)}")
