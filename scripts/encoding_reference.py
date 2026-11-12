#!/usr/bin/env python3
"""Lumora's encoder settings reference: render it to documentation pages, or check it against installed encoders.

  python3 scripts/encoding_reference.py render   # docs/encoding/data/*.json -> docs/encoding/<key>.md
  python3 scripts/encoding_reference.py check    # flags in the installed encoders' help vs the reference

The data (one JSON file per encoder or tool group) lists every option the installed tool's own help prints, with its
values and default, a plain-English description, effects on quality/speed/size, HDR relevance, recommendations by
content type and goal with sources, and how Lumora uses it. `check` exits 0 and prints a report; options that appear
in a newer encoder's help but not in the reference are listed so the reference can be updated.
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "docs", "encoding", "data")
OUT = os.path.join(ROOT, "docs", "encoding")
ORDER = ["svtav1", "x265", "vvenc", "aomenc", "avm", "videotoolbox", "hdrtools"]
HELP = {  # key -> (binary, help argument)
    "svtav1": ("SvtAv1EncApp", "--help"), "aomenc": ("aomenc", "--help"), "x265": ("x265", "--fullhelp"),
    "vvenc": ("vvencapp", "--fullhelp"),
}
CATEGORIES = ["Input and output", "Rate control", "Speed and presets", "GOP and keyframes", "Psychovisual and tuning",
              "Film grain and noise", "Color and HDR", "Analysis and motion search", "Partitioning and transforms",
              "In-loop filters", "Threading and performance", "Logging and statistics", "Other"]


def load(key):
    with open(os.path.join(DATA, f"{key}.json"), encoding="utf-8") as f:
        return json.load(f)


def cell(v):
    """Text safe for a Markdown table cell."""
    if v is None:
        return ""
    if isinstance(v, (list, tuple)):
        v = ", ".join(str(x) for x in v)
    return str(v).replace("|", "\\|").replace("\n", " ").strip()


def slug(s):
    return re.sub(r"[^a-z0-9-]+", "-", s.lower().strip("-")).strip("-") or "option"


def link(src):
    src = (src or "").strip()
    if re.match(r"^https?://", src):
        return f"[source]({src})"
    if src.startswith(("Lumora/", "scripts/", "docs/")):
        return f"[{src}](https://github.com/info-moed/Lumora/blob/main/{src})"
    return cell(src)


def table(rows, cols, headers=None):
    if not rows:
        return ""
    out = ["| " + " | ".join(headers or cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        out.append("| " + " | ".join(cell(r.get(c)) for c in cols) + " |")
    return "\n".join(out) + "\n"


def generic(value, depth=3):
    """Render extra top-level fields (code tables, tool lists, version notes) without knowing their shape."""
    if isinstance(value, list) and value and all(isinstance(x, dict) for x in value):
        cols = list(dict.fromkeys(k for x in value for k in x.keys()))
        simple = [c for c in cols if all(not isinstance(x.get(c), (dict, list)) or isinstance(x.get(c), list) for x in value)]
        return table(value, simple)
    if isinstance(value, dict):
        parts = []
        for k, v in value.items():
            parts.append(f"{'#' * depth} {k}\n\n{generic(v, min(depth + 1, 6))}")
        return "\n".join(parts)
    if isinstance(value, list):
        return "\n".join(f"- {cell(x)}" for x in value) + "\n"
    return f"{value}\n"


FLAG = re.compile(r"(?<![`\w/-])(--?[A-Za-z][\w-]*(?:=[^\s,;)`]+)?)(?![`\w])")


def code_flags(text):
    """Show command-line flags in prose as code, so they're copyable and never typeset as dashes."""
    if not isinstance(text, str):
        return text
    parts = re.split(r"(`[^`]*`)", text)
    return "".join(p if p.startswith("`") else FLAG.sub(lambda m: f"`{m.group(1)}`" if m.group(1).startswith("--")
                                                         or re.match(r"^-[A-Za-z]$", m.group(1)) else m.group(1), p)
                   for p in parts)


