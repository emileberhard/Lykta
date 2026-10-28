import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("app_store_connect", str(Path(__file__).resolve().parents[1] / "app-store-connect"))
spec = importlib.util.spec_from_loader(loader.name, loader)
asc = importlib.util.module_from_spec(spec)
loader.exec_module(asc)


class ScreenshotProcessingTests(unittest.TestCase):
    def test_a_draft_screenshot_finishes_at_the_documented_parent_state(self):
        for state in ("ACTIVE", "PARENT_PREPARE_FOR_SUBMISSION"):
            with self.subTest(state=state):
                with patch.object(asc, "api", return_value={"attributes": {"state": state}}):
                    self.assertTrue(asc.processed_screenshots(["screenshot"]))

    def test_processing_is_pending_and_failed_processing_is_reported(self):
        with patch.object(asc, "api", return_value={"attributes": {"state": "ASSET_PROCESSING"}}):
            self.assertIsNone(asc.processed_screenshots(["screenshot"]))
        with patch.object(asc, "api", return_value={"attributes": {"state": "FAILED", "stateDetails": "Invalid image"}}):
            with self.assertRaisesRegex(SystemExit, "Invalid image"):
                asc.processed_screenshots(["screenshot"])


class BuildIdentityTests(unittest.TestCase):
    def test_pending_uploads_count_toward_the_next_global_build(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "10"}}],
            [{"attributes": {"cfBundleVersion": "12"}}],
        ]):
            self.assertEqual(13, asc.next_build_number("app"))

    def test_acceptance_filters_the_exact_uploaded_build(self):
        with patch.object(asc, "api", return_value=[]) as api:
            self.assertIsNone(asc.processed_build("app", "1.3.2", "11"))
            self.assertEqual("11", api.call_args_list[0].kwargs["filter[version]"])
            self.assertEqual("1.3.2", api.call_args_list[0].kwargs["filter[preReleaseVersion.version]"])

    def test_all_pages_are_read_before_selecting_a_build_number(self):
        pages = [
            {"data": [{"id": "first"}], "links": {"next": asc.API + "builds?cursor=next"}},
            {"data": [{"id": "last"}], "links": {"next": None}},
        ]
        with patch.object(asc, "token", return_value="fixture"), patch.object(asc, "send", side_effect=[json.dumps(p).encode() for p in pages]):
            self.assertEqual([{"id": "first"}, {"id": "last"}], asc.api("GET", "builds"))

    def test_rejected_upload_reports_the_exact_builds_errors(self):
        with patch.object(asc, "api", side_effect=[[], [{"attributes": {"state": {
            "state": "FAILED", "errors": [{"code": "ITMS-90626", "description": "Missing entitlement"}]
        }}}]]) as api:
            with self.assertRaisesRegex(SystemExit, r"1\.3\.2 \(11\).*ITMS-90626 Missing entitlement"):
                asc.processed_build("app", "1.3.2", "11")
            self.assertEqual("11", api.call_args.kwargs["filter[cfBundleVersion]"])


class ReviewPolicyTests(unittest.TestCase):
    def test_an_app_store_version_in_review_is_left_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "01.png").write_bytes(b"fixture image")
            with patch.object(asc, "api", return_value=[{"id": "review", "attributes": {
                "appVersionState": "WAITING_FOR_REVIEW", "versionString": "0.10.0"
            }}]) as api:
                asc.app_store("app", "0.14.3", "11", root, "notes")
                self.assertEqual(["GET"], [call.args[0] for call in api.call_args_list])

    def test_without_external_groups_no_beta_review_is_submitted(self):
        with patch.object(asc, "api", side_effect=[[{"id": "english"}], None, []]) as api:
            asc.submit_beta("app", "1.3.2", "build", "notes")
            self.assertFalse(any(call.args[0] == "POST" for call in api.call_args_list))


class UploadFenceTests(unittest.TestCase):
    def test_a_first_attempt_uploads_beside_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]) as existing, \
             patch.object(asc, "next_build_number", return_value=12):
            self.assertEqual((13, False), asc.reserve_build("app", "1.3.2", "13", fenced=False))
            existing.assert_not_called()

    def test_a_first_attempt_takes_a_newer_global_number_than_its_reservation(self):
        with patch.object(asc, "next_build_number", return_value=14), patch.object(asc.time, "sleep") as sleep:
            self.assertEqual((14, False), asc.reserve_build("app", "1.3.2", "13", fenced=False))
            sleep.assert_not_called()

    def test_a_fenced_rerun_waits_for_the_build_and_never_reserves_a_second_number(self):
        with patch.object(asc, "uploaded_build_numbers", side_effect=[[], [], ["12"]]), patch.object(asc, "next_build_number") as reserve, \
             patch.object(asc.time, "sleep"):
            self.assertEqual((12, True), asc.reserve_build("app", "1.3.2", "12", fenced=True))
            reserve.assert_not_called()

    def test_a_retry_never_selects_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]), \
             patch.object(asc.time, "sleep"), patch.object(asc.time, "monotonic", side_effect=[0, 901]):
            with self.assertRaisesRegex(SystemExit, "do not upload again blindly"):
                asc.reserve_build("app", "1.3.2", "12", fenced=True)

    def test_a_fenced_rerun_fails_when_no_build_appears(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=[]), patch.object(asc, "next_build_number") as reserve, \
             patch.object(asc.time, "sleep"), patch.object(asc.time, "monotonic", side_effect=[0, 1, 1000]):
            with self.assertRaisesRegex(SystemExit, "do not upload again"):
                asc.reserve_build("app", "1.3.2", "12", fenced=True)
            reserve.assert_not_called()

class UploadCleanupTests(unittest.TestCase):
    def test_cleanup_keeps_placed_images_and_only_deletes_owned_images(self):
        requests = []

        def api(method, path, **params):
            requests.append((method, path))
            if method == "GET":
                return {"relationships": {"placements": {"data": [{"id": "placement"}] if path.endswith("placed") else []}}}

        with patch.object(asc, "api", side_effect=api):
            asc.delete_unplaced(["placed", "reserved"])
        self.assertEqual([("DELETE", "appAssetLibraryImages/reserved")], [request for request in requests if request[0] == "DELETE"])
        self.assertTrue(all(path.startswith("appAssetLibraryImages/") for _, path in requests))

    def test_a_failed_transfer_reclaims_its_reserved_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "01.png").write_bytes(b"fixture image")
            reservation = {"id": "reserved", "attributes": {"uploadOperations": [
                {"url": "https://example.com/upload", "offset": 0, "length": 13, "method": "PUT", "requestHeaders": []}
            ]}}
            with patch.object(asc, "draft_version", return_value=("version", False)), \
                 patch.object(asc, "api", side_effect=[{"id": "library"}, reservation]), \
                 patch.object(asc, "send", side_effect=asc.RequestFailed("transfer failed")), \
                 patch.object(asc, "delete_unplaced") as cleanup:
                with self.assertRaisesRegex(asc.RequestFailed, "transfer failed"):
                    asc.app_store("app", "1.3.2", "11", root, "notes")
                cleanup.assert_called_once_with(["reserved"])
