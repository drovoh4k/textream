#!/usr/bin/env python3
"""Run the workflow's real shell against temporary Git repos; gh never reaches GitHub."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/drovo-sync-upstream.yml"
SCRIPT = textwrap.dedent(WORKFLOW.read_text().split("        run: |\n", 1)[1].split("\n  build:", 1)[0])
GIT = shutil.which("git")
ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
           GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid")


def git(repo, *args):
    return subprocess.check_output([GIT, "-C", str(repo), *args], env=ENV, stderr=subprocess.PIPE, text=True).strip()


def commit(repo, name, text):
    (repo / name).write_text(text)
    git(repo, "add", name)
    git(repo, "commit", "-qm", text.strip())


class Scenario:
    def __init__(self, root, name, *, conflict=False):
        self.root = root / name
        self.root.mkdir()
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q", "-b", "master")
        commit(self.upstream, "script.txt", "original\n")
        self.origin = self.root / "origin.git"
        git(self.root, "clone", "-q", "--bare", str(self.upstream), str(self.origin))
        fork = self.root / "fork"
        git(self.root, "clone", "-q", str(self.origin), str(fork))
        commit(fork, "script.txt" if conflict else "fork.txt", "our changes\n")
        git(fork, "push", "-q", "origin", "master")
        if conflict:
            commit(self.upstream, "script.txt", "their changes\n")
        self.before = git(self.origin, "rev-parse", "master")
        self.count = 0
        self.env = dict(ENV, PATH=str(root / "bin") + os.pathsep + ENV["PATH"],
                        UPSTREAM_REPO=str(self.upstream), UPSTREAM_BRANCH="master",
                        GITHUB_REPOSITORY="test/fork", GITHUB_WORKFLOW="Sync with upstream",
                        GITHUB_RUN_NUMBER="1", GITHUB_RUN_ID="1", GITHUB_SERVER_URL="https://example.invalid",
                        FAKE_GH_ROOT=str(self.root), FAKE_ISSUES="false")

    def run(self, *, success=True):
        self.count += 1
        checkout = self.root / f"run-{self.count}"
        git(self.root, "clone", "-q", str(self.origin), str(checkout))
        output, summary = checkout / "outputs", checkout / "summary"
        result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", SCRIPT],
                                cwd=checkout, env=dict(self.env, GITHUB_OUTPUT=str(output),
                                                       GITHUB_STEP_SUMMARY=str(summary)),
                                capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        self.checkout = checkout
        self.output = output.read_text() if output.exists() else ""
        self.summary = summary.read_text() if summary.exists() else ""
        return result

    def unchanged(self):
        assert git(self.origin, "rev-parse", "master") == self.before
        assert git(self.checkout, "rev-parse", "HEAD") == self.before
        assert not (self.checkout / ".git/MERGE_HEAD").exists()

    def calls(self):
        log = self.root / "gh.log"
        return [json.loads(line)[:2] for line in log.read_text().splitlines()] if log.exists() else []


with tempfile.TemporaryDirectory(prefix="textream-sync-") as temporary:
    root = Path(temporary)
    (root / "bin").mkdir()
    fake_gh = root / "bin/gh"
    fake_gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
        import json, os, sys
        from pathlib import Path
        args = sys.argv[1:]
        root = Path(os.environ["FAKE_GH_ROOT"])
        with (root / "gh.log").open("a") as log:
            log.write(json.dumps(args) + "\\n")
        if os.environ.get("FAKE_GH_FAIL") == " ".join(args[:2]):
            sys.exit(42)
        state = root / "issue-body"
        command = args[:2]
        if command == ["repo", "view"]:
            print(os.environ["FAKE_ISSUES"])
        elif command == ["issue", "list"]:
            print("7" if state.exists() else "")
        elif command == ["issue", "view"]:
            print(state.read_text())
        elif command in (["issue", "create"], ["issue", "edit"]):
            state.write_text(Path(args[args.index("--body-file") + 1]).read_text())
        elif command != ["label", "create"]:
            sys.exit("Unexpected gh call: " + repr(args))
        '''))
    fake_gh.chmod(0o755)

    clean = Scenario(root, "clean")
    commit(clean.upstream, "upstream.txt", "upstream addition\n")
    clean.run()
    assert "merged=true\n" in clean.output
    assert f"sha={git(clean.origin, 'rev-parse', 'master')}\n" in clean.output
    assert (clean.checkout / "fork.txt").exists() and (clean.checkout / "upstream.txt").exists()
    assert not clean.calls()
    clean.run()
    assert clean.output == "merged=false\n" and not clean.calls()

    disabled = Scenario(root, "disabled", conflict=True)
    result = disabled.run()
    disabled.unchanged()
    assert disabled.output == "merged=false\n"
    assert "::warning::" in result.stdout and "script.txt" in disabled.summary
    assert "Issues desactivadas" in disabled.summary
    assert disabled.calls() == [["repo", "view"]]

    enabled = Scenario(root, "enabled", conflict=True)
    enabled.env["FAKE_ISSUES"] = "true"
    enabled.run()
    enabled.unchanged()
    assert enabled.calls().count(["issue", "create"]) == 1
    enabled.run()
    enabled.unchanged()
    assert enabled.calls().count(["issue", "create"]) == 1
    assert ["issue", "edit"] not in enabled.calls() and ["issue", "comment"] not in enabled.calls()
    commit(enabled.upstream, "script.txt", "new upstream conflict\n")
    enabled.run()
    enabled.unchanged()
    assert enabled.calls().count(["issue", "edit"]) == 1
    assert git(enabled.upstream, "rev-parse", "HEAD") in (enabled.root / "issue-body").read_text()

    unrelated = Scenario(root, "unrelated")
    git(unrelated.upstream, "checkout", "-q", "--orphan", "unrelated")
    git(unrelated.upstream, "rm", "-q", "-rf", ".")
    commit(unrelated.upstream, "unrelated.txt", "unrelated history\n")
    git(unrelated.upstream, "branch", "-M", "master")
    result = unrelated.run(success=False)
    unrelated.unchanged()
    assert "::error::" in result.stdout and not unrelated.calls() and not unrelated.output

    rejected = Scenario(root, "push-rejected")
    commit(rejected.upstream, "new.txt", "new upstream file\n")
    hook = rejected.origin / "hooks/pre-receive"
    hook.write_text("#!/bin/sh\nexit 1\n")
    hook.chmod(0o755)
    rejected.run(success=False)
    assert git(rejected.origin, "rev-parse", "master") == rejected.before
    assert not rejected.output and not rejected.calls()

    auth = Scenario(root, "auth-error", conflict=True)
    auth.env["FAKE_GH_FAIL"] = "repo view"
    assert auth.run(success=False).returncode == 42
    auth.unchanged()
    assert "script.txt" in auth.summary

    fetch = Scenario(root, "fetch-error")
    fetch.env["UPSTREAM_REPO"] = str(root / "missing-repository")
    fetch.run(success=False)
    fetch.unchanged()
    assert not fetch.output and not fetch.calls()

print("PASS: clean merge/push, unchanged, disabled issues, issue dedup/update, merge/push/auth/fetch failures")
