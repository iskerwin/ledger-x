"""Validation boundaries, using only fictional files and local temporary repositories."""
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ship


class DemoSnapshotTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.demo = self.root/'.demo-data'
        self.demo.mkdir()
        self.git('init', '-q')
        (self.demo/'main.bean').write_text('; fictional snapshot\n')
        (self.demo/'.gitignore').write_text('ignored/\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fictional snapshot')
        self.commit = self.git('rev-parse', 'HEAD')
        (self.root/'tools/fixtures').mkdir(parents=True)
        (self.root/'tools/fixtures/manifest.json').write_text(json.dumps({'demoCommit': self.commit}))
        root_patch = patch.object(ship, 'ROOT', self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.demo), *args], text=True).strip()

    def test_demo_rejects_modified_staged_untracked_and_ignored_files_without_overwriting(self):
        for kind in ('modified', 'staged', 'untracked', 'ignored'):
            with self.subTest(kind=kind):
                path = self.demo/('main.bean' if kind in ('modified', 'staged') else
                                  'extra.bean' if kind == 'untracked' else 'ignored/extra.bean')
                path.parent.mkdir(exist_ok=True)
                path.write_text('; fictional local change\n')
                if kind == 'staged':
                    self.git('add', 'main.bean')
                with self.assertRaises(ship.Failure):
                    ship.demo_snapshot()
                self.assertEqual(path.read_text(), '; fictional local change\n')
                if kind in ('modified', 'staged'):
                    self.git('restore', '--staged', '--worktree', 'main.bean')
                else:
                    path.unlink()
                    if kind == 'ignored':
                        path.parent.rmdir()

    def test_clean_demo_selects_the_pinned_commit(self):
        self.assertEqual(ship.demo_snapshot(), self.commit)

    def test_demo_digest_detects_content_change_even_when_git_status_is_unchanged(self):
        digest = ship.verify_demo_snapshot(self.commit)
        self.git('update-index', '--assume-unchanged', 'main.bean')
        (self.demo/'main.bean').write_text('; fictional change hidden from git status')
        self.assertEqual(self.git('status', '--porcelain'), '')
        with self.assertRaises(ship.Failure):
            ship.verify_demo_snapshot(self.commit, digest)

    def test_changed_copy_is_rejected_before_compiling(self):
        original = ship.shutil.copytree
        for change_source in (False, True):
            with self.subTest(change_source=change_source):
                def copy(source, target, **kwargs):
                    original(source, target, **kwargs)
                    changed = source if change_source else target
                    (changed/'main.bean').write_text('; fictional copy-time change')
                (self.root/'Ledger').mkdir(exist_ok=True)
                with patch.object(ship.shutil, 'copytree', side_effect=copy), \
                     patch.object(ship, 'run') as run, patch.object(ship, 'step'):
                    with self.assertRaises(ship.Failure):
                        ship.build_ipa('1.0.0', '1', self.commit)
                    run.assert_not_called()
                self.git('restore', 'main.bean')

    def test_package_demo_contents_must_match_validation_evidence(self):
        folder = self.root/'package'
        folder.mkdir()
        with zipfile.ZipFile(folder/'Ledger.ipa', 'w') as archive:
            archive.writestr('Payload/Ledger.app/Info.plist', plistlib.dumps(dict(
                CFBundleShortVersionString='1.0.0', CFBundleVersion='1',
                CFBundleIdentifier='com.iskerwin.ledger')))
            archive.writestr('Payload/Ledger.app/Demo/main.bean', '; different fictional snapshot')
            archive.writestr('Payload/Ledger.app/_CodeSignature/CodeResources', 'fixture')
        data = (folder/'Ledger.ipa').read_bytes()
        manifest = dict(repository='example/app', source_sha='source', tree='tree',
                        version='1.0.0', build='1', sha256=hashlib.sha256(data).hexdigest(), size=len(data))
        proof = dict(validator='local', scope='build', source_sha='source', tree='tree',
                     static_checks=True, tools_tests=True, release_build=True,
                     demo_commit=self.commit, demo_sha256='0'*64)
        with self.assertRaises(ValueError):
            ship.verify_package(folder, manifest, proof, 'example/app')


if __name__ == '__main__':
    unittest.main()
