#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1] / "app" / "ddos_detector.py"
SPEC = importlib.util.spec_from_file_location("ddos_detector", MODULE)
detector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(detector)
CFG = {"window_seconds": 10, "packet_threshold": 1000, "syn_threshold": 200,
       "unique_ip_threshold": 5, "candidate_min_packets": 20,
       "cooldown_seconds": 60, "max_ai_candidates": 1}


class ClassificationTest(unittest.TestCase):
    def test_below_threshold(self):
        self.assertEqual(detector.analyze(["198.51.100.1 S"] * 19, CFG), [])

    def test_single_source_syn_flood(self):
        events = detector.analyze(["198.51.100.23 S"] * 200, CFG)
        self.assertEqual(events[0]["attack_category"], "dos_syn_flood")
        self.assertEqual(events[0]["severity"], "high")

    def test_distributed_syn_flood(self):
        samples = [f"198.51.100.{index} S" for index in range(1, 6) for _ in range(40)]
        events = detector.analyze(samples, CFG)
        self.assertEqual(events[0]["attack_category"], "ddos_syn_flood")
        self.assertEqual(events[0]["evidence"]["unique_source_ips"], 5)

    def test_invalid_samples_are_ignored(self):
        self.assertEqual(detector.analyze(["garbage", "999.1.1.1 S"], CFG), [])


if __name__ == "__main__":
    unittest.main()
