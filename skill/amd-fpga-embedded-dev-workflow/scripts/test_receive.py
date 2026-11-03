import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import receive_check as receipt
import workflow


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def files(self, names):
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture', encoding='utf-8')

    def fixture(self):
        return ['reproduction.md', 'input_snapshot/src/rtl/top.sv', 'input_snapshot/sim/tb_top.sv',
                'input_snapshot/board/pins.xdc', 'input_snapshot/build/build.tcl',
                'evidence/input_sha256_before.csv']

    def test_empty_blocks_without_tool_calls(self):
        with patch.object(workflow.subprocess, 'Popen', side_effect=AssertionError('tool started')):
            result = receipt.inspect(self.root)
        self.assertEqual(result['reason'], 'empty_input')
        self.assertFalse(result['tool_probe_allowed'])
        self.assertEqual(result['exit_code'], 2)

    def test_missing_path_blocks(self):
        self.assertEqual(receipt.inspect(self.root / 'missing')['reason'], 'input_unreadable')

    def test_hidden_file_is_counted(self):
        self.files(['.hidden'])
        result = receipt.inspect(self.root)
        self.assertEqual(result['file_count'], 1)
        self.assertEqual(result['reason'], 'missing_guide')

    def test_valid_candidates_require_review(self):
        self.files(self.fixture())
        result = receipt.inspect(self.root)
        self.assertEqual(result['status'], 'ready_for_review')
        self.assertFalse(result['complete'])
        self.assertFalse(result['tool_probe_allowed'])

    def test_amd_readme_root(self):
        self.files(['README.md'] + self.fixture()[1:])
        result = receipt.inspect(self.root)
        self.assertEqual(result['guide_candidates'], ['README.md'])
        self.assertEqual(result['exit_code'], 0)

    def test_amd_readme_in_wrapped_zip(self):
        path = self.make_zip(['project/README.md'] + ['project/' + n for n in self.fixture()[1:]])
        result = receipt.inspect(path)
        self.assertEqual(result['selected_root'], 'project')
        self.assertEqual(result['exit_code'], 0)

    def test_skill_readme_is_not_project_guide(self):
        self.files(['skill/README.md', 'skill/validation/reproduction.md'])
        self.assertEqual(receipt.inspect(self.root)['reason'], 'missing_guide')

    def test_nested_root_found(self):
        self.files(['wrapper/run/' + name for name in self.fixture()])
        result = receipt.inspect(self.root)
        self.assertEqual(result['selected_root'], 'wrapper/run')
        self.assertEqual(result['exit_code'], 0)

    def test_multiple_runs_need_selection(self):
        self.files(['one/' + name for name in self.fixture()] + ['two/' + name for name in self.fixture()])
        self.assertEqual(receipt.inspect(self.root)['reason'], 'ambiguous_roots')

    def test_resume_guide_does_not_override_top(self):
        self.files(self.fixture() + ['evidence/resume_01/reproduction.md'])
        self.assertEqual(receipt.inspect(self.root)['guide_candidates'], ['reproduction.md'])

    def test_skill_fixtures_not_counted_as_project(self):
        self.files(['reproduction.md'] + ['skill/validation/inputs/' + name for name in self.fixture()])
        result = receipt.inspect(self.root)
        self.assertEqual(result['reason'], 'incomplete_run')
        self.assertIn('rtl', result['missing_items'])
        self.assertIn('manifests', result['missing_items'])

    def test_handoff_alone_is_incomplete(self):
        self.files(['reproduction.md', 'evidence/handoff_01/reproduce.py', 'evidence/handoff_01/handoff_manifest.json'])
        self.assertEqual(receipt.inspect(self.root)['reason'], 'incomplete_run')

    def test_output_archive_is_not_baseline(self):
        self.files(['reproduction_review.md', 'preflight_evidence/tool_version.json'])
        self.assertEqual(receipt.inspect(self.root)['reason'], 'missing_guide')

    def make_zip(self, names):
        path = self.root / 'input.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name in names:
                archive.writestr(name, 'fixture')
        return path

    def test_zip_read_without_extraction(self):
        path = self.make_zip(['run/' + n for n in self.fixture()])
        result = receipt.inspect(path)
        self.assertEqual(result['status'], 'ready_for_review')
        self.assertEqual(result['input_kind'], 'zip')
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_zip_traversal_rejected(self):
        result = receipt.inspect(self.make_zip(['../evil.v']))
        self.assertEqual(result['reason'], 'input_unreadable')

    def test_zip_absolute_rejected(self):
        self.assertEqual(receipt.inspect(self.make_zip(['/evil.v']))['reason'], 'input_unreadable')

    def test_zip_drive_rejected(self):
        self.assertEqual(receipt.inspect(self.make_zip(['C:/evil.v']))['reason'], 'input_unreadable')

    def test_case_collisions_rejected(self):
        self.assertEqual(receipt.inspect(self.make_zip(['a.v', 'A.v']))['reason'], 'input_unreadable')

    def test_directory_limit(self):
        self.files(self.fixture())
        self.assertEqual(receipt.inspect(self.root, limit=2)['reason'], 'input_unreadable')

    def test_zip_limit(self):
        self.assertEqual(receipt.inspect(self.make_zip(self.fixture()), limit=2)['reason'], 'input_unreadable')

    def test_nested_zip_requires_extraction(self):
        path = self.make_zip(self.fixture())
        self.assertEqual(receipt.inspect(self.root)['reason'], 'missing_guide')

    def test_symlink_zip_rejected(self):
        path = self.root / 'link.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            info = zipfile.ZipInfo('link')
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, 'outside')
        self.assertEqual(receipt.inspect(path)['reason'], 'input_unreadable')


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.log = Path(self.temp.name) / 'version.log'
        self.banner = 'vivado v2026.1 (64-bit)\nSW Build 6511674\nIP Build 6504888\nSharedData Build 6501428\n'

    def parse(self, text=None, code=0):
        self.log.write_text(self.banner if text is None else text, encoding='utf-8')
        return workflow.parse_version(self.log, code)

    def test_lowercase_banner(self):
        self.assertEqual(self.parse()['actual_release'], '2026.1')

    def test_uppercase_banner(self):
        self.assertEqual(self.parse(self.banner.upper())['exit_code'], 0)

    def test_nonzero_banner_is_identity_only(self):
        result = self.parse(code=1)
        self.assertEqual(result['exit_code'], 0)
        self.assertTrue(result['returncode_anomaly'])
        self.assertFalse(result['startup_validated'])
        self.assertFalse(result['synthesis_license_validated'])

    def test_other_release_blocks(self):
        self.assertEqual(self.parse(self.banner.replace('2026.1', '2025.2'))['exit_code'], 3)

    def test_partial_banner_blocks(self):
        self.assertEqual(self.parse('vivado v2026.1\n')['exit_code'], 3)

    def test_conflicting_release_blocks(self):
        self.assertEqual(self.parse(self.banner + '\nVivado v2025.2')['exit_code'], 3)

    def test_startup_error_blocks_even_with_banner(self):
        self.assertEqual(self.parse(self.banner + '\nERROR: [Common 17-39] load_features failed', code=1)['exit_code'], 3)

    def test_unexpected_returncode_blocks(self):
        self.assertEqual(self.parse(code=9)['exit_code'], 3)

    def test_log_integrity_recorded(self):
        result = self.parse()
        self.assertEqual(result['raw_log_sha256'], workflow.digest(self.log))

    def test_powershell_utf16_little_endian_banner(self):
        self.log.write_bytes(self.banner.encode('utf-16'))
        result = workflow.parse_version(self.log, 1)
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['log_encoding'], 'utf-16')

    def test_utf16_big_endian_banner(self):
        self.log.write_bytes(b'\xfe\xff' + self.banner.encode('utf-16-be'))
        self.assertEqual(workflow.parse_version(self.log, 1)['exit_code'], 0)

    def test_unknown_encoding_is_not_silently_replaced(self):
        self.log.write_bytes(b'\x81\x90vivado v2026.1')
        with self.assertRaises(UnicodeError):
            workflow.parse_version(self.log, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
