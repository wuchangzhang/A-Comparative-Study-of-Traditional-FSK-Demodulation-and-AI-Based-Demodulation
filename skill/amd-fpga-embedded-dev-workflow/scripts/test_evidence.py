import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import evidence
import workflow


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'run'
        (self.root / 'src').mkdir(parents=True)
        (self.root / 'src/top.sv').write_bytes(b'module top; endmodule\n')
        (self.root / 'src/rom.mem').write_bytes(b'01\n')
        self.manifest = self.base / 'before.jsonl'

    def make(self, output=None, selections=None, exclusions=()):
        return evidence.make_manifest(self.root, output or self.manifest, selections or ['src'], exclusions)

    def test_complete_manifest_verifies(self):
        self.make()
        self.assertEqual(evidence.verify(self.root, self.manifest)['verified_files'], 2)

    def test_partial_manifest_never_verifies(self):
        self.make()
        self.manifest.write_bytes(self.manifest.read_bytes().splitlines(keepends=True)[0])
        with self.assertRaises(workflow.InputError):
            evidence.verify(self.root, self.manifest)

    def test_missing_file_blocks(self):
        self.make()
        (self.root / 'src/top.sv').unlink()
        with self.assertRaises(workflow.InputError):
            evidence.verify(self.root, self.manifest)

    def test_changed_file_blocks(self):
        self.make()
        (self.root / 'src/top.sv').write_bytes(b'changed')
        with self.assertRaises(workflow.InputError):
            evidence.verify(self.root, self.manifest)

    def test_manifest_tamper_detected(self):
        self.make()
        self.manifest.write_bytes(self.manifest.read_bytes().replace(b'"file_count":2', b'"file_count":9'))
        with self.assertRaises(workflow.InputError):
            evidence.verify(self.root, self.manifest)

    def test_no_overwrite(self):
        self.make()
        with self.assertRaises(FileExistsError):
            self.make()

    def test_explicit_exclusions_recorded(self):
        (self.root / 'src/large.wdb').write_bytes(b'waveform')
        self.make(exclusions=['*.wdb'])
        header = next(evidence.rows(self.manifest))
        self.assertEqual(header['exclusions'], ['*.wdb'])
        self.assertEqual(evidence.verify(self.root, self.manifest)['verified_files'], 2)

    def test_internal_manifest_excludes_itself(self):
        manifest = self.root / 'manifest.jsonl'
        self.make(manifest, ['.'])
        self.assertEqual(evidence.verify(self.root, manifest)['verified_files'], 2)
        self.assertEqual(next(evidence.rows(manifest))['self_excluded'], 'manifest.jsonl')

    def test_overlapping_selections_deduplicated(self):
        self.make(selections=['src', 'src/top.sv'])
        self.assertEqual(evidence.verify(self.root, self.manifest)['verified_files'], 2)

    def test_manifest_outside_selected_subtree_does_not_change_policy(self):
        self.make()
        other = self.root / 'after.jsonl'
        self.make(other)
        self.assertIsNone(next(evidence.rows(other))['self_excluded'])
        self.assertEqual(evidence.compare(self.manifest, other)['exit_code'], 0)

    def test_scope_changes_cannot_be_compared(self):
        self.make()
        other = self.base / 'after.jsonl'
        self.make(other, ['.'])
        with self.assertRaises(workflow.InputError):
            evidence.compare(self.manifest, other)

    def test_output_files_do_not_pollute_fixed_input_scope(self):
        self.make()
        (self.root / 'sim').mkdir()
        (self.root / 'sim/generated.log').write_text('new output')
        other = self.base / 'after.jsonl'
        self.make(other)
        self.assertEqual(evidence.compare(self.manifest, other)['exit_code'], 0)

    def test_unexpected_change_blocks(self):
        self.make()
        (self.root / 'src/top.sv').write_bytes(b'changed')
        other = self.base / 'after.jsonl'
        self.make(other)
        self.assertEqual(evidence.compare(self.manifest, other)['exit_code'], 2)

    def test_allowed_patch_is_reported_not_simulation_pass(self):
        self.make()
        (self.root / 'src/top.sv').write_bytes(b'changed')
        other = self.base / 'after.jsonl'
        self.make(other)
        result = evidence.compare(self.manifest, other, ['src/top.sv'])
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['changed'], ['src/top.sv'])
        self.assertIn('not a simulation', result['scope'])

    def test_new_input_requires_review(self):
        self.make()
        (self.root / 'src/new.mem').write_bytes(b'02')
        other = self.base / 'after.jsonl'
        self.make(other)
        self.assertEqual(evidence.compare(self.manifest, other)['added'], ['src/new.mem'])

    def test_removed_input_blocks(self):
        self.make()
        (self.root / 'src/rom.mem').unlink()
        other = self.base / 'after.jsonl'
        self.make(other)
        self.assertEqual(evidence.compare(self.manifest, other)['removed'], ['src/rom.mem'])

    def archive(self, corrupt=False, omit=False, prefix=''):
        path = self.base / 'out.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name in ('src/top.sv', 'src/rom.mem'):
                if omit and name.endswith('.mem'):
                    continue
                data = (self.root / name).read_bytes()
                archive.writestr(prefix + name, data[:-1] + b'x' if corrupt else data)
        return path

    def test_zip_member_bytes_verified(self):
        self.make()
        result = evidence.verify_zip(self.archive(), self.manifest)
        self.assertEqual(result['verified_archive_files'], 2)
        self.assertEqual(result['scope'], 'listed_members_only')

    def test_zip_prefix_supports_packaging_root(self):
        self.make()
        self.assertEqual(evidence.verify_zip(self.archive(prefix='run/'), self.manifest, 'run')['verified_archive_files'], 2)

    def test_zip_same_size_corruption_blocks(self):
        self.make()
        with self.assertRaises(workflow.InputError):
            evidence.verify_zip(self.archive(corrupt=True), self.manifest)

    def test_zip_missing_member_blocks(self):
        self.make()
        with self.assertRaises(workflow.InputError):
            evidence.verify_zip(self.archive(omit=True), self.manifest)

    def test_escape_selection_rejected(self):
        with self.assertRaises(workflow.InputError):
            self.make(selections=['../outside'])

    def test_large_file_is_hashed_in_chunks(self):
        (self.root / 'src/large.bin').write_bytes(b'x' * 3145729)
        self.make()
        self.assertEqual(evidence.verify(self.root, self.manifest)['verified_files'], 3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
