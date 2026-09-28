#!/usr/bin/env python3
"""Public history audit checks every reachable release tree, not only HEAD."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "audit_public_refs", Path(__file__).with_name("audit-public-refs.py")
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicRefAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "README.md").write_text("Toki\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "release: v1.13.0 (44)")
        self.default_branch = subprocess.check_output(
            ["git", "branch", "--show-current"], cwd=self.repo, text=True
        ).strip()
        self.git("tag", "-a", "v1.13.0", "-m", "release")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def test_clean_history_passes(self) -> None:
        self.assertEqual(MODULE.audit(self.repo), 1)

    def test_forbidden_file_on_other_branch_fails(self) -> None:
        self.git("checkout", "-qb", "other")
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/ClAuDe.Md").write_text("private\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "bad")
        self.git("checkout", "-q", self.default_branch)
        with self.assertRaisesRegex(ValueError, "agent"):
            MODULE.audit(self.repo)

    def test_deleted_private_doc_remains_disallowed_in_history(self) -> None:
        (self.repo / "docs/research").mkdir(parents=True)
        (self.repo / "docs/research/plan.md").write_text("private\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "bad")
        (self.repo / "docs/research/plan.md").unlink()
        self.git("add", "-A")
        self.git("commit", "-qm", "delete")
        with self.assertRaisesRegex(ValueError, "private docs"):
            MODULE.audit(self.repo)

    def test_symlink_on_tagged_commit_fails(self) -> None:
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/link.swift").symlink_to("Feature.swift")
        self.git("add", "-A")
        self.git("commit", "-qm", "bad")
        self.git("tag", "-a", "v1.14.0", "-m", "release")
        with self.assertRaisesRegex(ValueError, "symlink"):
            MODULE.audit(self.repo)


if __name__ == "__main__":
    unittest.main()
