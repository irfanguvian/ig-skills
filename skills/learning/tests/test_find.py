"""learn.sh find / stats + hooks/learning-pre-search.sh.

Hermetic: HOME, TMPDIR and LEARNING_DIR point at a tmp tree, so the real
~/.claude/learning-metrics.jsonl and $TMPDIR seen-files are never written.
"""
import datetime, json, os, shutil, subprocess, tempfile, time, unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
LEARN = SKILL / "bin" / "learn.sh"
# LEARNING_HOOKS_DIR: revert checks run against a copy, never the canonical hook
HOOK = Path(os.environ.get("LEARNING_HOOKS_DIR", SKILL / "hooks")) / "learning-pre-search.sh"
NOTE = "---\nid: {id}\ntitle: {title}\ntype: concept\ntags: [{tags}]\nsummary: {summary}\n---\n# {title}\n{body}\nverdict: ok\n"
REF = "---\nid: {id}\ntitle: {title}\ntype: reference\ntags: [reference]\n---\n# {title}\n{body}"


class FindAndPreSearch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp()).resolve()
        cls.repo = cls.tmp / "repo"
        cls.L = cls.repo / ".learning"
        (cls.L / "modules").mkdir(parents=True)
        (cls.L / "modules" / "billing.md").write_text(NOTE.format(
            id="billing", title="Billing", tags="billing, stripe", summary="Stripe checkout + webhook",
            body="flow: checkout session, webhook signature verify"))
        (cls.L / "modules" / "jobs.md").write_text(NOTE.format(
            id="jobs", title="Jobs", tags="jobs", summary="client posts order request; worker accepts it", body="status lifecycle"))
        (cls.L / "DECISIONS.md").write_text(REF.format(id="decisions", title="Decisions", body=(
            "- D-0001 2026-01-01 [[jobs]] jobs paginate by cursor\n"
            "- D-0002 2026-01-02 [[billing]] refunds idempotent by Idempotency-Key on stripe webhook\n")))
        (cls.L / "SESSIONS.md").write_text(REF.format(id="sessions", title="Sessions", body=(
            "## S-0002 2026-01-02 refund-idempotency sid:aaaa\nwork: idempotency key [[billing]] stripe\n"
            "## S-0001 2026-01-01 onboard sid:bbbb\nwork: onboard [[jobs]]\n")))
        # real build: graphify-out/graph.json carries every term, the noise defect (a) is about
        subprocess.run(["bash", str(LEARN), "build", str(cls.L)], capture_output=True, text=True, check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(dir=self.tmp)).resolve()
        (self.home / ".claude" / "skills").mkdir(parents=True)
        (self.home / ".claude" / "skills" / "learning").symlink_to(SKILL)
        (self.home / "tmp").mkdir()
        self.env = {k: v for k, v in os.environ.items() if k not in ("LEARNING_DIR", "LEARNING_CALLER")}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.home / "tmp"), PWD=str(self.repo),
                        CLAUDE_CODE_SESSION_ID="feedf00d-0000-0000-0000-000000000000")

    def learn(self, *args):
        env = dict(self.env, LEARNING_DIR=str(self.L))
        return subprocess.run(["bash", str(LEARN), *args], cwd=self.repo, env=env, capture_output=True, text=True).stdout

    def hook(self, command, **agent):
        payload = {"session_id": "cafe0123-1", "cwd": str(self.repo), "tool_name": "Bash",
                   "tool_input": {"command": command}, **agent}
        return subprocess.run(["bash", str(HOOK)], input=json.dumps(payload), cwd=self.repo, env=self.env,
                              capture_output=True, text=True).stdout

    def metrics(self):
        f = self.home / ".claude" / "learning-metrics.jsonl"
        return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []

    def test_doc_list_skips_graphify_out_and_logs(self):
        self.assertIn("stripe", (self.L / "graphify-out" / "graph.json").read_text().lower())
        out = self.learn("find", "stripe")
        self.assertIn("DOC modules/billing.md", out)
        self.assertNotIn("graphify-out", out)
        self.assertNotIn("DOC DECISIONS.md", out)
        [m] = self.metrics()
        self.assertEqual(("find", "feedf00d", "stripe", str(self.repo)), (m["ev"], m["sid"], m["terms"], m["root"]))
        self.assertGreater(m["hits"], 0)

    def test_nonsense_prints_nothing_and_graph_lines_name_a_term(self):
        self.assertEqual("", self.learn("find", "zzqx", "qqzx"))
        self.assertEqual(0, self.metrics()[0]["hits"])
        if not (SKILL / "bin" / ".python").exists():
            self.skipTest("no python with graphify")
        # "cursor" seeds graphify on D-0001; its BFS drags in hub nodes (Billing, Jobs) that name no term
        graph = [l for l in self.learn("find", "zzqx", "cursor").splitlines() if l.startswith(("NODE", "EDGE"))]
        self.assertTrue(graph)
        self.assertTrue(all("cursor" in l.lower() for l in graph), graph)

    def test_on_demand_find_prints_node_lines_but_no_edge_lines(self):
        if not (SKILL / "bin" / ".python").exists():
            self.skipTest("no python with graphify")
        # graphify answers "cursor" with NODE and EDGE lines that both name D-0001
        out = self.learn("find", "cursor").splitlines()
        self.assertIn("NODE D-0001", "\n".join(out))
        self.assertEqual([], [l for l in out if l.startswith("EDGE")])

    def test_decision_and_session_lines_for_a_decision_term(self):
        out = self.learn("find", "idempotency")
        self.assertIn("DEC - D-0002 2026-01-02 [[billing]] refunds idempotent", out)
        self.assertNotIn("D-0001", out)
        self.assertIn("SES S-0002 2026-01-02 refund-idempotency", out)

    def test_pre_search_skips_pipeline_filter_grep(self):
        self.assertEqual("", self.hook("ps aux | grep stripe"))
        self.assertEqual([], self.metrics(), "a filter grep is no lookup")
        ctx = json.loads(self.hook("grep -rn stripe src"))["hookSpecificOutput"]["additionalContext"]
        self.assertIn("modules/billing.md", ctx)
        [m] = self.metrics()
        self.assertEqual(("pre-search", "main", str(self.repo)), (m["ev"], m["agent"], m["root"]))
        self.assertGreater(m["hits"], 0)

    def test_repeat_lookup_same_agent_is_deduped(self):
        first = self.hook("grep -rn stripe src")
        self.assertIn("additionalContext", first)
        self.assertEqual("", self.hook("rg stripe apps"), "same terms, same session, same agent")
        dup = self.metrics()[-1]
        self.assertEqual((True, 0), (dup["dup"], dup["bytes"]))
        self.assertEqual(self.metrics()[0]["bytes"], dup["saved"])
        other = self.hook("grep -rn stripe src", agent_id="aexplore-0123456789abcdef", agent_type="Explore")
        self.assertIn("additionalContext", other, "a subagent has not seen the parent's injection")

    def test_flag_values_are_not_the_pattern(self):
        self.hook("grep -rn --include='*.ts' --exclude-dir=node_modules stripe src")
        self.assertEqual(["stripe"], [m["terms"] for m in self.metrics()])

    def test_e_arg_is_the_pattern(self):
        self.assertIn("additionalContext", self.hook("grep -rn -C 2 -e stripe src"))
        for cmd in ("grep -rn --regexp=stripe src", "grep -rn -E -e stripe src"):
            self.hook(cmd)  # same terms -> dup line, still logged with its terms
        self.assertEqual(["stripe"] * 3, [m["terms"] for m in self.metrics()])

    def test_spaced_flag_value_is_not_the_pattern(self):
        # own session per call: the fixture's one billing note would repeat lines already sent
        for i, cmd in enumerate(("grep -rn -A 3 stripe src", "rg -t ts webhook apps", "grep -rn -C2 checkout src")):
            self.assertIn("additionalContext", self.hook(cmd, session_id=f"spaced0{i}"), cmd)
        self.assertEqual(["stripe", "webhook", "checkout"], [m["terms"] for m in self.metrics()])

    def test_search_without_a_command_line_pattern_is_skipped(self):
        for cmd in ("rg --files apps/orders | grep stripe", "grep -f patterns.txt -rn apps/orders",
                    'grep -rn -e "-stripe" apps/orders'):
            self.assertEqual("", self.hook(cmd), cmd)
        self.assertEqual([], self.metrics())

    def test_quoted_newlines_are_not_statements(self):
        out = self.hook('git commit -m "fix billing\n\ngrep -rn stripe was slow\nbash x/learn.sh find bodyterm"')
        self.assertEqual("", out)
        self.assertEqual([], self.metrics())

    def test_heredoc_body_is_no_command_and_opens_no_quote(self):
        self.hook("cat > n.md <<'EOF'\nit's a note\ngrep -rn bodygrep apps\nEOF\ngrep -rn stripe src")
        self.hook('cat <<-"END"\n\tgrep -rn bodygrep apps\n\tEND\nrg webhook apps')
        self.assertEqual(["stripe", "webhook"], [m["terms"] for m in self.metrics()])

    def test_ag_f_is_a_flag_not_a_pattern_file(self):
        self.assertIn("additionalContext", self.hook("ag -f stripe apps"))
        self.assertEqual(["stripe"], [m["terms"] for m in self.metrics()])

    def test_word_after_double_dash_is_the_pattern(self):
        self.assertIn("additionalContext", self.hook("grep -rn -- -stripe apps/orders"))
        self.assertEqual(["stripe"], [m["terms"] for m in self.metrics()])

    def test_pattern_before_double_dash_wins(self):
        for cmd in ("git grep -n stripe -- apps/orders", "rg webhook -- apps/orders/src",
                    "grep -rn checkout -- apps/orders/src", 'git grep cursor -- "*.ts"'):
            self.hook(cmd)
        self.assertEqual(["stripe", "webhook", "checkout", "cursor"], [m["terms"] for m in self.metrics()])

    def test_ack_f_lists_files_no_lookup(self):
        self.assertEqual("", self.hook("ack -f apps/orders"))
        self.assertEqual([], self.metrics())

    def test_stopwords_are_not_terms(self):
        self.hook('grep -rn "the stripe" src')
        self.assertEqual("", self.hook('grep -rn "with from that" src'), "all-stopword pattern = no lookup")
        self.learn("find", "the", "webhook")
        self.assertEqual([("pre-search", "stripe"), ("find", "webhook")], [(m["ev"], m["terms"]) for m in self.metrics()])

    def test_spaced_long_option_value_is_not_the_pattern(self):
        self.hook("grep -rn --include '*.ts' --exclude-dir billing stripe src")
        self.hook("rg --type ts --glob '*.ts' --max-count 5 webhook apps")
        self.assertEqual(["stripe", "webhook"], [m["terms"] for m in self.metrics()])

    def test_heredoc_starts_only_outside_quotes_or_in_quoted_substitution(self):
        self.hook('git commit -m "use << EOF style"\ngrep -rn stripe src')
        self.hook('gh pr create --body "$(cat <<\'EOF\'\nsay "hi\nEOF\n)"; grep -rn webhook src')
        self.assertEqual(["stripe", "webhook"], [m["terms"] for m in self.metrics()])

    def test_indented_search_line_is_a_lookup(self):
        self.assertIn("additionalContext", self.hook("if true; then\n\tgrep -rn stripe src\nfi"))
        self.assertEqual(["stripe"], [m["terms"] for m in self.metrics()])

    def test_path_prefixed_tool_is_a_lookup(self):
        for i, cmd in enumerate(("/usr/bin/grep -rn stripe src", "/opt/homebrew/bin/rg -t ts webhook apps")):
            self.assertIn("additionalContext", self.hook(cmd, session_id=f"prefix0{i}"), cmd)
        self.assertEqual(["stripe", "webhook"], [m["terms"] for m in self.metrics()])

    def test_grep_for_learn_sh_find_text_is_a_lookup_not_a_find_call(self):
        self.hook('grep -rn "learn.sh find" ~/.claude/skills')
        self.assertEqual([("pre-search", "learn find")], [(m["ev"], m["terms"]) for m in self.metrics()])

    def test_big_non_search_command_exits_fast(self):
        t0 = time.monotonic()
        self.assertEqual("", self.hook('echo "' + "x" * 3_000_000 + '" > /dev/null'))
        self.assertLess(time.monotonic() - t0, 0.5, "must exit before git/jq/awk work (1.4s without the prefilter)")
        self.assertEqual([], self.metrics())

    def test_big_search_command_splits_in_linear_time(self):
        t0 = time.monotonic()
        out = self.hook('grep -rn stripe src; echo "' + "x" * 300_000 + '"')
        self.assertLess(time.monotonic() - t0, 2.0, "quadratic split took 6s+ at this size")
        self.assertIn("additionalContext", out)

    def test_find_call_logged_with_agent(self):
        out = self.hook("bash ~/.claude/skills/learning/bin/learn.sh find stripe webhook 2>/dev/null",
                        agent_id="aexplore-0123456789abcdef", agent_type="Explore")
        self.assertEqual("", out)
        [m] = self.metrics()
        self.assertEqual(("find-call", "Explore", "89abcdef", "stripe webhook"), (m["ev"], m["agent"], m["aid"], m["terms"]))

    def test_stats_here_counts_subdir_and_rooted_lines(self):
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = lambda **kw: json.dumps({"ts": ts, "ev": "pre-search", "sid": "s1", "terms": "x", "hits": 3, "bytes": 10, **kw})
        (self.home / ".claude" / "learning-metrics.jsonl").write_text("\n".join([
            line(cwd=str(self.repo / "apps" / "backend")),            # legacy line, subdir cwd
            line(cwd="/elsewhere/wt", root=str(self.repo)),          # rooted here from a worktree
            line(cwd="/elsewhere/other")]) + "\n")
        out = self.learn("stats", "30", "--here")
        self.assertIn("auto-inject: 2 lookups", out)
        self.assertIn("1 real hits of 1 rated (100%)", out)


