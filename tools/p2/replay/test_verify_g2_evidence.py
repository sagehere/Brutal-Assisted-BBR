import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).parents[1] / "verify-g2-evidence.py"
NAMES = ("l03", "l04", "l05", "l06", "l08_l09", "l10", "observe_resources", "lite_resources")


class G2EvidenceTest(unittest.TestCase):
    def run_check(self, manifest):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            return subprocess.run([sys.executable, str(CHECKER), str(path)], text=True, capture_output=True)

    def test_accepts_one_commit_with_all_artifacts(self):
        commit = "abcdef123456"
        manifest = {"candidate_commit": commit, "evidence": {
            name: {"status": "PASS", "commit": commit, "artifact": f"artifact/{name}"}
            for name in NAMES
        }}
        self.assertEqual(self.run_check(manifest).returncode, 0)

    def test_rejects_mixed_commit_and_blocked_case(self):
        commit = "abcdef123456"
        manifest = {"candidate_commit": commit, "evidence": {
            name: {"status": "PASS", "commit": commit, "artifact": f"artifact/{name}"}
            for name in NAMES
        }}
        manifest["evidence"]["l03"]["commit"] = "oldcommit"
        manifest["evidence"]["l05"]["status"] = "BLOCKED"
        self.assertNotEqual(self.run_check(manifest).returncode, 0)


if __name__ == "__main__":
    unittest.main()
