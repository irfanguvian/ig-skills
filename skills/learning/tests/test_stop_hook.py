"""learning-stop.sh: LEARNING_DIR override, board-run (TB_PHASE) rule, real-write counting."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / "hooks" / "learning-stop.sh"
EDIT = lambda d: tool("Edit", file_path=str(d / "src" / "a.js"))  # one real project edit


def tool(name, **inp):
    """One transcript line in the real Claude Code shape: assistant message with a tool_use block."""
    return {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "ok"}, {"type": "tool_use", "id": "t1", "name": name, "input": inp}]}}


def bash(command):
    return tool("Bash", command=command)


def unsaved(n):
    return f"learning: {n} unsaved edits"


class StopHook(unittest.TestCase):
    def run_hook(self, lines=None, cwd=None, **env):
        d = Path(tempfile.mkdtemp()).resolve()  # resolved: git reports /private/var, not /var
        (d / "db").mkdir()
        (d / "db" / "SESSIONS.md").write_text("## S-0001\n")
        lines = [EDIT] if lines is None else lines
        lines = [l(d) if callable(l) else l for l in lines]
        tr = d / "tr"
        tr.write_text("".join((l if isinstance(l, str) else json.dumps(l)) + "\n" for l in lines))
        sid = "t" + d.name[-6:]
        inp = json.dumps({"cwd": str(cwd(d) if cwd else d), "transcript_path": str(tr), "session_id": sid})
        e = {k: v for k, v in os.environ.items() if not k.startswith(("TB_", "GIT_"))}
        e.update(TMPDIR=str(d), HOME=str(d), LEARNING_DIR=str(d / "db"), **env)
        return subprocess.run(["bash", str(HOOK)], input=inp, capture_output=True, text=True, env=e).stdout

    def test_terminal_session_blocks_via_learning_dir(self):
        self.assertIn('"block"', self.run_hook())

    def test_board_review_never_blocks(self):
        self.assertEqual(self.run_hook(TB_PHASE="review", TB_LAST_TASK="1"), "")

    def test_board_working_blocks_only_on_last_task(self):
        self.assertEqual(self.run_hook(TB_PHASE="working", TB_LAST_TASK="0"), "")
        self.assertIn('"block"', self.run_hook(TB_PHASE="working", TB_LAST_TASK="1"))

    # negatives: each sits next to one real edit, so the count must be exactly 1 (0 or 2+ fails)
    def test_tool_list_line_naming_bash_is_not_an_edit(self):
        line = {"type": "api-request", "tools": [{"name": "Bash", "description": "call tabs_context_mcp first"}]}
        self.assertIn(unsaved(1), self.run_hook([line, line, EDIT]))

    def test_write_verb_inside_quotes_is_not_a_write(self):
        self.assertIn(unsaved(1), self.run_hook([bash("grep -n 'sed -i' f.sh"), EDIT]))

    def test_write_to_scratch_outside_project_is_not_an_edit(self):
        self.assertIn(unsaved(1), self.run_hook([tool("Write", file_path="/private/tmp/x/scratch.html", content="hi"), EDIT]))

    def test_redirect_to_scratch_var_is_not_a_write(self):
        self.assertIn(unsaved(1), self.run_hook([bash("S=/private/tmp/x; D=$S/y.diff; : > $D"), EDIT]))

    def test_bad_lines_do_not_hide_a_real_edit(self):
        bad = ['{"type":"assistant","message":{"content":[{"type":"tool_u',  # truncated line
               tool("Edit", file_path=123), tool("Bash", command=["ls"]),
               {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Edit", "input": "oops"}]}}]
        self.assertIn(unsaved(1), self.run_hook(bad + [EDIT]))

    def test_edit_under_project_root_blocks(self):
        self.assertIn(unsaved(1), self.run_hook([lambda d: tool("Edit", file_path=str(d / "apps" / "x.ts"))]))

    def test_heredoc_redirect_into_project_blocks(self):
        self.assertIn(unsaved(1), self.run_hook([bash("cat > notes.md <<EOF\nhello\nEOF")]))

    def test_wrapped_and_nested_writes_count(self):
        for cmd in ["rg -l foo apps/ | xargs sed -i '' 's/a/b/'",
                    "find apps -name '*.ts' -exec sed -i '' 's/a/b/' {} \\;",
                    "sed -i.bak 's/a/b/' f.ts",
                    "if cp a.ts b.ts; then echo ok; fi",
                    "CI=1 npm i left-pad",
                    "bash -c \"sed -i '' s/a/b/ f.ts\""]:
            with self.subTest(cmd=cmd):
                self.assertIn(unsaved(1), self.run_hook([bash(cmd)]))

    def test_edit_in_linked_worktree_blocks(self):
        def repo(d):
            main, g = d / "main", ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
            main.mkdir()
            for a in (["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "x"], ["worktree", "add", "-q", str(d / "wt")]):
                subprocess.run(g + ["-C", str(main)] + a, check=True, capture_output=True)
            return main
        self.assertIn(unsaved(1), self.run_hook([lambda d: tool("Edit", file_path=str(d / "wt" / "x.ts"))], cwd=repo))

    def test_learn_build_after_edits_is_a_save(self):
        self.assertIn(unsaved(1), self.run_hook([
            EDIT, lambda d: tool("Write", file_path=str(d / "b.js")),
            bash("bash ~/.claude/skills/learning/bin/learn.sh build 2>&1 | tail -1"), EDIT]))

    def test_learn_find_with_build_word_is_not_a_save(self):
        self.assertIn(unsaved(1), self.run_hook([EDIT, bash("bash ~/.claude/skills/learning/bin/learn.sh find build gate")]))

    def test_sessions_md_as_write_target_is_a_save(self):
        self.assertIn(unsaved(1), self.run_hook([EDIT, bash("cat >> .learning/SESSIONS.md <<EOF\nx\nEOF"), EDIT]))

    def test_sessions_md_as_copy_source_is_not_a_save(self):
        self.assertIn(unsaved(2), self.run_hook([EDIT, bash("cp .learning/SESSIONS.md /tmp/bak.md")]))


if __name__ == "__main__":
    unittest.main()