LONG = "z" * 70  # long folder name: DOC lines near 105 chars, so 3 INDEX + 3 DOC pass the 900-char inject cap


class WholeWordAndBrief(unittest.TestCase):
    """Whole-word term matching, term dedupe, find --brief and the pre-search inject built on it."""
    setUp, learn, hook, metrics = FindAndPreSearch.setUp, FindAndPreSearch.learn, FindAndPreSearch.hook, FindAndPreSearch.metrics

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp()).resolve()
        cls.repo = cls.tmp / "repo"
        cls.L = cls.repo / ".learning"
        notes = {
            "modules/auth.md": ("auth", "account locked after five failed tries, retry later", "def keyword helper"),
            "modules/timing.md": ("timing", "clock skew tolerance, retry window, default policy", "policy"),
            "modules/plans.md": ("plans", "subscriptions renew monthly, retry failed charge", "charge flow"),
            "modules/queue.md": ("queue", "retry queue drains nightly", "worker"),
            "modules/billing.md": ("billing", "reads subscriptionStatus from the profile", "status gate"),
            f"specs/{LONG}/zebra-one.md": ("zebra-one", "zebra " + "a" * 250, "zebra body"),
            f"specs/{LONG}/zebra-two.md": ("zebra-two", "zebra " + "b" * 250, "zebra body"),
            f"specs/{LONG}/zebra-three.md": ("zebra-three", "zebra " + "c" * 250, "zebra body"),
        }
        for rel, (nid, summary, body) in notes.items():
            (cls.L / rel).parent.mkdir(parents=True, exist_ok=True)
            (cls.L / rel).write_text(NOTE.format(id=nid, title=nid, tags="x", summary=summary, body=body))
        (cls.L / "DECISIONS.md").write_text(REF.format(id="decisions", title="Decisions", body="- D-0001 2026-01-01 [[auth]] retry with backoff\n"))
        (cls.L / "SESSIONS.md").write_text(REF.format(id="sessions", title="Sessions", body="## S-0001 2026-01-01 onboard sid:bbbb\nwork: retry [[auth]]\n"))
        subprocess.run(["bash", str(LEARN), "build", str(cls.L)], capture_output=True, text=True, check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def ids(self, out):
        return [l.split(" | ")[1] for l in out.splitlines() if l.startswith("INDEX ")]

    def docs(self, out):
        return [l for l in out.splitlines() if l.startswith("DOC ")]

    def ctx(self, out):
        return json.loads(out)["hookSpecificOutput"]["additionalContext"]

    def test_def_is_a_word_not_a_prefix(self):
        out = self.learn("find", "def")
        self.assertEqual(([], ["DOC modules/auth.md (1 hits)"]), (self.ids(out), self.docs(out)), "timing says 'default', not 'def'")

    def test_short_term_takes_endings_but_a_longer_word_does_not(self):
        out = self.learn("find", "lock")
        self.assertEqual((["auth"], ["DOC modules/auth.md (1 hits)"]), (self.ids(out), self.docs(out)), "'locked' hits, 'clock' does not")

    def test_term_of_five_chars_hits_as_word_prefix_only(self):
        self.assertEqual(["billing", "plans"], self.ids(self.learn("find", "subscription")), "subscriptionStatus + subscriptions")
        self.assertEqual("", self.learn("find", "scription"), "no hit inside a word")

    def test_repeated_term_counts_once(self):
        self.assertEqual(["DOC modules/auth.md (1 hits)"], self.docs(self.learn("find", "lock", "LOCK")))
        self.learn("find", "lock LOCK skew retry Skew clock tolerance monthly")
        self.assertEqual(["lock", "lock skew retry clock tolerance"], [m["terms"] for m in self.metrics()])

    def test_brief_keeps_three_index_three_doc_and_nothing_else(self):
        full = self.learn("find", "retry")
        self.assertEqual((4, 4), (len(self.ids(full)), len(self.docs(full))))
        self.assertTrue(any(l.startswith(("DEC ", "SES ")) for l in full.splitlines()))
        brief = self.learn("find", "--brief", "retry").splitlines()
        self.assertEqual(["INDEX"] * 3 + ["DOC"] * 3, [l.split(" ")[0] for l in brief])
        self.assertEqual(["auth", "plans", "queue"], self.ids("\n".join(brief)), "best first, INDEX order on a tie")
        self.assertEqual(len("INDEX ") + 200, len(self.learn("find", "--brief", "zebra").splitlines()[0]), "row cut to 200")

    def test_brief_doc_lines_need_only_one_of_two_terms(self):
        out = self.learn("find", "--brief", "retry", "zzqx")
        self.assertEqual((["auth", "plans", "queue"], 3), (self.ids(out), len(self.docs(out))))
        self.assertEqual("", self.learn("find", "--brief", "zzqx"))

    def test_hook_inject_is_whole_lines_under_900_chars(self):
        brief = self.learn("find", "--brief", "zebra").splitlines()
        self.assertEqual(6, len(brief))
        ctx = self.ctx(self.hook("grep -rn zebra src"))
        self.assertEqual(["learning hits [zebra] (open only if relevant):"] + brief[:5], ctx.splitlines(), "6th line would pass 900")
        self.assertLessEqual(len(ctx), 900)

    def test_hook_keeps_code_words_as_terms(self):
        self.assertEqual("", self.hook('grep -rnE "Get|Post|Patch|Put" src'), "no note names them")
        self.assertEqual([("pre-search", "Get Post Patch Put")], [(m["ev"], m["terms"]) for m in self.metrics()])

    def test_hook_never_resends_a_line_to_the_same_agent(self):
        first = self.ctx(self.hook("grep -rn lock src")).splitlines()
        self.assertEqual(["INDEX", "DOC"], [l.split(" ")[0] for l in first[1:]])
        second = self.ctx(self.hook('grep -rnE "lock|skew" src')).splitlines()
        self.assertEqual(["learning hits [lock skew] (open only if relevant):", "INDEX", "DOC modules/timing.md (1 hits)"],
                         [second[0], second[1].split(" ")[0], second[2]])
        self.assertEqual((3, ["timing"]), (len(second), self.ids("\n".join(second))))
        self.assertEqual("", self.hook('grep -rnE "lock|tolerance" src'), "every line already sent")
        self.assertEqual([(1, 0)], [(m["dup"], m["hits"]) for m in self.metrics() if m.get("dup")])
        sub = self.ctx(self.hook('grep -rnE "lock|skew" src', agent_id="aexplore-0123456789abcdef", agent_type="Explore"))
        self.assertEqual(["auth", "timing"], self.ids(sub), "a subagent has not seen the parent's lines")


if __name__ == "__main__":
    unittest.main()
