"""Static release regressions: describe changes accurately without re-listing history."""
import importlib.util
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_notes', ROOT / 'tools/release/release_notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
PROOF = dict(core_tests=308, interaction_tests=32, xcode='Xcode 27.1 Build version 27A9275', simulator='iPhone 17 · iOS 27.0')
BASE = '## 1.0.0（开发中）\n\n### 新增\n- 原有功能。\n\n### 开发与验证\n- 不向用户重复列出的内部流程。\n'


class ReleaseNotesTests(unittest.TestCase):
    def render(self, current=BASE, previous='', channel='dev'):
        return notes.render(current, previous, 'example/ledger-x', 'a' * 40, '1.0.0', '7.2', PROOF, channel)

    def test_first_release_lists_all_current_changes(self):
        text = self.render()
        self.assertIn('- 原有功能。', text)
        self.assertNotIn('内部流程', text)
        self.assertIn('构建 7.2', text)
        self.assertIn('手机验收待 Kerwin', text)
        self.assertIn('核心测试 308 项', text)
        self.assertIn('交互测试 32 项', text)

    def test_release_uses_release_source_and_records_acceptance(self):
        text = self.render(channel='release')
        self.assertIn('Ledger X 1.0.0 正式版', text)
        self.assertIn('添加正式版 IPA 源', text)
        self.assertIn('/ipa/release.json', text)
        self.assertNotIn('/ipa/dev.json', text)
        self.assertIn('手机验收已由 Kerwin 完成', text)

    def test_build_only_dev_does_not_claim_full_tests_passed(self):
        proof = dict(scope='build', xcode='Xcode 27.1')
        text = notes.render(BASE, '', 'example/ledger-x', 'a'*40, '1.0.0', '8', proof)
        self.assertIn('本次发布未运行核心、Beancount 报表对照和界面全量测试', text)
        self.assertIn('Release 编译', text)
        self.assertIn('手机验收待 Kerwin', text)
        self.assertNotIn('核心测试 308 项', text)
        self.assertNotIn('本机验证通过：', text)

    def test_only_delta_and_nonempty_categories_appear(self):
        current = BASE.replace('- 原有功能。', '- 原有功能。\n- 新功能。') + '\n### 修复\n- 修复保存失败。\n'
        text = self.render(current, BASE)
        self.assertIn('- 新功能。', text)
        self.assertIn('- 修复保存失败。', text)
        self.assertNotIn('- 原有功能。', text)
        self.assertNotIn('## 改进', text)

    def test_rebuild_does_not_repeat_old_features(self):
        text = self.render(BASE, BASE)
        self.assertIn('没有新增用户可见', text)
        self.assertNotIn('- 原有功能。', text)

    def test_new_version_and_legacy_category(self):
        self.assertEqual(notes.changes(BASE, '## 0.0.1\n### 新增\n- 旧版本。', '1.0.0')['新增'], ['原有功能。'])
        self.assertEqual(notes.entries(BASE.replace('### 新增', '### 新功能'), '1.0.0')['新增'], ['原有功能。'])
        with self.assertRaises(ValueError):
            notes.entries(BASE, '0.1.1')

    def test_sources_use_actual_repository_and_no_ipa_download_in_notes(self):
        text = self.render()
        self.assertIn('- GitHub：https://raw.githubusercontent.com/example/ledger-x/ipa/dev.json', text)
        self.assertIn('- 镜像（gh-proxy.com）：https://gh-proxy.com/https://raw.githubusercontent.com/example/ledger-x/ipa/mirror/dev.json', text)
        self.assertNotIn('下载 Ledger.ipa', text)
        self.assertNotIn('/releases/download/', text)
        self.assertNotIn('IPA 源', text.split('\n---\n')[0])

    def test_only_missing_previous_release_is_treated_as_first_publish(self):
        with patch.object(notes.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)')):
            self.assertEqual(notes.previous_changelog('example/ledger-x'), '')
        with patch.object(notes.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'HTTP 403')):
            with self.assertRaises(RuntimeError): notes.previous_changelog('example/ledger-x')

    def test_source_feed_contains_changes_and_preserves_required_download_url(self):
        body = self.render()
        ipa = 'https://github.com/example/ledger-x/releases/download/dev/Ledger.ipa'
        release = dict(tag_name='dev', body=body, published_at='2026-10-20T00:00:00Z', assets=[
            dict(name='Ledger.ipa', browser_download_url=ipa, size=123)])
        with tempfile.TemporaryDirectory() as folder, patch('sys.argv', ['ipa_source.py', 'example/ledger-x', folder]), \
             patch('subprocess.check_output', side_effect=['abcdef012345', 'abc\trefs/tags/dev\n', json.dumps([[release]])]), patch('builtins.print'):
            runpy.run_path(str(ROOT / 'tools/release/ipa_source.py'))
            source = json.loads(Path(folder, 'dev.json').read_text())
            mirror = json.loads(Path(folder, 'mirror/dev.json').read_text())
            files = sorted(str(p.relative_to(folder)) for p in Path(folder).rglob('*.json'))
        self.assertEqual(files, ['dev.json', 'mirror/dev.json', 'mirror/release.json', 'release.json'])
        version = source['apps'][0]['versions'][0]
        self.assertIn('原有功能。', version['localizedDescription'])
        self.assertNotIn('IPA 源', version['localizedDescription'])
        self.assertEqual(version['version'], '1.0.0')
        self.assertEqual(version['buildVersion'], '7.2')
        self.assertEqual(version['downloadURL'], ipa)
        self.assertEqual(source['identifier'], 'com.example.ledger-x.dev')
        self.assertEqual(source['sourceURL'], 'https://raw.githubusercontent.com/example/ledger-x/ipa/dev.json')
        # The mirror variant routes every address through gh-proxy.com and is a separate source.
        mirrored = mirror['apps'][0]['versions'][0]
        self.assertEqual(mirrored['downloadURL'], f'https://gh-proxy.com/{ipa}?v=1.0.0-7.2')
        self.assertEqual(mirror['apps'][0]['downloadURL'], mirrored['downloadURL'])
        self.assertEqual(mirror['sourceURL'], 'https://gh-proxy.com/https://raw.githubusercontent.com/example/ledger-x/ipa/mirror/dev.json')
        self.assertTrue(mirror['iconURL'].startswith('https://gh-proxy.com/https://raw.githubusercontent.com/'))
        self.assertEqual(mirror['identifier'], 'com.example.ledger-x.dev.mirror')
        self.assertNotIn('gh-proxy', json.dumps(source))
    def test_notes_give_the_ipa_sha256(self):
        text = notes.render(BASE, '', 'example/ledger-x', 'a' * 40, '1.0.0', '7.2', PROOF, 'dev', ipa_sha256='b' * 64)
        self.assertIn('安装包 SHA256：`' + 'b' * 64 + '`', text)
