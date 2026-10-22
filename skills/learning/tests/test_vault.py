"""Tests for learn-build.py (contract 1/2) + learn-vault.py (contract 3). stdlib unittest, no LLM.
run: python3 -m unittest discover -s ~/.claude/skills/learning/tests
"""
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), BIN / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


build = load("learn-build")
vault = load("learn-vault")

NOTE = "---\nid: {id}\ntitle: {title}\ntype: concept\ntags: [t]\nprerequisites: [{pre}]\nrelated: [{rel}]\n---\n# {title}\nbody {id}\n"


def fixture(root: Path) -> None:
    # a <-> b prerequisite cycle; c -> ghost (forward ref, dangling); d orphan; e no relations, tagged
    m = root / "modules"
    m.mkdir(parents=True)
    (m / "a.md").write_text(NOTE.format(id="a", title="A", pre="b", rel=""))
    (m / "b.md").write_text(NOTE.format(id="b", title="B", pre="a", rel=""))
    (m / "c.md").write_text(NOTE.format(id="c", title="C", pre="", rel="ghost"))
    (m / "d.md").write_text(NOTE.format(id="d", title="D", pre="", rel=""))
    (m / "e.md").write_text(NOTE.format(id="e", title="E", pre="", rel="a"))


def tree_hash(d: Path) -> str:
    h = hashlib.sha256()
    for p in sorted(x for x in d.rglob("*") if x.is_file()):
        h.update(p.relative_to(d).as_posix().encode())
        h.update(p.read_bytes())
    return h.hexdigest()


class VaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / ".learning"
        fixture(self.root)
        build.Build(self.root).run()

    def test_graph_contract(self):
        g = json.loads((self.root / "graph.json").read_text())
        self.assertEqual({n["id"] for n in g["nodes"]}, {"a", "b", "c", "d", "e"})
        self.assertTrue(all(set(n) == {"id", "title", "type", "tags", "path"} for n in g["nodes"]))
        edges = {(e["from"], e["to"], e["rel"]) for e in g["edges"]}
        # prerequisites:[b] on a => b -> a (learning order)
        self.assertIn(("b", "a", "prerequisite"), edges)
        self.assertIn(("a", "b", "prerequisite"), edges)
        self.assertIn(("c", "ghost", "related"), edges)  # dangling kept for the exporter to report
        self.assertTrue(all(e["rel"] in ("prerequisite", "related") for e in g["edges"]))

    def test_report_catches_dangling_orphan_cycle(self):
        r = vault.export(self.root, self.root / "vault")
        self.assertEqual(r["dangling"], ["ghost"])
        self.assertEqual(r["orphans"], ["d"])
        self.assertEqual(r["cycles"], [["a", "b"]])
        self.assertEqual(r["nodes"], 5)

    def test_idempotent(self):
        out = self.root / "vault"
        vault.export(self.root, out)
        h1 = tree_hash(out)
        vault.export(self.root, out)
        self.assertEqual(h1, tree_hash(out))

    def test_note_without_relations_exports_valid(self):
        out = self.root / "vault"
        vault.export(self.root, out)
        txt = (out / "concept" / "d.md").read_text()
        fm, body = vault.split_note(txt)
        self.assertIn("id: d", fm)
        self.assertIn("cssclass: generated", fm)
        self.assertIn("body d", body)
        self.assertNotIn("## Prerequisites", txt)
        self.assertNotIn("## Related", txt)
        # a has incoming prerequisite b, and e relates to a (symmetric)
        a = (out / "concept" / "a.md").read_text()
        self.assertIn("## Prerequisites\n- [[b]]", a)
        self.assertIn("## Related\n- [[e]]", a)
        self.assertNotIn("Leads to", a)
        idx = (out / "index.md").read_text()
        self.assertIn("## t\n### concept\n- [[a]] A", idx)

    def test_refuses_to_wipe_foreign_dir(self):
        out = self.tmp / "mine"
        out.mkdir()
        (out / "keep.txt").write_text("x")
        with self.assertRaises(SystemExit):
            vault.export(self.root, out)
        self.assertTrue((out / "keep.txt").exists())

    def test_migrate_backfills(self):
        legacy = self.root / "modules" / "legacy.md"
        legacy.write_text("---\ntitle: Legacy\nsummary: s\ntags: [x]\nrelated: [modules/a]\n---\n# Legacy\nsee [[modules/b]]\n")
        r = build.Build(self.root, migrate=True).run()
        self.assertIn("modules/legacy.md", r["migrated"])
        fm, _, body = build.parse_frontmatter(legacy.read_text())
        self.assertEqual(fm["id"], "legacy")
        self.assertEqual(fm["type"], "concept")
        self.assertEqual(fm["related"], ["a"])
        self.assertIn("[[b]]", body)
        self.assertEqual(r["problems"], [])


if __name__ == "__main__":
    unittest.main()
