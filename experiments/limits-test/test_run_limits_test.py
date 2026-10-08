"""Offline regression tests; never send requests or read the API key."""

import unittest
from types import SimpleNamespace
from tempfile import TemporaryDirectory
from pathlib import Path
from unittest.mock import patch

import run_limits_test


class ResponseClassificationTests(unittest.TestCase):
    def test_http_200_error_is_failure(self):
        for body in ('{"error":{"code":524}}', '{"error":{},"text":"partial"}'):
            with self.subTest(body=body):
                self.assertEqual(
                    run_limits_test.classify_outcome(200, body), "provider_error_in_200"
                )

    def test_valid_transcript_is_success(self):
        self.assertEqual(run_limits_test.classify_outcome(200, '{"text":"speech"}'), "success")
        self.assertEqual(
            run_limits_test.classify_outcome(200, '{"words":[{"end":3600}]}'), "success"
        )

    def test_http_200_without_transcript_is_failure(self):
        for body in ('{}', '[]', 'not json', '{"usage":{"seconds":3600}}',
                     '{"text":"","words":[]}'):
            with self.subTest(body=body):
                self.assertEqual(run_limits_test.classify_outcome(200, body), "missing_transcript")

    def test_http_200_error_body_is_recorded(self):
        record = {"audio_duration_seconds": 3600}
        response = SimpleNamespace(status_code=200, text='{"error":{"code":524}}', headers={})
        with TemporaryDirectory() as directory:
            run_limits_test.record_response(record, response, 148, 0, Path(directory) / "response.json")
        self.assertEqual(record["error_body"], response.text)
        self.assertIsNone(record["success_summary"])

    def test_complete_transcript_and_half_hour_speakers(self):
        words = [
            {"start": 10, "end": 11, "speaker": 0},
            {"start": 1799, "end": 1800, "speaker": 1},
            {"start": 1801, "end": 1802, "speaker": 2},
            {"start": 3594, "end": 3595, "speaker": 0},
        ]
        summary = run_limits_test.summarise_success({"words": words}, 3600)
        self.assertTrue(summary["transcript_reaches_end"])
        self.assertEqual(summary["speaker_count_per_30_minutes"], {0: 2, 1: 2})
        self.assertEqual(summary["speaker_count"], 3)
        self.assertEqual(summary["end_gap_seconds"], 5)

    def test_truncated_transcript_is_not_complete(self):
        summary = run_limits_test.summarise_success(
            {"words": [{"start": 100, "end": 101, "speaker": 0}]}, 3600
        )
        self.assertFalse(summary["transcript_reaches_end"])
        self.assertEqual(summary["end_gap_seconds"], 3499)

    def test_timeout_trigger_checks_provider_error(self):
        self.assertTrue(run_limits_test.is_timeout_failure({
            "outcome": "provider_error_in_200", "error_body": '{"error":{"code":524}}'
        }))
        self.assertFalse(run_limits_test.is_timeout_failure({
            "outcome": "success", "error_body": None
        }))
        self.assertFalse(run_limits_test.is_timeout_failure({
            "outcome": "http_error", "error_body": "Unauthorized"
        }))

    def test_error_body_limit_is_bytes(self):
        error_body = run_limits_test.limited_error_body("é" * 2048)
        self.assertEqual(len(error_body.encode("utf-8")), 2048)

    def test_successful_test_four_does_not_trigger_test_six(self):
        with patch.object(run_limits_test, "run_test", return_value={"outcome": "success"}) as run_test:
            run_limits_test.run_sequence("unused", [])
        self.assertEqual([call.args[0] for call in run_test.call_args_list], ["test4", "test5"])
        self.assertEqual(run_test.call_args_list[1].kwargs["maximum_size_bytes"], 52_428_800)

    def test_timeout_test_four_triggers_test_six_after_test_five(self):
        with patch.object(run_limits_test, "run_test", return_value={
            "outcome": "provider_error_in_200", "error_body": "Provider returned 524"
        }) as run_test:
            run_limits_test.run_sequence("unused", [])
        self.assertEqual(
            [call.args[0] for call in run_test.call_args_list], ["test4", "test5", "test6"]
        )
        self.assertEqual(run_test.call_args_list[2].args[2:4], (2400, 64))


if __name__ == "__main__":
    unittest.main()