def render_page(d, nav_order):
    L = []
    L.append(f"---\ntitle: {d['name']}\nparent: Encoding settings\nnav_order: {nav_order}\n---\n")
    L.append("{% raw %}\n")
    L.append(f"# {d['name']}\n")
    meta = [f"**Documented version:** {d.get('versionDocumented', '?')}", f"**Codec:** {d.get('codec', '?')}",
            f"**License:** {d.get('license', '?')}"]
    if d.get("homepage"):
        meta.append(f"**Homepage:** <{d['homepage']}>")
    if d.get("homebrew"):
        meta.append(f"**Homebrew:** [`{d['homebrew']}`](https://formulae.brew.sh/formula/{d['homebrew']})")
    L.append(" · ".join(meta) + "\n")
    L.append(f"{code_flags(d.get('summary', ''))}\n")
    if d.get("bitDepths") or d.get("chroma"):
        L.append(f"**Bit depths:** {cell(d.get('bitDepths'))} · **Chroma:** {cell(d.get('chroma'))}\n")
    L.append("Machine-readable data: [`data/" + d["key"] + ".json`](data/" + d["key"] + ".json). Every option below is "
             "listed in the installed tool's own help; descriptions are written for this reference, and each "
             "recommendation links to its source.\n")
    L.append("**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · "
             "[Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · "
             "[Sources](#sources)\n")

    hdr = d.get("hdr") or {}
    L.append("## HDR\n")
    if hdr.get("summary"):
        L.append(f"{code_flags(hdr['summary'])}\n")
    if hdr.get("flags"):
        L.append("**Flags involved:** " + ", ".join(f"`{f}`" for f in hdr["flags"]) + "\n")
    if hdr.get("example"):
        L.append("**Example (HDR10):**\n\n```bash\n" + hdr["example"].strip() + "\n```\n")
    if hdr.get("pitfalls"):
        L.append("**Pitfalls:**\n\n" + "\n".join(f"- {code_flags(p)}" for p in hdr["pitfalls"]) + "\n")

    L.append("## Presets\n")
    L.append(table([{**r, "notes": code_flags(r.get("notes"))} for r in d.get("presets") or []], ["value", "speed", "notes"], ["Preset", "Speed", "Notes"]) or "None.\n")
    L.append("## Rate control\n")
    L.append(table([{**r, "notes": code_flags(r.get("notes"))} for r in d.get("rateControl") or []], ["mode", "flags", "notes"], ["Mode", "Flags", "Notes"]) or "None.\n")

    L.append("## Recipes\n")
    for r in d.get("recipes") or []:
        L.append(f"### {r.get('name', 'Recipe')}\n")
        bits = [f"**Goal:** {r['goal']}" if r.get("goal") else "", f"**Content:** {r['content']}" if r.get("content") else ""]
        L.append(" · ".join(b for b in bits if b) + "\n")
        if r.get("args"):
            L.append("```bash\n" + str(r["args"]).strip() + "\n```\n")
        if r.get("why"):
            L.append(f"{code_flags(r['why'])}\n")
        if r.get("sources"):
            L.append("Sources: " + ", ".join(link(s) for s in r["sources"]) + "\n")

    for k, v in d.items():
        if k in ("key", "name", "binary", "codec", "versionDocumented", "summary", "license", "homepage", "homebrew",
                 "bitDepths", "chroma", "hdr", "presets", "rateControl", "options", "recipes", "sources"):
            continue
        title = re.sub(r"(?<!^)(?=[A-Z])", " ", k).capitalize()
        L.append(f"## {title}\n\n{generic(v)}")

    opts = d.get("options") or []
    by_cat = {}
    for o in opts:
        by_cat.setdefault(o.get("category") if o.get("category") in CATEGORIES else "Other", []).append(o)
    L.append(f"## All options\n\n{len(opts)} options. Click a flag for details. **HDR** marks options that matter for "
             "HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.\n")
    for cat in CATEGORIES:
        if cat not in by_cat:
            continue
        L.append(f"### {cat}\n")
        L.append("| Flag | Values | Default | What it does | HDR | Lumora |\n|---|---|---|---|---|---|")
        for o in by_cat[cat]:
            first = re.split(r"(?<=[.!?])\s", o.get("description") or "", maxsplit=1)[0]
            L.append(f"| [`{cell(o['flag'])}`](#{slug(o['flag'])}) | {cell(o.get('values'))} | {cell(o.get('default'))} | "
                     f"{cell(code_flags(first))} | {'✓' if o.get('hdr') else ''} | {'✓' if o.get('lumora') else ''} |")
        L.append("")

    L.append("## Options in detail\n")
    for cat in CATEGORIES:
        if cat not in by_cat:
            continue
        L.append(f"### {cat}\n")
        for o in by_cat[cat]:
            L.append(f'<a id="{slug(o["flag"])}"></a>\n')
            aliases = f" (also {', '.join(f'`{a}`' for a in o['aliases'])})" if o.get("aliases") else ""
            L.append(f"#### `{o['flag']}`{aliases}\n")
            facts = [f"**Type:** {cell(o.get('type'))}", f"**Values:** {cell(o.get('values'))}",
                     f"**Default:** {cell(o.get('default'))}"]
            if o.get("hdr"):
                facts.append("**HDR-relevant**")
            if o.get("advanced"):
                facts.append("advanced")
            L.append(" · ".join(facts) + "\n")
            if o.get("description"):
                L.append(f"{code_flags(o['description'])}\n")
            e = o.get("effect") or {}
            if any(e.get(k) not in (None, "", "none") for k in ("quality", "speed", "size")):
                L.append(f"**Effect:** quality {cell(e.get('quality'))} · speed {cell(e.get('speed'))} · "
                         f"size {cell(e.get('size'))}\n")
            recs = o.get("recommendations") or []
            if recs:
                L.append("| For | Value | Why | Source |\n|---|---|---|---|")
                for r in recs:
                    L.append(f"| {cell(r.get('for'))} | `{cell(r.get('value'))}` | {cell(code_flags(r.get('why')))} | {link(r.get('source'))} |")
                L.append("")
            if o.get("lumora"):
                L.append(f"**In Lumora:** {code_flags(o['lumora'])}\n")
            if o.get("notes"):
                L.append(f"**Notes:** {code_flags(o['notes'])}\n")

    L.append("## Sources\n")
    for s in d.get("sources") or []:
        if isinstance(s, dict):
            L.append(f"- [{cell(s.get('title') or s.get('url'))}]({s.get('url')})")
        else:
            L.append(f"- {link(s)}")
    L.append("\n{% endraw %}\n")
    return "\n".join(L)


