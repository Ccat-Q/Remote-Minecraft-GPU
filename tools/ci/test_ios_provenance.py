import unittest
from ios_provenance import pins_from_source, revision_from_log


class ProvenanceTests(unittest.TestCase):
    def test_actual_log_revision_not_workflow_default(self):
        sha = "a" * 40
        self.assertEqual(revision_from_log(f"env UTM_REVISION: {sha}\nUTM_REVISION: {sha}"), sha)
        for log in ("", f"UTM_REVISION: {sha}\nUTM_REVISION: {'b' * 40}"):
            with self.assertRaises(ValueError):
                revision_from_log(log)

    def test_all_dependency_pins_required(self):
        source = '\n'.join(f'{name}_COMMIT="{"b" * 40}"' for name in ("VIRGLRENDERER", "WEBKIT", "EPOXY"))
        self.assertEqual(len(pins_from_source(source)), 3)
        with self.assertRaises(ValueError):
            pins_from_source(source.replace("EPOXY_COMMIT", "WRONG_COMMIT"))
