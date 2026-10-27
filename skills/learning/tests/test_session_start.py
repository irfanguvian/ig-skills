"""hooks/learning-session-start.sh: short pointer (< 2 KB, Claude Code previews only the first 2 KB).

Hermetic: HOME and TMPDIR in a tmp tree, real metrics never written.
"""
import os, shutil, subprocess, tempfile, unittest, json
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
LEARN = SKILL / "bin" / "learn.sh"
HOOK = Path(os.environ.get("LEARNING_HOOKS_DIR", SKILL / "hooks")) / "learning-session-start.sh"
NOTE = "---\nid: {id}\ntitle: {id}\ntype: {type}\ntags: [x]\nsummary: {summary}\n---\n# {id}\nbody\n"
SID = "sid:abcd1234"
SLUG = "s" * 150  # header past 140 chars: the slug is cut, the sid: token stays
NEXT = "next: " + "n" * 250


class SessionStart(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.repo = self.tmp / "repo"
        self.L = self.repo / ".learning"
        (self.L / "modules").mkdir(parents=True)
        self.home = self.tmp / "h"
        (self.home / ".claude" / "skills").mkdir(parents=True)
        (self.home / ".claude" / "skills" / "learning").symlink_to(SKILL)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LEARNING_", "TB_", "GIT_"))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.tmp))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def build(self, sessions):
        # 8 concept + 1 guide + 30 reference rows: the old INDEX head alone was ~3.5 KB of this
        rows = [("c%d" % i, "concept") for i in range(8)] + [("g0", "guide")] + [("r%02d" % i, "reference") for i in range(30)]
        for nid, typ in rows:
            (self.L / "modules" / f"{nid}.md").write_text(NOTE.format(id=nid, type=typ, summary="row summary " + "w" * 100))
        (self.L / "SESSIONS.md").write_text("---\nid: sessions\ntitle: Sessions\ntype: reference\ntags: [reference]\n---\n# Sessions\n" + sessions)
        subprocess.run(["bash", str(LEARN), "build", str(self.L)], capture_output=True, text=True, check=True)

    def run_hook(self, **env):
        return subprocess.run(["bash", str(HOOK)], input=json.dumps({"session_id": "s1", "cwd": str(self.repo)}),
                              cwd=self.repo, env=dict(self.env, **env), capture_output=True, text=True).stdout

    def test_pointer_has_rule_module_ids_last_header_and_next(self):
        self.build(f"## S-0002 2026-01-02 {SLUG} {SID} score:90\nverdict: ok\n{NEXT}\n## S-0001 2026-01-01 onboard sid:bbbb\nnext: older next\n")
        out = self.run_hook()
        lines = out.splitlines()
        find = f"`bash {self.home}/.claude/skills/learning/bin/learn.sh find <terms>`"
        self.assertTrue(lines[0].startswith("learning: .learning/ DB present. RULES:"))
        self.assertIn(find, lines[0])
        # sessions (type reference) counts in "more"; 30 r rows + sessions = 31
        self.assertEqual("modules: c0 c1 c2 c3 c4 c5 c6 c7 g0 +31 more (learn.sh find)", lines[1])
        head = f"S-0002 2026-01-02 {SLUG} {SID} score:90"
        self.assertEqual("last: " + head[:140 - len(" " + SID)] + " " + SID, lines[2])
        self.assertEqual(NEXT[:200], lines[3])
        self.assertEqual(4, len(lines))
        self.assertNotIn("row summary", out)
        self.assertLess(len(out.encode()) - len(find), 1800 - 120, "under 1,800 B with a 120-char find command")

    def test_next_line_comes_only_from_the_newest_block(self):
        self.build("## S-0002 2026-01-02 new sid:cccc\nverdict: ok\n## S-0001 2026-01-01 onboard sid:bbbb\nnext: older next\n")
        self.assertEqual(["last: S-0002 2026-01-02 new sid:cccc"], self.run_hook().splitlines()[2:])

    def test_board_run_text_names_the_learn_wrapper_and_no_claude_path(self):
        self.build("## S-0001 2026-01-01 onboard sid:bbbb\nnext: x\n")
        out = self.run_hook(TB_PHASE="working")
        self.assertIn("`learn find <terms>`", out)
        self.assertIn("Board run: save notes only when the board note says so", out)
        self.assertNotIn(".claude", out)

    def test_no_database_nudges_only_in_a_code_repo(self):
        self.assertEqual("", self.run_hook())
        (self.repo / "package.json").write_text("{}")
        self.assertEqual(["learning: no .learning/ here. Onboarding new project? run /learning onboard (builds module map, local only)."],
                         self.run_hook().splitlines())


if __name__ == "__main__":
    unittest.main()
