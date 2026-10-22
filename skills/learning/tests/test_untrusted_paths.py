"""Untrusted cwd and shared tmp: a repo's planted python module never runs, hook state files
live in a per-user 700 dir and are skipped when that dir is not safe."""
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
LEARN = SKILL / "bin" / "learn.sh"
HOOKS = SKILL / "hooks"
NOTE = "---\nid: billing\ntitle: Billing\ntype: concept\ntags: [billing]\nsummary: checkout flow\n---\n# Billing\nwebhook\n"


class UntrustedPaths(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.repo = self.tmp / "repo"
        self.L = self.repo / ".learning"
        (self.L / "modules").mkdir(parents=True)
        (self.L / "modules" / "billing.md").write_text(NOTE)
        (self.L / "SESSIONS.md").write_text("## S-0001\n")
        subprocess.run(["bash", str(LEARN), "build", str(self.L)], capture_output=True, text=True, check=True)
        self.home = self.tmp / "home"
        (self.home / ".claude" / "skills").mkdir(parents=True)
        (self.home / ".claude" / "skills" / "learning").symlink_to(SKILL)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LEARNING_", "TB_", "GIT_"))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.tmp), LEARNING_DIR=str(self.L))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_planted_modules_in_cwd_never_run(self):
        for mod in ("graphify", "json", "pathlib"):
            (self.repo / f"{mod}.py").write_text(f"open({str(self.tmp / ('RAN_' + mod))!r}, 'w').close()\n")
        found = ""
        for args in (["find", "billing"], ["hooks", "status"], ["doctor"]):
            r = subprocess.run(["bash", str(LEARN), *args], cwd=self.repo, env=self.env, capture_output=True, text=True)
            found += r.stdout if args[0] == "find" else ""
        self.assertEqual([], sorted(p.name for p in self.tmp.glob("RAN_*")))
        self.assertIn("DOC modules/billing.md", found)

    def test_pre_search_seen_file_lives_in_private_user_dir(self):
        inp = {"session_id": "cafe0123-1", "cwd": str(self.repo), "tool_name": "Grep", "tool_input": {"pattern": "billing"}}
        r = subprocess.run(["bash", str(HOOKS / "learning-pre-search.sh")], input=json.dumps(inp), cwd=self.repo,
                           env=self.env, capture_output=True, text=True)
        self.assertIn("additionalContext", r.stdout)
        d = self.tmp / f"learning-{os.getuid()}"
        self.assertEqual((0o700, ["learning-seen-cafe0123"]), (d.stat().st_mode & 0o777, [p.name for p in d.iterdir()]))

    def test_loose_user_dir_is_tightened_to_700(self):
        d = self.tmp / f"learning-{os.getuid()}"
        d.mkdir()
        d.chmod(0o777)
        inp = {"session_id": "cafe0123-1", "cwd": str(self.repo), "tool_name": "Grep", "tool_input": {"pattern": "billing"}}
        subprocess.run(["bash", str(HOOKS / "learning-pre-search.sh")], input=json.dumps(inp), cwd=self.repo,
                       env=self.env, capture_output=True, text=True)
        self.assertEqual(0o700, d.stat().st_mode & 0o777)

    def test_stop_hook_skips_marker_when_user_dir_is_a_symlink(self):
        evil = self.tmp / "evil"
        evil.mkdir()
        (self.tmp / f"learning-{os.getuid()}").symlink_to(evil)
        tr = self.tmp / "tr"
        tr.write_text(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "t1", "name": "Edit", "input": {"file_path": str(self.repo / "a.js")}}]}}) + "\n")
        inp = {"cwd": str(self.repo), "transcript_path": str(tr), "session_id": "s1"}
        r = subprocess.run(["bash", str(HOOKS / "learning-stop.sh")], input=json.dumps(inp), env=self.env,
                           capture_output=True, text=True)
        # no safe loop-guard marker -> fail open: no block, nothing written through the link
        self.assertEqual((0, "", []), (r.returncode, r.stdout, list(evil.iterdir())))


if __name__ == "__main__":
    unittest.main()
