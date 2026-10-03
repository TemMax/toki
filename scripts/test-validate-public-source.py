#!/usr/bin/env python3
"""Release-tree checks that must run before a public snapshot is tagged."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "validate_public_source", Path(__file__).with_name("validate-public-source.py")
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write("project.yml", """MARKETING_VERSION: 1.13.0
CURRENT_PROJECT_VERSION: 44
SUFeedURL: https://github.com/TemMax/toki/releases/latest/download/appcast.xml
""")
        self.write("docs/release-notes/v1.13.0.md", "## Changes\n\n- Improved usage display\n")
        self.write("Package.swift", "// package\n")
        self.write("Toki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "{}\n")
        self.write("build-inputs.json", "{}\n")
        self.write("LICENSE", "Apache License\n")
        self.write("App/Resources/ThirdPartyNotices.txt", "Sparkle license\n")
        scripts = Path(__file__).parent
        for name in ("make-credits.sh", "notes-to-html.sh", "release-notes.sh"):
            target = self.root / "scripts" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            source = scripts.parent / "PublicSource/scripts/release-notes.sh" if name == "release-notes.sh" else scripts / name
            shutil.copy2(source, target)
            target.chmod(0o755)
        self.render_credits()

    def render_credits(self) -> None:
        rendered = subprocess.check_output([
            str(self.root / "scripts/make-credits.sh"), "1.13.0",
            str(self.root / "docs/release-notes/v1.13.0.md"),
        ])
        target = self.root / "App/Resources/Credits.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(rendered)

    def write(self, name: str, content: str) -> None:
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def validate(self) -> None:
        MODULE.validate_tree(self.root, "1.13.0", 44)

    def test_matching_tree_passes(self) -> None:
        self.validate()

    def test_validation_does_not_execute_renderer_from_candidate_tree(self) -> None:
        marker = self.root / "candidate-renderer-ran"
        credits = self.root / "App/Resources/Credits.html"
        renderer = self.root / "scripts/make-credits.sh"
        renderer.write_text(f"#!/bin/sh\ntouch '{marker}'\ncat '{credits}'\n")
        renderer.chmod(0o755)
        self.validate()
        self.assertFalse(marker.exists(), "private validation executed public candidate code")

    def test_old_feed_or_placeholder_credits_fails(self) -> None:
        self.write("project.yml", (self.root / "project.yml").read_text().replace(
            "github.com/TemMax/toki/releases", "github.com/TemMax/toki-releases/releases"
        ))
        with self.assertRaisesRegex(ValueError, "feed"):
            self.validate()
        self.write("project.yml", (self.root / "project.yml").read_text().replace(
            "github.com/TemMax/toki-releases/releases", "github.com/TemMax/toki/releases"
        ))
        self.write("App/Resources/Credits.html", "stale content\n")
        with self.assertRaisesRegex(ValueError, "Credits"):
            self.validate()

    def test_forbidden_case_and_symlink_are_rejected(self) -> None:
        self.write("Sources/ClAuDe.Md", "private\n")
        with self.assertRaisesRegex(ValueError, "agent"):
            self.validate()
        (self.root / "Sources/ClAuDe.Md").unlink()
        (self.root / "Sources/link.swift").symlink_to("Feature.swift")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.validate()

    def test_private_docs_and_extra_release_notes_are_rejected(self) -> None:
        self.write("docs/research/notes.md", "private\n")
        with self.assertRaisesRegex(ValueError, "private docs"):
            self.validate()
        (self.root / "docs/research/notes.md").unlink()
        (self.root / "docs/research").rmdir()
        self.write("docs/release-notes/v1.12.0.md", "old\n")
        with self.assertRaisesRegex(ValueError, "release notes"):
            self.validate()

    def test_private_document_reference_in_source_is_rejected(self) -> None:
        self.write("CONTRIBUTING.md", "See docs/performance/x.md and CLAUDE.md.\n")
        self.validate()
        for text in ("// see `docs/performance/x.md`\n", "/// per claude.md section 5\n", "// AGENTS.md rules\n"):
            self.write("Sources/Feature.swift", text)
            with self.assertRaisesRegex(ValueError, "reference to a private document in public source: Sources/Feature.swift"):
                self.validate()

    def test_non_utf8_source_is_skipped(self) -> None:
        (self.root / "Tests").mkdir()
        (self.root / "Tests/blob.bin").write_bytes(b"\xff\xfe CLAUDE.md")
        self.validate()

    def test_wrong_version_or_build_fails(self) -> None:
        self.write("project.yml", (self.root / "project.yml").read_text().replace("1.13.0", "1.12.1"))
        with self.assertRaisesRegex(ValueError, "MARKETING_VERSION"):
            self.validate()
        self.write("project.yml", (self.root / "project.yml").read_text().replace("1.12.1", "1.13.0"))
        with self.assertRaisesRegex(ValueError, "CURRENT_PROJECT_VERSION"):
            MODULE.validate_tree(self.root, "1.13.0", 45)
        for build in (1, 43):
            with self.subTest(build=build):
                with self.assertRaisesRegex(ValueError, "build number"):
                    MODULE.validate_tree(self.root, "1.13.0", build)
                result = subprocess.run(
                    ["python3", str(Path(__file__).with_name("validate-public-source.py")),
                     "--root", str(self.root), "--version", "1.13.0", "--build", str(build)],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("build number", result.stderr)

    def test_release_tag_requires_annotated_tag_and_exact_commit_subject(self) -> None:
        def git(*args: str) -> None:
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)
        git("init", "-q")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.invalid")
        git("add", "-A")
        git("commit", "-qm", "release: v1.13.0 (44)")
        git("tag", "-a", "v1.13.0", "-m", "release")
        self.assertEqual(MODULE.validate_tag(self.root, "v1.13.0"), ("1.13.0", 44))
        git("tag", "v1.12.0")
        with self.assertRaisesRegex(ValueError, "annotated"):
            MODULE.validate_tag(self.root, "v1.12.0")

    def test_old_readme_parent_is_rejected_but_orphan_root_passes(self) -> None:
        def git(*args: str) -> None:
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)
        # Existing valid fixture is an orphan source root and is accepted.
        git("init", "-q")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.invalid")
        git("add", "-A")
        git("commit", "-qm", "release: v1.13.0 (44)")
        git("tag", "-a", "v1.13.0", "-m", "release")
        self.assertEqual(MODULE.validate_tag(self.root, "v1.13.0"), ("1.13.0", 44))

        # Recreate history with a README-only legacy root before a valid-looking snapshot.
        other = self.root / "legacy"
        other.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=other, check=True)
        for key, value in (("user.name", "Test"), ("user.email", "test@example.invalid")):
            subprocess.run(["git", "config", key, value], cwd=other, check=True)
        (other / "README.md").write_text("legacy\n")
        subprocess.run(["git", "add", "README.md"], cwd=other, check=True)
        subprocess.run(["git", "commit", "-qm", "initial README"], cwd=other, check=True)
        for item in self.root.iterdir():
            if item.name == ".git" or item.name == "legacy":
                continue
            target = other / item.name
            shutil.copytree(item, target) if item.is_dir() else shutil.copy2(item, target)
        subprocess.run(["git", "add", "-A"], cwd=other, check=True)
        subprocess.run(["git", "commit", "-qm", "release: v1.13.0 (44)"], cwd=other, check=True)
        subprocess.run(["git", "tag", "-a", "v1.13.0", "-m", "release"], cwd=other, check=True)
        with self.assertRaisesRegex(ValueError, "root"):
            MODULE.validate_tag(other, "v1.13.0")

    def test_later_release_build_must_increase(self) -> None:
        for previous, current in ((44, 44), (46, 45)):
            with self.subTest(previous=previous, current=current), tempfile.TemporaryDirectory() as directory:
                repo = Path(directory)
                for item in self.root.iterdir():
                    if item.name == ".git":
                        continue
                    target = repo / item.name
                    shutil.copytree(item, target) if item.is_dir() else shutil.copy2(item, target)
                def git(*args: str) -> None:
                    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
                git("init", "-q")
                git("config", "user.name", "Test")
                git("config", "user.email", "test@example.invalid")
                project = (repo / "project.yml").read_text().replace("44", str(previous))
                (repo / "project.yml").write_text(project)
                git("add", "-A")
                git("commit", "-qm", f"release: v1.13.0 ({previous})")
                git("tag", "-a", "v1.13.0", "-m", "release")
                # A later commit contains the target build and version.
                project = (repo / "project.yml").read_text().replace("1.13.0", "1.13.1").replace(str(previous), str(current))
                (repo / "project.yml").write_text(project)
                git("add", "project.yml")
                git("commit", "-qm", f"release: v1.13.1 ({current})")
                git("tag", "-a", "v1.13.1", "-m", "release")
                with self.assertRaisesRegex(ValueError, "increase"):
                    MODULE.validate_tag(repo, "v1.13.1")


if __name__ == "__main__":
    unittest.main()
