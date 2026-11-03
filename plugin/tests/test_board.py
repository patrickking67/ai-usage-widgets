"""board.py against the spec fixtures.

Runs the script as a subprocess, the way the plugin's commands and hook do.
Assertions avoid anything that depends on the wall clock (fixtures age), so
they check shape and contract behaviour: vendors, notes, unknown vendors,
missing boards and the silent hook.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "plugin" / "scripts" / "board.py"
FIXTURES = ROOT / "spec" / "fixtures"


def run(*args, board=None, env_extra=None):
    env = dict(os.environ)
    env.pop("TOKENMETER_BOARD", None)
    if board is not None:
        env["TOKENMETER_BOARD"] = str(board)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=30)


class BoardTests(unittest.TestCase):
    def test_limits_lists_every_known_vendor(self):
        r = run("limits", board=FIXTURES / "demo-board.json")
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in ("Claude", "Codex", "GitHub Copilot", "Cursor"):
            self.assertIn(name, r.stdout)

    def test_note_is_printed_for_uncapped_lanes(self):
        r = run("limits", board=FIXTURES / "demo-board.json")
        self.assertIn("premium credits this month", r.stdout)

    def test_activity_accepts_30_days(self):
        r = run("activity", "--days", "30", board=FIXTURES / "demo-board.json")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.strip())

    def test_json_round_trips(self):
        r = run("json", board=FIXTURES / "demo-board.json")
        self.assertEqual(r.returncode, 0, r.stderr)
        json.loads(r.stdout)

    def test_budget_is_json(self):
        r = run("budget", board=FIXTURES / "demo-board.json")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsInstance(json.loads(r.stdout), dict)

    def test_unknown_vendor_is_skipped(self):
        board = json.loads((FIXTURES / "demo-board.json").read_text())
        board["providers"].append({"vendor": "mystery-ai", "account": "X", "meters": []})
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(board, f)
        try:
            r = run("limits", board=f.name)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn("mystery", r.stdout.lower())
        finally:
            os.unlink(f.name)

    def test_missing_board_exits_2(self):
        r = run("limits", board="/nonexistent/board.json")
        self.assertEqual(r.returncode, 2)

    def test_hook_never_fails(self):
        for board in ("/nonexistent/board.json", FIXTURES / "demo-board.json", FIXTURES / "board.json"):
            r = run("hook", board=board)
            self.assertEqual(r.returncode, 0, (board, r.stderr))


if __name__ == "__main__":
    unittest.main()
