import json
from pathlib import Path
import subprocess
import unittest


class TapLatencyTests(unittest.TestCase):
    def test_distinguishes_tap_observation_and_push_fallback(self):
        def event(index, time, name, side="gateway", **detail):
            return {"seq": index, "at": f"2026-11-27T15:32:{time}Z", "name": name,
                    "source": side, "activity": "activity-id", "detail": detail}

        data = {"events": [
            event(1, "00.000", "activity.action", "app", action="11111111-first", button="volume-up", processAgeMs=8120),
            event(2, "00.080", "activity.action", action="11111111-first", button="volume-up", ms=6, seq=40, stamp=1, fingerprint="one"),
            event(3, "00.104", "activity.tapUpdate", "app", action="11111111-first", outcome="called", to="one",
                  inSync=False, requestMs=100, updateMs=4, dnsMs=0, connectMs=0, tlsMs=0, reusedConnection=True),
            event(4, "00.140", "activity.content", "app", source="tap", fingerprint="one"),
            event(5, "00.700", "activity.put", cursor=40, kept=["volume", "level"]),
            event(6, "01.000", "activity.action", "app", action="22222222-second", button="input-mac", processAgeMs=310),
            event(7, "01.100", "activity.action", action="22222222-second", button="input-mac", ms=5, seq=41, stamp=2, fingerprint="two"),
            event(8, "01.120", "activity.tapUpdate", "app", action="22222222-second", outcome="called", to="two", inSync=True),
            event(9, "01.300", "push.update", outcome="accepted", fingerprint="two", priority=10, reason="tap", ms=100, idleMs=900),
            event(10, "01.450", "activity.content", "app", source="push", fingerprint="two"),
            event(11, "02.000", "push.update", outcome="accepted", fingerprint="three", priority=10, reason="interval", ms=100),
            event(12, "00.600", "push.update", outcome="accepted", fingerprint="one", priority=10, reason="tap", ms=100),
            event(13, "02.200", "push.update", outcome="accepted", fingerprint="one", priority=10, reason="tap", ms=100),
            event(14, "02.400", "activity.content", "app", source="tap", fingerprint="one"),
        ]}
        result = subprocess.run([str(Path(__file__).resolve().parents[1] / "tap-latency")],
                                input=json.dumps(data), text=True, capture_output=True, check=True).stdout
        first, second = result.splitlines()[1:3]
        self.assertRegex(first, r"11111111 +volume-up.*tap \+140.*\+620, kept 2")
        self.assertRegex(second, r"22222222 +input-mac.*push \+450.*10/100/900")
        self.assertIn("taps 2 · shown by tap 1 · called but shown only by a push 1", result)
        self.assertIn("priority-10 updates never reported 1", result)
        self.assertIn("priority-10 pushes for content a tap had already shown 1", result)
        self.assertIn("seq 11", result)
        self.assertNotIn("seq 12", result)
        self.assertNotIn("seq 13", result)