def render():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for i, key in enumerate(ORDER):
        d = load(key)
        with open(os.path.join(OUT, f"{key}.md"), "w", encoding="utf-8") as f:
            f.write(render_page(d, i + 2))
        opts = d.get("options") or []
        rows.append((d["name"], key, d.get("versionDocumented", "?"), len(opts),
                     sum(len(o.get("recommendations") or []) for o in opts), len(d.get("recipes") or [])))
    print("\n".join(f"{n}: {o} options, {r} recommendations, {c} recipes -> docs/encoding/{k}.md" for n, k, v, o, r, c in rows))


def help_flags(text):
    """Options declared in a help listing: flags in the option column at the start of a line, not flags merely
    mentioned inside another option's description."""
    found = set()
    text = text.replace("--[no-]-", "--").replace("--[no-]", "--")   # x265 prints one as "--[no-]-hrd-concat"
    for line in text.splitlines():
        found.update(m.group(1) for m in re.finditer(r"(?<![\w-])(--[a-zA-Z][\w-]*)", line) if m.start() < 48)
    return found


def check():
    report, drift = [], False
    for key, (binary, arg) in HELP.items():
        try:
            out = subprocess.run([binary, arg], capture_output=True, text=True, timeout=30)
        except FileNotFoundError:
            report.append(f"  {binary}: not installed, skipped")
            continue
        current = help_flags(out.stdout + out.stderr)
        documented = {o["flag"] for o in load(key)["options"]} | {a for o in load(key)["options"] for a in o.get("aliases") or []}
        new = sorted(f for f in current - documented if len(f) > 3)
        def present(f):
            return f in current or (f.startswith("--no-") and "--" + f[5:] in current)
        gone = sorted(f for f in documented if f.startswith("--") and not present(f))
        if new or gone:
            drift = True
            report.append(f"  {binary}: {len(new)} option(s) in --help not in the reference: {' '.join(new[:12])}"
                          + (" …" if len(new) > 12 else ""))
            if gone:
                report.append(f"  {binary}: {len(gone)} documented option(s) no longer in --help: {' '.join(gone[:12])}"
                              + (" …" if len(gone) > 12 else ""))
        else:
            report.append(f"  {binary}: reference matches --help ({len(documented)} options)")
    print("Encoder settings reference vs installed encoders:")
    print("\n".join(report))
    if drift:
        print("  -> Update docs/encoding/data/*.json (see docs/encoding/index.md), then: python3 scripts/encoding_reference.py render")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "render":
        render()
    elif cmd == "check":
        sys.exit(check())
    else:
        print(__doc__)
        sys.exit(2)
