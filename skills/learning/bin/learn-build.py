#!/usr/bin/env python3
"""Build .learning/ index + graphs from its markdown notes. Deterministic, no LLM.

usage: learn-build.py [LEARNING_DIR] [--migrate]

Outputs
  INDEX.md                     grep target, one row per note
  graph.json                   CONTRACT 2: {nodes:[{id,title,type,tags,path}], edges:[{from,to,rel}]}
                               directed; prerequisites:[x] on A -> {from:x,to:A,rel:prerequisite}
  graphify-out/graph.json      graphify-native (networkx node-link) for `graphify query --graph`
  graphify-out/graph.html      optional viz (graphify installed)

Frontmatter CONTRACT 1 (every note): id, title, type(concept|guide|reference|moc), tags[>=1],
optional prerequisites[ids], related[ids], summary. Relations reference ids, never paths.
--migrate backfills: id=filename stem, title=H1, type by location, tags by dir, related paths->ids,
body [[modules/x]] -> [[x]].
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

TYPES = {"concept", "guide", "reference", "moc"}
REQUIRED = ("id", "title", "type", "tags")
GENERATED = {"INDEX.md"}
LINK_RE = re.compile(r"\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]")
FM_RE = re.compile(r"\A---\n(.*?)\n---\n?", re.S)
LIST_RE = re.compile(r"^(\w+):\s*\[(.*)\]\s*$")
KV_RE = re.compile(r"^(\w+):\s*(.*)$")
LIST_KEYS = {"tags", "related", "prerequisites"}


def parse_frontmatter(text: str) -> tuple[dict, str, str]:
    """-> (fm dict, raw frontmatter block text or '', body)"""
    m = FM_RE.match(text)
    if not m:
        return {}, "", text
    fm: dict = {}
    for line in m.group(1).splitlines():
        lm = LIST_RE.match(line)
        if lm:
            fm[lm.group(1)] = [x.strip().strip("'\"") for x in lm.group(2).split(",") if x.strip()]
            continue
        km = KV_RE.match(line)
        if km:
            v = km.group(2).strip().strip("'\"")
            fm[km.group(1)] = [x.strip() for x in v.split(",") if x.strip()] if km.group(1) in LIST_KEYS and v else v
    for k in LIST_KEYS:
        if k in fm and not isinstance(fm[k], list):
            fm[k] = [fm[k]] if fm[k] else []
    return fm, m.group(0), text[m.end():]


def dump_frontmatter(fm: dict) -> str:
    order = ["id", "title", "type", "tags", "summary", "prerequisites", "related"]
    keys = [k for k in order if k in fm] + [k for k in fm if k not in order]
    out = ["---"]
    for k in keys:
        v = fm[k]
        out.append(f"{k}: [{', '.join(str(x) for x in v)}]" if isinstance(v, list) else f"{k}: {v}")
    out.append("---")
    return "\n".join(out) + "\n"


def kebab(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "note"


def default_type(rel: str) -> str:
    name = Path(rel).name
    if name in ("DECISIONS.md", "SESSIONS.md"):
        return "reference"
    if name == "CODEBASE.md":
        return "guide"
    return "concept"


def h1(body: str) -> str | None:
    return next((l[2:].strip() for l in body.splitlines() if l.startswith("# ")), None)


class Build:
    def __init__(self, root: Path, migrate: bool = False):
        self.root = root.resolve()
        self.migrate = migrate
        self.problems: list[str] = []
        self.migrated: list[str] = []

    def notes(self) -> list[Path]:
        return sorted(p for p in self.root.rglob("*.md")
                      if "graphify-out" not in p.parts and "vault" not in p.parts and p.name not in GENERATED)

    def load(self, p: Path) -> tuple[dict, str]:
        rel = p.relative_to(self.root).as_posix()
        text = p.read_text(encoding="utf-8", errors="replace")
        fm, raw, body = parse_frontmatter(text)
        stem_id = kebab(p.stem)
        if self.migrate:
            new = dict(fm)
            new.setdefault("id", stem_id)
            new.setdefault("title", h1(body) or p.stem)
            new.setdefault("type", default_type(rel))
            if not new.get("tags"):
                new["tags"] = [kebab(p.parent.name)] if p.parent != self.root else [default_type(rel) if default_type(rel) != "concept" else "codebase"]
            new["related"] = [kebab(Path(r).stem) for r in new.get("related", [])]
            new.setdefault("prerequisites", [])
            new_body = LINK_RE.sub(lambda m: f"[[{kebab(Path(m.group(1).strip()).stem)}]]" if kebab(Path(m.group(1).strip()).stem) != m.group(1) else m.group(0), body)
            new_text = dump_frontmatter(new) + new_body
            if new_text != text:
                p.write_text(new_text, encoding="utf-8")
                self.migrated.append(rel)
            fm, body = new, new_body
        missing = [k for k in REQUIRED if not fm.get(k)]
        if missing:
            self.problems.append(f"{rel}: missing {','.join(missing)}")
        if fm.get("type") and fm["type"] not in TYPES:
            self.problems.append(f"{rel}: bad type {fm['type']!r}")
        fm.setdefault("id", stem_id)
        fm.setdefault("title", h1(body) or p.stem)
        fm.setdefault("type", default_type(rel))
        fm.setdefault("tags", [])
        fm.setdefault("related", [])
        fm.setdefault("prerequisites", [])
        fm["_path"] = rel
        fm["_body"] = body
        return fm, rel

    def run(self) -> dict:
        notes = [self.load(p) for p in self.notes()]
        by_id: dict[str, dict] = {}
        for fm, rel in notes:
            if fm["id"] in by_id:
                self.problems.append(f"{rel}: duplicate id {fm['id']!r} (also {by_id[fm['id']]['_path']})")
                continue
            by_id[fm["id"]] = fm
        known = set(by_id)
        stem_to_id = {Path(fm["_path"]).stem: i for i, fm in by_id.items()}

        def resolve(raw: str) -> str:
            raw = raw.strip().removesuffix(".md")
            if raw in known:
                return raw
            return stem_to_id.get(Path(raw).stem, kebab(Path(raw).stem))  # unknown -> dangling id

        # ---- CONTRACT 2 graph
        c_nodes = [{"id": i, "title": fm["title"], "type": fm["type"], "tags": sorted(fm["tags"]), "path": fm["_path"]}
                   for i, fm in sorted(by_id.items())]
        c_edges: set[tuple[str, str, str]] = set()
        for i, fm in by_id.items():
            for pre in fm["prerequisites"]:
                c_edges.add((resolve(pre), i, "prerequisite"))
            for r in fm["related"]:
                c_edges.add((i, resolve(r), "related"))
            for m in LINK_RE.finditer(fm["_body"]):
                t = resolve(m.group(1))
                if t != i:
                    c_edges.add((i, t, "related"))
        c_edges = {e for e in c_edges if e[0] != e[1]}
        contract = {"nodes": c_nodes,
                    "edges": [{"from": a, "to": b, "rel": r} for a, b, r in sorted(c_edges)]}
        (self.root / "graph.json").write_text(json.dumps(contract, indent=1) + "\n", encoding="utf-8")

        # ---- INDEX.md
        lines = ["# .learning index", "",
                 "grep me. then read only matched notes. relations: `learn.sh find <terms>` (graph BFS).", "",
                 "| id | type | summary | tags |", "|---|---|---|---|"]
        for i, fm in sorted(by_id.items()):
            lines.append(f"| {i} | {fm['type']} | {fm.get('summary') or fm['title']} | {' '.join(sorted(fm['tags']))} |")
        (self.root / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

        # ---- graphify-native graph (richer: tag nodes, decision/session nodes)
        nodes: list[dict] = []
        edges: list[dict] = []
        seen: set[str] = set()

        def add_node(nid: str, label: str, src: str, ftype: str = "document", **extra) -> None:
            if nid not in seen:
                seen.add(nid)
                nodes.append({"id": nid, "label": label, "file_type": ftype, "source_file": src, **extra})

        def add_edge(s: str, t: str, rel: str, src: str) -> None:
            if s != t and s in seen and t in seen:
                edges.append({"source": s, "target": t, "relation": rel, "confidence": "EXTRACTED", "source_file": src})

        for i, fm in by_id.items():
            add_node(i, fm["title"], fm["_path"], summary=fm.get("summary", ""), tags=fm["tags"], note_type=fm["type"])
        for i, fm in by_id.items():
            for t in fm["tags"]:
                add_node(f"tag:{t}", t, fm["_path"], "rationale")
                add_edge(i, f"tag:{t}", "tagged", fm["_path"])
        for a, b, r in sorted(c_edges):
            add_edge(a, b, r, by_id[a]["_path"] if a in by_id else by_id[b]["_path"])
        for i, fm in by_id.items():
            name = Path(fm["_path"]).name
            if name == "DECISIONS.md":
                for n, line in enumerate(fm["_body"].splitlines(), 1):
                    dm = re.match(r"^- (D-\d+)\s+(\S+)\s+(.*)$", line)
                    if dm:
                        add_node(dm.group(1), f"{dm.group(1)} {LINK_RE.sub(lambda x: x.group(1), dm.group(3))[:120]}",
                                 fm["_path"], "rationale", source_location=f"L{n}", date=dm.group(2))
                        add_edge(dm.group(1), i, "listed_in", fm["_path"])
                        for lm in LINK_RE.finditer(line):
                            add_edge(dm.group(1), resolve(lm.group(1)), "decides", fm["_path"])
            if name == "SESSIONS.md":
                cur = None
                for n, line in enumerate(fm["_body"].splitlines(), 1):
                    sm = re.match(r"^## (S-\d+)\s+(\S+)\s+(.*)$", line)
                    if sm:
                        cur = sm.group(1)
                        add_node(cur, f"{cur} {sm.group(3)[:100]}", fm["_path"], "rationale",
                                 source_location=f"L{n}", date=sm.group(2))
                        add_edge(cur, i, "listed_in", fm["_path"])
                        continue
                    if cur:
                        for lm in LINK_RE.finditer(line):
                            add_edge(cur, resolve(lm.group(1)), "touched", fm["_path"])
                        for dm in re.finditer(r"\b(D-\d+)\b", line):
                            add_edge(cur, dm.group(1), "made", fm["_path"])

        out = self.root / "graphify-out"
        out.mkdir(exist_ok=True)
        extraction = {"nodes": nodes, "edges": edges, "hyperedges": []}
        try:
            from graphify.build import build_from_json
            from graphify.cluster import cluster
            from graphify.export import to_html, to_json
            G = build_from_json(extraction, directed=True)
            comms = cluster(G)
            to_json(G, comms, str(out / "graph.json"))
            try:
                to_html(G, comms, str(out / "graph.html"))
            except Exception:
                pass
            ncomm = len(comms)
        except ImportError:
            (out / "graph.json").write_text(json.dumps({"directed": True, "multigraph": False, "graph": {},
                                                        "nodes": nodes, "links": edges}), encoding="utf-8")
            ncomm = -1
        return {"notes": len(by_id), "nodes": len(c_nodes), "edges": len(c_edges),
                "native_nodes": len(nodes), "native_edges": len(edges), "communities": ncomm,
                "problems": self.problems, "migrated": self.migrated}


def main(argv: list[str]) -> int:
    migrate = "--migrate" in argv
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0] if args else ".learning")
    if not root.is_dir():
        print(f"learn-build: no dir {root}", file=sys.stderr)
        return 1
    r = Build(root, migrate).run()
    for m in r["migrated"]:
        print(f"migrated: {m}")
    for p in r["problems"]:
        print(f"problem: {p}", file=sys.stderr)
    comm = "" if r["communities"] < 0 else f" communities={r['communities']}"
    print(f"learn-build: notes={r['notes']} graph.json nodes={r['nodes']} edges={r['edges']} | "
          f"native nodes={r['native_nodes']} edges={r['native_edges']}{comm}"
          + (f" | problems={len(r['problems'])} (run --migrate)" if r["problems"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
