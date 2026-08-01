#!/usr/bin/env python3

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SketchUpProbeLockContractTest(unittest.TestCase):
    def test_probe_owns_global_and_sketchup_locks_and_only_kills_spawned_pid(self):
        script = (ROOT / "tools" / "run_skp_probe.ps1").read_text(encoding="utf-8")
        global_at = script.index("CAD-HOST-GLOBAL.lock")
        host_at = script.index("SKETCHUP-HOST.lock")
        spawn_at = script.index("Start-Process")
        self.assertLess(global_at, spawn_at)
        self.assertLess(host_at, spawn_at)
        self.assertIn("[System.IO.FileMode]::CreateNew", script)
        self.assertIn("RESOURCE_BOARD.md", script)
        self.assertIn("finally", script)
        self.assertIn("Stop-Process -Id $spawnedPid", script)
        self.assertNotIn("Stop-Process -Name", script)
        self.assertNotIn("taskkill /IM", script.lower())


if __name__ == "__main__":
    unittest.main()
