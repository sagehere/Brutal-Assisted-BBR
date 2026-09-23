import unittest
from tools.p2.replay.compose_l05_evidence import compose


class ComposeL05EvidenceTest(unittest.TestCase):
    def test_both_subgates_and_revision_required(self):
        network = {"scenario": "l05-network", "status": "PASS", "candidate_commit": "abc"}
        host = {"scenario": "l05-host", "status": "PASS", "candidate_commit": "abc"}
        self.assertEqual(compose(network, host, "abc")["status"], "PASS")
        self.assertEqual(compose({**network, "status": "BLOCKED"}, host, "abc")["status"], "BLOCKED")
        self.assertEqual(compose(network, {**host, "status": "FAIL"}, "abc")["status"], "FAIL")
        self.assertEqual(compose(network, {**host, "candidate_commit": "old"}, "abc")["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
