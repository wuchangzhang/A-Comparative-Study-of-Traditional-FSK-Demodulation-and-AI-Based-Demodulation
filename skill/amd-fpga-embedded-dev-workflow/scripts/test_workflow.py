"""Behavioral regression tests using disposable inputs, never the FPGA project."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

import workflow


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project"
        (self.root / "rtl").mkdir(parents=True)
        (self.root / "rtl/top.sv").write_text("module top; endmodule\n")
        self.spec = self.base / "spec.json"
        self.config = {"workspace_root": str(self.root), "files": ["rtl"],
                       "configuration": {"top": "top", "part": "xc7a35tcsg324-1",
                                         "tool_version": "2026.1", "compile_order": ["rtl/top.sv"],
                                         "defines": [], "include_dirs": [], "parameters": {},
                                         "test_scope": ["helper_regression_only"]}}

    def snap(self):
        self.spec.write_text(json.dumps(self.config), encoding="utf-8")
        return Path(workflow.snapshot(self.spec, self.base / "snapshot")["manifest"])

    def run_code(self, code, timeout=10):
        manifest = self.snap()
        command = self.base / "command.json"
        command.write_text(json.dumps({"argv": [sys.executable, "-c", code],
                                       "timeout_seconds": timeout}), encoding="utf-8")
        return workflow.run_command(manifest, command, self.base / "run")

    def test_snapshot_and_verify(self):
        self.assertTrue(workflow.verify(self.snap())["verified"])

    def test_changed_source_blocks(self):
        manifest = self.snap()
        (self.root / "rtl/top.sv").write_text("changed")
        with self.assertRaises(workflow.InputError):
            workflow.verify(manifest)

    def test_changed_snapshot_blocks(self):
        manifest = self.snap()
        (manifest.parent / "inputs/rtl/top.sv").write_text("changed")
        with self.assertRaises(workflow.InputError):
            workflow.verify(manifest)

    def test_added_dependency_blocks(self):
        manifest = self.snap()
        (self.root / "rtl/new.mem").write_text("01")
        with self.assertRaises(workflow.InputError):
            workflow.verify(manifest)

    def test_deleted_input_blocks(self):
        manifest = self.snap()
        (self.root / "rtl/top.sv").unlink()
        with self.assertRaises(workflow.InputError):
            workflow.verify(manifest)

    def test_configuration_tamper_blocks(self):
        manifest = self.snap()
        data = workflow.read_json(manifest)
        data["payload"]["configuration"]["top"] = "other"
        manifest.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaises(workflow.InputError):
            workflow.verify(manifest)

    def test_missing_file_blocks(self):
        self.config["files"] = ["missing.sv"]
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_wrong_version_blocks(self):
        self.config["configuration"]["tool_version"] = "2025.2"
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_missing_configuration_blocks(self):
        del self.config["configuration"]["top"]
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_unlisted_compile_input_blocks(self):
        self.config["configuration"]["compile_order"] = ["other.sv"]
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_outside_input_blocks(self):
        (self.base / "outside.sv").write_text("external")
        self.config["files"] = ["../outside.sv"]
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_no_overwrite(self):
        self.snap()
        with self.assertRaises(FileExistsError):
            workflow.snapshot(self.spec, self.base / "snapshot")

    def test_inventory_is_candidate_only(self):
        result = workflow.inventory(self.root)
        self.assertIn("rtl/top.sv", result["candidates"])
        self.assertFalse(result["complete"])

    def test_command_pass_is_not_acceptance(self):
        result = self.run_code("print('PASS')")
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["acceptance"], "not_evaluated")
        self.assertTrue(all(Path(a["path"]).is_file() for a in result["artifacts"]))

    def test_command_failure_preserved(self):
        result = self.run_code("import sys; print('failure', file=sys.stderr); sys.exit(7)")
        self.assertEqual(result["exit_code"], 4)
        self.assertEqual(result["process_returncode"], 7)

    def test_input_mutation_invalidates_command(self):
        result = self.run_code("from pathlib import Path; Path('rtl/top.sv').write_text('changed')")
        self.assertEqual(result["exit_code"], 2)

    def test_timeout_is_not_design_failure(self):
        result = self.run_code("import time; time.sleep(30)", timeout=0.2)
        self.assertEqual(result["exit_code"], 6)
        self.assertIn("Timeout", result["error"])

    def test_unicode_paths(self):
        self.root = self.root / "\u5de5\u7a0b"
        (self.root / "rtl").mkdir(parents=True)
        (self.root / "rtl/top.sv").write_text("module top; endmodule")
        self.config["workspace_root"] = str(self.root)
        self.assertTrue(workflow.verify(self.snap())["verified"])

    def test_malformed_configuration_blocks(self):
        self.config["configuration"]["compile_order"] = "rtl/top.sv"
        with self.assertRaises(workflow.InputError):
            self.snap()

    def test_empty_command_blocks_before_output(self):
        manifest = self.snap()
        command = self.base / "command.json"
        command.write_text(json.dumps({"argv": [], "timeout_seconds": 10}))
        with self.assertRaises(workflow.InputError):
            workflow.run_command(manifest, command, self.base / "run")
        self.assertFalse((self.base / "run").exists())

    def test_nonfinite_timeout_blocks(self):
        manifest = self.snap()
        command = self.base / "command.json"
        command.write_text(json.dumps({"argv": [sys.executable], "timeout_seconds": float("inf")}))
        with self.assertRaises(workflow.InputError):
            workflow.run_command(manifest, command, self.base / "run")

    def test_missing_executable_is_environment_failure(self):
        manifest = self.snap()
        command = self.base / "command.json"
        command.write_text(json.dumps({"argv": [str(self.base / "missing-tool")], "timeout_seconds": 10}))
        result = workflow.run_command(manifest, command, self.base / "run")
        self.assertEqual(result["exit_code"], 6)
        self.assertIsNone(result["process_returncode"])

    def test_snapshot_output_in_inputs_blocks(self):
        self.spec.write_text(json.dumps(self.config), encoding="utf-8")
        with self.assertRaises(workflow.InputError):
            workflow.snapshot(self.spec, self.root / "rtl/snapshot")
        self.assertFalse((self.root / "rtl/snapshot").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
