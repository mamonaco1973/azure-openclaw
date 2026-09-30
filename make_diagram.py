#!/usr/bin/env python3
"""Generate the README architecture diagram, one SVG per colour scheme.

Two files rather than one self-switching file: GitHub strips <style> blocks
from inline SVG, so a `prefers-color-scheme` media query inside the document is
silently dropped and the diagram renders in whichever theme was hardcoded. The
README pairs them with <picture>, which GitHub does honour.

SVG rather than PNG so the text stays crisp at any width and stays searchable
in the rendered page.

Fuller than the video's version of this diagram on purpose. The video slide
carries five nodes because a phone screen cannot hold more; a README is read on
a monitor at whatever width the reader chooses, so the managed services the
agent actually calls are worth showing rather than narrating.

Still not the whole deployment: the VNet, its subnet and NSG, the NAT gateway,
the resource groups and the Xvfb framebuffer are all real and none of them
changes the request path this diagram exists to explain.

The Microsoft Foundry subtitle is read from azure-config.sh rather than typed here,
so changing the model list cannot leave the diagram claiming the old one.

Same layout and conventions as aws-openclaw's make_diagram.py -- keep the two
in step. One real difference: on Azure only Key Vault and Cost Management are
reached with the VM's managed identity. Microsoft Foundry takes an API key and ACS
a connection string, both read from Key Vault at boot; the footer says so.

Run:  python make_diagram.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))

# Sized to the content, not to a video frame: a 16:9 canvas in a README is
# mostly empty margin.
W, H = 1500, 800
NH = 110                                   # node height
TITLE_PX, SUB_PX, EDGE_PX = 26, 17, 16

# Three bands: the user, the VM, the Azure services it calls. The shape is the
# argument -- one box in the middle reaching a column of managed services.
BOX = (400, 70, 530, 650)                  # instance boundary: x, y, w, h
SPINE_X, SPINE_W = 440, 450                # nodes stacked inside the boundary
RIGHT_X, RIGHT_W = 1010, 450
ROW = {"r1": 120, "r2": 270, "r3": 420, "r4": 570}

THEMES = {
    "dark": {
        "bg": "#0d1117", "panel": "#161b22", "text": "#e6edf3",
        "muted": "#8b949e", "line": "#58a6ff", "local": "#39c5bb",
        "navy": "#c8d6e8", "blue": "#58a6ff", "amber": "#f2c163",
        "edge": "#6e7681",
    },
    "light": {
        "bg": "#ffffff", "panel": "#f6f8fa", "text": "#1f2328",
        "muted": "#59636e", "line": "#0969da", "local": "#137e77",
        "navy": "#475467", "blue": "#0969da", "amber": "#9a6700",
        "edge": "#8c959f",
    },
}

# Lucide icon paths, on a 24-unit grid. Inline rather than an icon font so the
# SVG has no runtime dependency and GitHub cannot fail to load it.
ICONS = {
    "monitor": ['<rect width="20" height="14" x="2" y="3" rx="2"/>',
                '<line x1="8" x2="16" y1="21" y2="21"/>',
                '<line x1="12" x2="12" y1="17" y2="21"/>'],
    "app-window": ['<rect width="20" height="16" x="2" y="4" rx="2"/>',
                   '<path d="M2 9h20"/>', '<path d="M6 6h.01"/>',
                   '<path d="M10 6h.01"/>'],
    "bot": ['<path d="M12 8V4H8"/>',
            '<rect width="16" height="12" x="4" y="8" rx="2"/>',
            '<path d="M2 14h2"/>', '<path d="M20 14h2"/>',
            '<path d="M15 13v2"/>', '<path d="M9 13v2"/>'],
    "route": ['<circle cx="6" cy="19" r="3"/>', '<circle cx="18" cy="5" r="3"/>',
              '<path d="M12 19h4.5a3.5 3.5 0 0 0 0-7h-8a3.5 3.5 0 0 1 0-7H12"/>'],
    "globe": ['<circle cx="12" cy="12" r="10"/>', '<path d="M2 12h20"/>',
              '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>'],
    "sparkles": ['<path d="M12 3l1.9 5.8L19.7 10l-5.8 1.9L12 17.7L10.1 11.9'
                 'L4.3 10l5.8-1.2z"/>',
                 '<path d="M19 15v4"/>', '<path d="M17 17h4"/>',
                 '<path d="M5 16v3"/>', '<path d="M3.5 17.5h3"/>'],
    "lock": ['<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>',
             '<path d="M7 11V7a5 5 0 0 1 10 0v4"/>'],
    "mail": ['<rect width="20" height="16" x="2" y="4" rx="2"/>',
             '<path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>'],
    "chart": ['<path d="M3 3v18h18"/>', '<path d="M18 17V9"/>',
              '<path d="M13 17V5"/>', '<path d="M8 17v-3"/>'],
}


def azure_models():
    """Read the model display names out of azure-config.sh.

    Typing them here instead would let the diagram outlive the model list it
    describes, which is the one stale reference a picture hides best.

    Returns:
        The display names, wrapped into at most two subtitle lines.
    """
    path = os.path.join(HERE, "azure-config.sh")
    names = []
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    block = re.search(r"AZURE_MODELS=\((.*?)\n\)", body, re.S)
    if block:
        for line in block.group(1).splitlines():
            # alias|model|version|capacity|display[|format]
            entry = re.search(r'"[^|"]+\|[^|"]+\|[^|"]+\|[^|"]+\|([^|"]+)', line)
            if entry:
                names.append(entry.group(1).strip())
    if not names:
        return "models from azure-config.sh"
    # Wrapped, not truncated: every model the picker offers should be on it.
    lines, current = [], ""
    for name in names:
        candidate = f"{current} · {name}" if current else name
        if len(candidate) > 38 and current:
            lines.append(current)
            current = name
        else:
            current = candidate
    lines.append(current)
    return lines[:2] if len(lines) <= 2 else [lines[0], " · ".join(lines[1:])]


# id: (x, y, width, colour key, icon, title, subtitle)
NODES = {
    "user":    (40, ROW["r1"], 262, "navy", "monitor", "RDP Client",
                "Windows · Mac · Linux"),
    "desktop": (SPINE_X, ROW["r1"], SPINE_W, "navy", "app-window",
                "LXQt Desktop", "Chrome · VS Code · OnlyOffice"),
    "gateway": (SPINE_X, ROW["r2"], SPINE_W, "amber", "bot",
                "OpenClaw Gateway",
                "loopback :18789 · exec, files, browser"),
    "litellm": (SPINE_X, ROW["r3"], SPINE_W, "local", "route",
                "LiteLLM Proxy", "loopback :4000 · OpenAI-compatible"),
    "apache":  (SPINE_X, ROW["r4"], SPINE_W, "local", "globe",
                "Apache", "/var/www/html, loopback only"),
    "secrets": (RIGHT_X, ROW["r1"], RIGHT_W, "blue", "lock",
                "Key Vault", "password · OpenAI key · ACS string"),
    "cost":    (RIGHT_X, ROW["r2"], RIGHT_W, "blue", "chart",
                "Cost Management", "read-only, Cost Management Reader"),
    "bedrock": (RIGHT_X, ROW["r3"], RIGHT_W, "blue", "sparkles",
                "Microsoft Foundry", azure_models()),
    "ses":     (RIGHT_X, ROW["r4"], RIGHT_W, "blue", "mail",
                "ACS Email", "Azure Communication Services"),
}


def _r(nid):
    """Return (left, top, right, bottom, centre-x, centre-y) for a node."""
    x, y, w = NODES[nid][0], NODES[nid][1], NODES[nid][2]
    return x, y, x + w, y + NH, x + w / 2, y + NH / 2


def _h(a, b):
    """Horizontal hop, right edge of a to left edge of b."""
    return f"M{_r(a)[2]},{_r(a)[5]} L{_r(b)[0] - 6},{_r(b)[5]}"


def _v(a, b):
    """Vertical hop between two nodes sharing the spine."""
    x = _r(a)[4]
    return f"M{x},{_r(a)[3]} L{x},{_r(b)[1] - 6}"


def _from_box(b):
    """Horizontal hop leaving the instance boundary for a service beside it.

    Drawn from the boundary rather than from a single node because the claim is
    about the instance's identity, not about which process made the call.
    """
    return f"M{BOX[0] + BOX[2]},{_r(b)[5]} L{_r(b)[0] - 6},{_r(b)[5]}"


def _into_box(a):
    """Horizontal hop from a service back into the instance boundary.

    Used for the secrets read, which travels the other way: custom_data.sh
    pulls the password, the OpenAI key and the ACS string at first boot.
    """
    return f"M{_r(a)[0]},{_r(a)[5]} L{BOX[0] + BOX[2] + 6},{_r(a)[5]}"


def _skip_down(a, b):
    """Left, down, right: the gateway reaching a node further down the spine.

    Turns down in the gutter inside the boundary rather than running straight
    through whatever sits between them. The gateway publishes pages to Apache;
    routing that hop through LiteLLM would draw a relationship that does not
    exist.
    """
    gutter = BOX[0] + 20
    return (f"M{_r(a)[0]},{_r(a)[5]} H{gutter} V{_r(b)[5]} "
            f"H{_r(b)[0] - 6}")


# id: (path, colour key, label, label_x, label_y, anchor)
#
# Every edge is a straight horizontal or vertical run at its own row, so
# nothing crosses anything. That is a layout constraint, not luck: each
# right-hand service sits on the row of whatever reaches it.
EDGES = {
    # Centred in the gap between the client and the boundary, above the
    # arrow; the boundary's caption starts inside the box, so they never meet.
    "e_rdp":     (_h("user", "desktop"), "line", "RDP :3389",
                  (_r("user")[2] + BOX[0]) / 2, ROW["r1"] - 14, "middle"),
    "e_ui":      (_v("desktop", "gateway"), "local", "localhost:18789",
                  _r("desktop")[4] + 14, ROW["r1"] + NH + 28, "start"),
    "e_model":   (_v("gateway", "litellm"), "local", "OpenAI API call",
                  _r("gateway")[4] + 14, ROW["r2"] + NH + 28, "start"),
    "e_publish": (_skip_down("gateway", "apache"), "local",
                  "agent publishes pages", _r("apache")[0] + 4,
                  ROW["r4"] - 14, "start"),
    # Arrives beside the desktop only because that is the row; the label
    # names the real reader, custom_data.sh, so it does not read as the desktop.
    "e_secrets": (_into_box("secrets"), "blue", "custom_data.sh, first boot",
                  BOX[0] + BOX[2] + 14, ROW["r1"] - 14, "start"),
    "e_cost":    (_from_box("cost"), "blue", "az costmanagement",
                  BOX[0] + BOX[2] + 14, ROW["r2"] - 14, "start"),
    # From LiteLLM itself, not the boundary: it is the one process that
    # calls Microsoft Foundry, and it sits on that row.
    "e_bedrock": (_h("litellm", "bedrock"), "blue", "chat completions",
                  BOX[0] + BOX[2] + 14, ROW["r3"] - 14, "start"),
    # Solid: 01-core always creates ACS. custom_data.sh only installs
    # acs-mail when the email secret exists, but on Azure it always does.
    "e_ses":     (_from_box("ses"), "blue", "acs-mail",
                  BOX[0] + BOX[2] + 14, ROW["r4"] - 14, "start"),
}

FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"

ALT = ("An RDP client reaches an LXQt desktop on one Azure VM, where the "
       "OpenClaw gateway calls a loopback LiteLLM proxy that calls Microsoft Foundry "
       "and publishes pages to a loopback Apache. With the VM's managed "
       "identity, custom_data.sh reads Key Vault at first boot and the agent "
       "reads Cost Management; email goes through Azure Communication Services")

# Two lines, because on Azure the identity story splits: the managed identity
# covers Key Vault and Cost Management only. Claiming more would be the one
# false thing on the diagram.
FOOTER = ("Key Vault and Cost Management calls use the VM's managed identity — "
          "no Azure credentials for them on disk.",
          "Microsoft Foundry and ACS use an API key and a connection string, read from "
          "Key Vault at boot into /opt/openclaw.")


def node_svg(nid, t):
    """Render one service box: rounded panel, icon, title, subtitle."""
    x, y, w, key, icon, title, sub = NODES[nid]
    colour = t[key]
    # A list subtitle is two lines (the model list); lift the title to fit.
    subs = sub if isinstance(sub, list) else [sub]
    lift = 10 * (len(subs) - 1)
    scale = 1.25
    isz = 24 * scale
    ix, iy = x + 20, y + (NH - isz) / 2
    tx = x + 20 + isz + 14
    return "".join([
        f'<rect x="{x}" y="{y}" width="{w}" height="{NH}" rx="10" ry="10" '
        f'fill="{t["panel"]}" stroke="{colour}" stroke-width="2"/>',
        f'<g transform="translate({ix},{iy}) scale({scale})" fill="none" '
        f'stroke="{colour}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">' + "".join(ICONS[icon]) + "</g>",
        f'<text x="{tx}" y="{y + NH / 2 - 4 - lift}" font-family="{FONT}" '
        f'font-size="{TITLE_PX}" font-weight="600" '
        f'fill="{t["text"]}">{title}</text>',
    ] + [
        f'<text x="{tx}" y="{y + NH / 2 + 22 - lift + i * 21}" font-family="{FONT}" '
        f'font-size="{SUB_PX}" fill="{t["muted"]}">{line}</text>'
        for i, line in enumerate(subs)
    ])


def edge_svg(eid, t):
    """Render one arrow plus its label."""
    d, key, label, lx, ly, anchor, *rest = EDGES[eid]
    colour = t[key]
    # Optional seventh field: True draws the edge dashed, for optional paths.
    dash = ' stroke-dasharray="7 5"' if rest and rest[0] else ""
    out = (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2"{dash} '
           f'marker-end="url(#a_{eid})"/>')
    if label:
        out += (f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" '
                f'font-family="{FONT}" font-size="{EDGE_PX}" font-weight="600" '
                f'fill="{colour}">{label}</text>')
    return out


def boundary_svg(t):
    """The dashed Azure VM boundary, labelled at the top-left.

    Dashed because it is a scope line rather than a thing the agent talks to;
    a solid box at this size reads as another service.
    """
    x, y, w, h = BOX
    return "".join([
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" ry="14" '
        f'fill="none" stroke="{t["edge"]}" stroke-width="2" '
        f'stroke-dasharray="9 6"/>',
        f'<text x="{SPINE_X + 10}" y="{y + 30}" font-family="{FONT}" font-size="19" '
        f'font-weight="600" fill="{t["muted"]}">'
        f'Azure VM · openclaw-host · D4s_v3 · Ubuntu 24.04</text>',
    ])


def build(t):
    """Assemble the diagram for one theme."""
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" role="img" aria-label="{ALT}">', "<defs>"]
    # One marker per edge: a shared marker cannot carry per-edge colour.
    for eid, spec in EDGES.items():
        out.append(
            f'<marker id="a_{eid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{t[spec[1]]}"/></marker>')
    out.append("</defs>")
    out.append(f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>')
    out.append(boundary_svg(t))
    for eid in EDGES:
        out.append(edge_svg(eid, t))
    for nid in NODES:
        out.append(node_svg(nid, t))
    for i, line in enumerate(FOOTER):
        out.append(f'<text x="{BOX[0]}" y="{H - 48 + i * 26}" font-family="{FONT}" '
                   f'font-size="18" fill="{t["muted"]}">{line}</text>')
    out.append("</svg>")
    return "".join(out)


def main():
    """Write one SVG per theme beside this script."""
    for name, theme in THEMES.items():
        path = os.path.join(HERE, f"architecture-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(build(theme))
        print(f"  architecture-{name}.svg")


if __name__ == "__main__":
    main()
