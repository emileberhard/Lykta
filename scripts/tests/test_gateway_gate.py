import contextlib
import importlib.machinery
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("gateway_gate", str(Path(__file__).resolve().parents[1] / "wait-for-gateway"))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


class GatewayGateTests(unittest.TestCase):
    def run_gate(self, versions, states, context="lykta-gateway/0.16.0"):
        elapsed = 0
        versions = iter(versions)
        states = iter(states)
        running = None
        state = None

        def sleep(seconds):
            nonlocal elapsed
            elapsed += seconds

        def response(command, **kwargs):
            nonlocal running, state
            if command[0] == "curl":
                running = next(versions, running)
                return json.dumps({"version": running})
            state = next(states, state)
            return json.dumps([[]] if state is None else [[{"context": context, "state": state, "description": "host deploy result"}]])

        with patch.object(gate.time, "monotonic", side_effect=lambda: elapsed), \
             patch.object(gate.time, "sleep", side_effect=sleep), \
             patch.object(gate.subprocess, "check_output", side_effect=response), \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                gate.wait("0.16.0", "gateway.example", "owner/repo", "a" * 40)
            except SystemExit as error:
                return str(error), elapsed
        return None, elapsed

    def test_compatible_public_version_allows_upload(self):
        for version in ("0.16.0", "0.16.1", "0.17.0"):
            with self.subTest(version=version):
                self.assertEqual((None, 0), self.run_gate([version], ["failure"]))

    def test_explicit_deploy_failure_stops_without_waiting(self):
        for state in ("failure", "error"):
            with self.subTest(state=state):
                error, elapsed = self.run_gate(["0.15.0"], [state])
                self.assertIn("host deploy result", error)
                self.assertEqual(0, elapsed)

    def test_in_progress_deploy_waits_until_public_version_is_compatible(self):
        self.assertEqual((None, 20), self.run_gate(["0.15.0", "0.15.0", "0.16.0"], ["pending", "success"]))

    def test_success_receipt_missing_receipt_and_invalid_public_version_never_allow_upload(self):
        for version, state in (("0.15.0", "success"), ("0.15.0", None), (None, "success"), ("unknown", "success")):
            with self.subTest(version=version, state=state):
                error, elapsed = self.run_gate([version], [state])
                self.assertIn("No compatible public gateway", error)
                self.assertEqual(60, elapsed)

    def test_genuinely_running_deploy_still_has_a_deadline(self):
        error, elapsed = self.run_gate(["0.15.0"], ["pending"])
        self.assertIn("within 30 minutes", error)
        self.assertEqual(1800, elapsed)

    def test_another_versions_receipt_cannot_decide_this_release(self):
        error, elapsed = self.run_gate(["0.15.0"], ["failure"], context="lykta-gateway/0.15.0")
        self.assertIn("deploy result is missing", error)
        self.assertEqual(60, elapsed)
