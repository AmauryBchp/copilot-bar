#!/usr/bin/env python3
"""Unit tests for the pure-Python parts of the Ulauncher extension.
Run: python3 tests/test_ulauncher_main.py
"""
import importlib.util
import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN_PATH = os.path.join(REPO_ROOT, "ulauncher", "copilot-bar", "main.py")

spec = importlib.util.spec_from_file_location("copilot_bar_main", MAIN_PATH)
main = importlib.util.module_from_spec(spec)
# main.py only imports the ulauncher package inside `if __name__ == "__main__"`,
# so loading it as a library module never requires ulauncher to be installed.
spec.loader.exec_module(main)


class BuildItemsTests(unittest.TestCase):
    def test_drops_items_without_a_pid_and_falls_back_to_no_sessions(self):
        feed = {"items": [{"title": "No Copilot CLI sessions", "pid": None}]}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}],
        )

    def test_keeps_items_with_a_pid(self):
        feed = {
            "items": [
                {"title": "● arthur", "subtitle": "needs input · 3s · pid 123", "pid": "123"}
            ]
        }
        self.assertEqual(
            main.build_items(feed),
            [{"title": "● arthur", "subtitle": "needs input · 3s · pid 123", "pid": "123"}],
        )

    def test_missing_items_key_yields_no_sessions_row(self):
        self.assertEqual(
            main.build_items({}),
            [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}],
        )

    def test_missing_subtitle_defaults_to_empty_string(self):
        feed = {"items": [{"title": "◐ deltatom", "pid": "456"}]}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "◐ deltatom", "subtitle": "", "pid": "456"}],
        )

    def test_error_key_yields_one_unselectable_warning_row(self):
        feed = {"items": [], "error": "wmctrl not found in PATH"}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "copilot-bar: wmctrl not found in PATH", "subtitle": "", "pid": None}],
        )


class PathHelperTests(unittest.TestCase):
    def test_feed_path_points_at_bin_copilot_bar_feed(self):
        self.assertTrue(main.feed_path().endswith(os.path.join("bin", "copilot-bar-feed")))

    def test_focus_path_points_at_focus_copilot_focus_sh(self):
        self.assertTrue(
            main.focus_path().endswith(os.path.join("focus", "copilot_focus.sh"))
        )


if __name__ == "__main__":
    unittest.main()
