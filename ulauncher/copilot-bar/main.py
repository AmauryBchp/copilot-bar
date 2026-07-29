#!/usr/bin/env python3
"""Ulauncher extension: list live Copilot CLI sessions, focus on Enter.

Delegates all state logic to bin/copilot-bar-feed (itself built on
lib/state.sh) rather than re-implementing the state machine in Python — one
implementation, read from two renderers (Argos and this extension).

build_items() and the path helpers below have no dependency on the ulauncher
package, so they can be unit tested directly (tests/test_ulauncher_main.py)
without installing Ulauncher itself.
"""
import json
import os
import subprocess

EXTENSION_DIR = os.path.dirname(os.path.realpath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(EXTENSION_DIR))


def feed_path():
    return os.path.join(REPO_ROOT, "bin", "copilot-bar-feed")


def focus_path():
    return os.path.join(REPO_ROOT, "focus", "copilot_focus.sh")


def build_items(feed_json):
    """Turn bin/copilot-bar-feed's JSON into a list of {title, subtitle, pid}.

    A feed reporting a missing jq/wmctrl surfaces as one unselectable
    "copilot-bar: <error>" row, matching the Argos renderer's behavior of
    showing an explicit warning rather than a misleading empty list. A feed
    with no live sessions surfaces as one unselectable "No Copilot CLI
    sessions" row. Both cases use pid None so ItemEnterEventListener knows
    not to try to focus anything for them.
    """
    if feed_json.get("error"):
        return [{"title": f"copilot-bar: {feed_json['error']}", "subtitle": "", "pid": None}]

    items = [
        {"title": it["title"], "subtitle": it.get("subtitle", ""), "pid": it["pid"]}
        for it in feed_json.get("items", [])
        if it.get("pid")
    ]
    return items or [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}]


def fetch_items():
    try:
        result = subprocess.run(
            [feed_path()], capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return [{"title": "copilot-bar: failed to run copilot-bar-feed", "subtitle": "", "pid": None}]

    try:
        feed_json = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return [{"title": "copilot-bar: copilot-bar-feed returned invalid JSON", "subtitle": "", "pid": None}]

    return build_items(feed_json)


def focus(pid):
    subprocess.Popen(
        [focus_path(), str(pid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


if __name__ == "__main__":
    from ulauncher.api.client.Extension import Extension
    from ulauncher.api.client.EventListener import EventListener
    from ulauncher.api.shared.event import KeywordQueryEvent, ItemEnterEvent
    from ulauncher.api.shared.item.ExtensionResultItem import ExtensionResultItem
    from ulauncher.api.shared.action.RenderResultListAction import RenderResultListAction
    from ulauncher.api.shared.action.HideWindowAction import HideWindowAction
    from ulauncher.api.shared.action.ExtensionCustomAction import ExtensionCustomAction

    class CopilotBarExtension(Extension):
        def __init__(self):
            super().__init__()
            self.subscribe(KeywordQueryEvent, KeywordQueryEventListener())
            self.subscribe(ItemEnterEvent, ItemEnterEventListener())

    class KeywordQueryEventListener(EventListener):
        def on_event(self, event, extension):
            result_items = [
                ExtensionResultItem(
                    icon="images/icon.png",
                    name=item["title"],
                    description=item["subtitle"],
                    on_enter=(
                        ExtensionCustomAction({"pid": item["pid"]}, keep_app_open=False)
                        if item["pid"]
                        else HideWindowAction()
                    ),
                )
                for item in fetch_items()
            ]
            return RenderResultListAction(result_items)

    class ItemEnterEventListener(EventListener):
        def on_event(self, event, extension):
            data = event.get_data()
            pid = data.get("pid")
            if pid:
                focus(pid)
            return HideWindowAction()

    CopilotBarExtension().run()
