"""Shell-policy tests only: stub producer is NOT rendering/device evidence."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CasePolicyTests(unittest.TestCase):
    def run_case(self, value=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).resolve().parents[1] / 'deploy/run-a21-case.sh', root / 'run-a21-case.sh')
            (root / 'SOURCE.txt').write_text('SYNTHETIC shell policy test; NOT rendering evidence\n')
            (root / 'run-gl-remote-present.sh').write_text('#!/bin/sh\nprintf "STUB producer args: %s\\n" "$*"\n')
            command = ['bash', str(root / 'run-a21-case.sh'), '12', str(root / 'new-case')]
            if value is not None:
                command.append(str(value))
            result = subprocess.run(command, text=True, capture_output=True)
            return result, (root / 'new-case').exists()

    def test_default_observation_is_30_with_explicit_cleanup_margin(self):
        result, exists = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(exists)
        self.assertIn('observation_s=30 resource_hold_s=35', result.stdout)
        self.assertIn('wait quiet_s >= 30', result.stdout)
        self.assertIn('--hold-seconds 35', result.stdout)

    def test_longer_cases_and_upper_boundary(self):
        for target, resource_hold in ((60, 65), (120, 125), (3600, 3600)):
            result, _ = self.run_case(target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'observation_s={target} resource_hold_s={resource_hold}', result.stdout)

    def test_invalid_duration_is_rejected_before_creating_evidence(self):
        for value in ('0', '29', '3601', '30.5', '0030', 'nan', '-1', '999999999999999999999'):
            result, exists = self.run_case(value)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(exists)
