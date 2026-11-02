"""learn.sh doctor / fix.

Hermetic: HOME and LEARNING_HOOKS_DIR both point at tmp copies, so no test ever
writes the canonical hook scripts the tool restores from.
"""
import json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
LEARN = SKILL / "bin" / "learn.sh"
SCRIPTS = ["learning-session-start.sh", "learning-pre-search.sh",
           "learning-post-edit.sh", "learning-stop.sh"]


class Doctor(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        (self.repo / ".learning").mkdir(parents=True)
        (self.repo / ".learning" / "INDEX.md").write_text("| id | type |\n")
        self.home = self.tmp / "home"
        (self.home / ".claude" / "hooks").mkdir(parents=True)
        self.canon = self.tmp / "canon"
        shutil.copytree(SKILL / "hooks", self.canon)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_learn(self, *args, cwd=None):
        env = {k: v for k, v in os.environ.items() if k != "LEARNING_DIR"}
        env.update(HOME=str(self.home), LEARNING_HOOKS_DIR=str(self.canon))
        return subprocess.run(["bash", str(LEARN), *args], cwd=cwd or self.repo, env=env,
                              capture_output=True, text=True)

    def test_reports_then_repairs_missing_scripts_and_never_registers_hooks(self):
        # Contract changed 2026-11-01 (lean flow): the 4 Claude hooks are off; fix must not register them.
        r = self.run_learn("doctor")
        self.assertIn("learning-stop.sh missing", r.stdout)
        self.assertIn("ok: learning hooks off", r.stdout)
        self.assertEqual(1, r.returncode, "doctor must exit non-zero on problems")

        self.run_learn("fix")
        r = self.run_learn("doctor")
        self.assertIn("verdict: clean", r.stdout)
        self.assertEqual(0, r.returncode)
        self.assertEqual(4, len(list((self.home / ".claude" / "hooks").glob("learning-*.sh"))))
        reg = self.repo / ".claude" / "settings.local.json"
        self.assertFalse(reg.exists() and "learning-" in reg.read_text(), "fix must never register learning hooks")

    def test_leftover_learning_hook_is_a_problem(self):
        (self.repo / ".claude").mkdir()
        (self.repo / ".claude" / "settings.local.json").write_text(json.dumps(
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash h/learning-stop.sh"}]}]}}))
        r = self.run_learn("doctor")
        self.assertIn("learning hooks still registered", r.stdout)
        self.assertIn("learning-stop.sh", r.stdout)
        self.assertEqual(1, r.returncode)

    def test_restores_a_stale_script(self):
        self.run_learn("fix")
        live = self.home / ".claude" / "hooks" / "learning-post-edit.sh"
        live.write_text("# tampered\n")
        self.assertIn("learning-post-edit.sh stale", self.run_learn("doctor").stdout)
        self.run_learn("fix")
        self.assertEqual((self.canon / "learning-post-edit.sh").read_text(), live.read_text())

    def test_flags_a_live_stop_hook_that_gates_on_stop_hook_active(self):
        self.run_learn("fix")
        live = self.home / ".claude" / "hooks" / "learning-stop.sh"
        live.write_text('#!/usr/bin/env bash\n[ "$stop_hook_active" = true ] && exit 0\n')
        out = self.run_learn("doctor").stdout
        self.assertIn("gates on stop_hook_active", out)
        self.assertIn(str(live), out, "must name the file that actually runs, not the skill copy")

    def test_flags_another_machines_home_in_repo_settings(self):
        (self.repo / ".claude").mkdir(exist_ok=True)
        (self.repo / ".claude" / "settings.json").write_text(
            '{"a":"/Users/someoneelse/x","b":"/Users/anotherdev/y","c":"/Users/Shared/z"}\n')
        out = self.run_learn("doctor").stdout
        self.assertIn("anotherdev, someoneelse", out, "every foreign home on the line, Shared excluded")

    def test_rebuilds_a_stale_index(self):
        self.run_learn("fix")
        note = self.repo / ".learning" / "CODEBASE.md"
        note.write_text("---\nid: codebase\ntitle: T\ntype: guide\ntags: [t]\n---\n# T\nverdict: ok\n")
        os.utime(self.repo / ".learning" / "INDEX.md", (0, 0))
        self.assertIn("INDEX older than 1 note", self.run_learn("doctor").stdout)
        self.assertIn("INDEX rebuilt", self.run_learn("fix").stdout)
        self.assertIn("INDEX fresh", self.run_learn("doctor").stdout)

    def test_git_repo_gets_post_checkout_seed_and_worktree_resolves_main_db(self):
        git = lambda *a, cwd=None: subprocess.run(["git", *a], cwd=cwd or self.repo, capture_output=True, text=True)
        git("init", "-q"); git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
        (self.repo / "CLAUDE.local.md").write_text("rules\n")
        (self.repo / ".claude").mkdir()
        (self.repo / ".claude" / "settings.local.json").write_text('{"hooks": {}}\n')
        r = self.run_learn("doctor")
        self.assertIn("git post-checkout missing", r.stdout)
        self.run_learn("fix")
        r = self.run_learn("doctor")
        self.assertIn("git post-checkout seeds worktrees", r.stdout)
        self.assertEqual(0, r.returncode)
        wt = self.tmp / "wt"
        git("worktree", "add", "--detach", str(wt), "HEAD")
        self.assertEqual("rules\n", (wt / "CLAUDE.local.md").read_text(), "post-checkout must seed local rules")
        self.assertTrue((wt / ".claude" / "settings.local.json").exists(), "post-checkout must seed hooks config")
        self.assertFalse((wt / ".learning").exists(), "worktree must never get its own DB")
        env = {k: v for k, v in os.environ.items() if k != "LEARNING_DIR"}; env["HOME"] = str(self.home)
        r = subprocess.run(["bash", str(LEARN), "status"], cwd=wt, env=env, capture_output=True, text=True)
        self.assertIn("docs:", r.stdout, "status from a worktree must read the main checkout DB, not report missing")


    def worktree(self):
        git = lambda *a: subprocess.run(["git", *a], cwd=self.repo, capture_output=True, text=True)
        git("init", "-q"); git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
        (self.repo / "CLAUDE.local.md").write_text("rules v1\n")
        (self.repo / ".claude").mkdir()
        (self.repo / ".claude" / "settings.local.json").write_text(json.dumps({"hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash vitest-guard.sh"}]}]}}, indent=2) + "\n")
        self.run_learn("fix")
        wt = self.tmp / "wt"
        git("worktree", "add", "--detach", str(wt), "HEAD")
        return wt

    def test_worktree_rules_edited_after_main_are_backed_up_before_sync(self):
        wt = self.worktree()
        (self.repo / "CLAUDE.local.md").write_text("rules v2\n"); os.utime(self.repo / "CLAUDE.local.md", (1, 1))
        (wt / "CLAUDE.local.md").write_text("my worktree note\n")
        out = self.run_learn("fix", cwd=wt).stdout
        [bak] = list(wt.glob("CLAUDE.local.md.bak-*"))
        self.assertEqual("my worktree note\n", bak.read_text())
        self.assertIn("kept as " + bak.name, out)
        self.assertEqual("rules v2\n", (wt / "CLAUDE.local.md").read_text())

    def test_corrupt_main_settings_is_a_problem_line_not_a_traceback(self):
        wt = self.worktree()
        (self.repo / ".claude" / "settings.local.json").write_text("{not json\n")
        r = self.run_learn("doctor", cwd=wt)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("is not valid JSON", r.stdout)
        self.assertIn("verdict: 1 problem(s)", r.stdout)
        self.assertEqual(1, r.returncode)

    def test_worktree_config_drift_reported_then_synced_keeping_permissions(self):
        wt = self.worktree()
        self.assertIn("main checkout, worktree sync n/a", self.run_learn("doctor").stdout)
        # main gains a hook + a rule after the seed; the worktree gained its own permission
        ms, ws = self.repo / ".claude" / "settings.local.json", wt / ".claude" / "settings.local.json"
        m = json.loads(ms.read_text())
        m["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": "bash guard.sh"}]})
        ms.write_text(json.dumps(m, indent=2) + "\n")
        (self.repo / "CLAUDE.local.md").write_text("rules v2\n")
        w = json.loads(ws.read_text()); w["permissions"] = {"allow": ["Bash(npm test)"]}
        ws.write_text(json.dumps(w, indent=2) + "\n")

        r = self.run_learn("doctor", cwd=wt)
        self.assertEqual(2, r.stdout.count("problem:"), r.stdout)
        self.assertIn("worktree hooks differ from main checkout", r.stdout)
        self.assertIn("CLAUDE.local.md differs from main checkout", r.stdout)
        self.assertEqual(1, r.returncode)
        self.run_learn("fix", cwd=wt)
        r = self.run_learn("doctor", cwd=wt)
        self.assertIn("verdict: clean", r.stdout)
        w = json.loads(ws.read_text())
        self.assertEqual(m["hooks"], w["hooks"])
        self.assertEqual(["Bash(npm test)"], w["permissions"]["allow"], "fix must touch only .hooks")
        self.assertEqual("rules v2\n", (wt / "CLAUDE.local.md").read_text())


if __name__ == "__main__":
    unittest.main()
