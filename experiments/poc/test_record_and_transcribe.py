"""Offline audio/device checks; run with python -m unittest discover -s experiments/poc."""

import contextlib
import io
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy
import soundfile as sf

import record_and_transcribe as recording


class AudioResamplingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.microphone_path = Path(self.directory.name) / "microphone.flac"
        self.system_path = Path(self.directory.name) / "system.wav"
        self.output_path = Path(self.directory.name) / "mixed.flac"

    def write_tracks(self, rate_hz, channels, amplitude=0.3, start_seconds=100.0):
        microphone_samples = numpy.zeros(16000)
        microphone_samples[4000] = 0.8
        sf.write(self.microphone_path, microphone_samples, 16000, subtype="PCM_16")
        system_samples = amplitude * numpy.sin(2 * numpy.pi * 1000 * numpy.arange(rate_hz) / rate_hz)
        system_samples = numpy.repeat(system_samples[:, None], channels, axis=1)
        sf.write(self.system_path, system_samples, rate_hz, subtype="FLOAT")
        Path(str(self.system_path) + ".start").write_text(str(start_seconds))

    def test_required_formats_preserve_length_tone_and_alignment(self):
        for rate_hz, channels in [(16000, 1), (24000, 1), (44100, 2), (48000, 2), (8000, 1), (32000, 6)]:
            for offset_seconds in [0.0, 0.125, -0.125]:
                with self.subTest(rate_hz=rate_hz, channels=channels, offset=offset_seconds):
                    self.write_tracks(rate_hz, channels, start_seconds=100 + offset_seconds)
                    recording.mix_audio_tracks(self.microphone_path, self.system_path, 100, self.output_path)
                    mixed_samples, output_rate_hz = sf.read(self.output_path)
                    self.assertEqual(output_rate_hz, 16000)
                    expected_frames = 18000 if offset_seconds else 16000
                    self.assertLessEqual(abs(len(mixed_samples) - expected_frames), 1)
                    self.assertLessEqual(numpy.max(numpy.abs(mixed_samples)), 0.95)
                    microphone_frame = 4000 + (2000 if offset_seconds < 0 else 0)
                    self.assertGreater(mixed_samples[microphone_frame], 0.79)
                    system_frame = 2000 if offset_seconds > 0 else 0
                    if offset_seconds > 0:
                        numpy.testing.assert_array_equal(mixed_samples[:2000], numpy.zeros(2000))
                    if offset_seconds < 0:
                        self.assertGreater(numpy.max(numpy.abs(mixed_samples[:2000])), 0.1)
                    tone_samples = mixed_samples[system_frame + 8000:system_frame + 14400]
                    frequency_hz = numpy.fft.rfftfreq(len(tone_samples), 1 / 16000)
                    peak_hz = frequency_hz[numpy.argmax(numpy.abs(numpy.fft.rfft(tone_samples)))]
                    self.assertLessEqual(abs(peak_hz - 1000), 10)

    def test_multichannel_average_and_clipping(self):
        sf.write(self.microphone_path, numpy.full(16000, 0.8), 16000, subtype="PCM_16")
        system_samples = numpy.tile([0.2, 0.4, 0.6, 0.8], (24000, 1))
        sf.write(self.system_path, system_samples, 24000, subtype="FLOAT")
        Path(str(self.system_path) + ".start").write_text("100")
        recording.mix_audio_tracks(self.microphone_path, self.system_path, 100, self.output_path)
        mixed_samples, _ = sf.read(self.output_path)
        self.assertTrue(numpy.allclose(mixed_samples, numpy.floor(0.95 * 32768) / 32768))

    def test_channel_average_without_normalization(self):
        sf.write(self.microphone_path, numpy.zeros(16000), 16000, subtype="PCM_16")
        sf.write(self.system_path, numpy.tile([0.1, 0.2, 0.3, 0.4], (24000, 1)), 24000, subtype="FLOAT")
        Path(str(self.system_path) + ".start").write_text("100")
        recording.mix_audio_tracks(self.microphone_path, self.system_path, 100, self.output_path)
        mixed_samples, _ = sf.read(self.output_path)
        self.assertTrue(numpy.allclose(mixed_samples, 0.25, atol=1 / 32768))

    def test_resampler_short_empty_and_passthrough(self):
        for rate_hz in [8000, 16000, 24000, 44100, 48000]:
            with self.subTest(rate_hz=rate_hz):
                self.assertEqual(len(recording.resample_audio(numpy.array([]), rate_hz)), 0)
                samples = numpy.ones(7)
                converted_samples = recording.resample_audio(samples, rate_hz)
                self.assertEqual(len(converted_samples), round(7 * 16000 / rate_hz))
                self.assertTrue(numpy.allclose(converted_samples, 1))
        samples = numpy.arange(10, dtype="float32")
        numpy.testing.assert_array_equal(recording.resample_audio(samples, 16000), samples)

    def test_native_microphone_file_is_resampled(self):
        samples = 0.2 * numpy.sin(2 * numpy.pi * 1000 * numpy.arange(44100) / 44100)
        sf.write(self.microphone_path, samples, 44100, subtype="PCM_16")
        recording.resample_microphone_file(self.microphone_path, 44100)
        converted_samples, rate_hz = sf.read(self.microphone_path)
        self.assertEqual(rate_hz, 16000)
        self.assertEqual(len(converted_samples), 16000)
        frequency_hz = numpy.fft.rfftfreq(len(converted_samples), 1 / 16000)
        self.assertEqual(frequency_hz[numpy.argmax(abs(numpy.fft.rfft(converted_samples)))], 1000)

    def test_empty_system_keeps_microphone(self):
        self.write_tracks(16000, 1)
        sf.write(self.system_path, numpy.empty((0, 1)), 16000, subtype="FLOAT")
        Path(str(self.system_path) + ".start").unlink()
        recording.mix_audio_tracks(self.microphone_path, self.system_path, 100, self.output_path)
        microphone_samples, _ = sf.read(self.microphone_path)
        mixed_samples, _ = sf.read(self.output_path)
        numpy.testing.assert_array_equal(mixed_samples, microphone_samples)

    def test_capture_errors_warn_and_keep_readable_audio(self):
        self.write_tracks(24000, 1)
        Path(str(self.system_path) + ".log").write_text("Error: Write WAV failed\n")
        with contextlib.redirect_stdout(io.StringIO()) as messages:
            recording.inspect_system_capture(self.system_path, 110)
        self.assertIn("Warning:", messages.getvalue())
        self.assertIn("stopped", messages.getvalue())
        recording.mix_audio_tracks(self.microphone_path, self.system_path, 100, self.output_path)
        self.assertTrue(self.output_path.is_file())


class MicrophoneDeviceTests(unittest.TestCase):
    def setUp(self):
        self.devices = [
            {"index": 0, "name": "MacBook Pro Microphone", "max_input_channels": 1, "default_samplerate": 48000},
            {"index": 1, "name": "USB Headset", "max_input_channels": 2, "default_samplerate": 44100},
            {"index": 2, "name": "USB Speakers", "max_input_channels": 0, "default_samplerate": 48000},
            {"index": 3, "name": "USB Microphone", "max_input_channels": 1, "default_samplerate": 24000},
        ]

    def query_devices(self, kind=None):
        if kind == "input":
            return self.devices[0]
        if kind == "output":
            return self.devices[2]
        return self.devices

    def test_selection_uses_input_only_case_insensitive_substring(self):
        with patch.object(recording.sd, "query_devices", side_effect=self.query_devices):
            self.assertEqual(recording.select_microphone("hEaDsEt"), self.devices[1])
            self.assertEqual(recording.select_microphone(None), self.devices[0])
            for name in ["USB", "missing", "Speakers"]:
                with self.subTest(name=name), contextlib.redirect_stderr(io.StringIO()) as errors:
                    with self.assertRaises(SystemExit):
                        recording.select_microphone(name)
                    self.assertIn("MacBook Pro Microphone", errors.getvalue())
                    self.assertIn("USB Microphone", errors.getvalue())

    def test_list_devices_without_api_key(self):
        with patch.object(recording.sd, "query_devices", side_effect=self.query_devices):
            with patch("sys.argv", ["record_and_transcribe.py", "--list-devices"]):
                with patch.object(recording, "load_api_key") as api_key:
                    with contextlib.redirect_stdout(io.StringIO()) as messages:
                        recording.main()
                    api_key.assert_not_called()
                    self.assertIn("Default input: MacBook Pro Microphone", messages.getvalue())
                    self.assertIn("Default output: USB Speakers", messages.getvalue())

    def test_stream_retries_native_rate_and_uses_selected_device(self):
        with patch.object(recording.sd, "InputStream", side_effect=[recording.sd.PortAudioError("Unsupported rate"), object()]) as stream:
            with contextlib.redirect_stdout(io.StringIO()) as messages:
                recording.open_microphone_stream(self.devices[1], lambda *arguments: None)
            self.assertEqual([call.kwargs["samplerate"] for call in stream.call_args_list], [16000, 44100])
            self.assertEqual([call.kwargs["device"] for call in stream.call_args_list], [1, 1])
            self.assertIn("Unsupported rate", messages.getvalue())

    def test_native_capture_is_converted_in_both_recording_modes(self):
        for system_audio in [False, True]:
            with self.subTest(system_audio=system_audio), tempfile.TemporaryDirectory() as directory:
                output_path = Path(directory) / "microphone.flac"
                microphone_start = []
                native_samples = 6000 * numpy.sin(2 * numpy.pi * 1000 * numpy.arange(44100) / 44100)
                native_samples = native_samples.astype("int16")[:, None]

                def make_stream(**options):
                    if options["samplerate"] == 16000:
                        raise recording.sd.PortAudioError("Unsupported rate")
                    stream = unittest.mock.MagicMock()
                    stream.samplerate = 44100

                    def start_stream():
                        options["callback"](native_samples, len(native_samples),
                                            SimpleNamespace(currentTime=1, inputBufferAdcTime=0), None)
                        return stream

                    stream.__enter__.side_effect = start_stream
                    return stream

                with patch.object(recording.sd, "InputStream", side_effect=make_stream):
                    with patch.object(recording, "write_blocks_until_interrupt", return_value=0):
                        with contextlib.redirect_stdout(io.StringIO()):
                            sources = recording.record_until_interrupt(
                                output_path, microphone_start, (lambda: None) if system_audio else None,
                                self.devices[1],
                            )
                microphone_samples, rate_hz = sf.read(output_path)
                self.assertEqual(rate_hz, 16000)
                self.assertEqual(len(microphone_samples), 16000)
                self.assertEqual(sources, "mic: USB Headset (44100 Hz)")
                self.assertEqual(len(microphone_start), 1)
                if system_audio:
                    system_path = Path(directory) / "system.wav"
                    sf.write(system_path, numpy.zeros(24000), 24000, subtype="FLOAT")
                    Path(str(system_path) + ".start").write_text(str(microphone_start[0]))
                    mixed_path = Path(directory) / "mixed.flac"
                    recording.mix_audio_tracks(output_path, system_path, microphone_start[0], mixed_path)
                    mixed_samples, _ = sf.read(mixed_path)
                    numpy.testing.assert_array_equal(mixed_samples, microphone_samples)

    def test_header_includes_named_sources_and_capture_rates(self):
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "transcript.md"
            sources = "mic: MacBook Pro Microphone (44100 Hz); system: USB Headset (24000 Hz, 1 channels)"
            recording.write_transcript_markdown(output_path, {}, "audio.flac", datetime(2026, 10, 8), sources)
            self.assertIn(f"- Sources: {sources}\n", output_path.read_text())



class UploadEncodingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.directory_path = Path(self.directory.name)
        self.recordings_path = self.directory_path / "recordings"
        self.recordings_path.mkdir()
        patcher = patch.object(recording, "SCRIPT_DIRECTORY", self.directory_path)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.flac_path = self.recordings_path / "session.flac"
        time_axis_seconds = numpy.arange(16000 * 30) / 16000
        envelope = 0.5 + 0.5 * numpy.sin(2 * numpy.pi * 3 * time_axis_seconds)
        noise = numpy.random.default_rng(1).standard_normal(time_axis_seconds.size)
        samples = 0.3 * envelope * numpy.sin(2 * numpy.pi * 220 * time_axis_seconds) + 0.05 * noise
        sf.write(self.flac_path, samples.astype("float32"), 16000, format="FLAC", subtype="PCM_16")

    def test_opus_upload_is_smaller_and_near_64_kbps(self):
        if "OPUS" not in sf.available_subtypes("OGG"):
            self.skipTest("libsndfile was built without Opus support")
        with contextlib.redirect_stdout(io.StringIO()):
            upload = recording.prepare_upload(self.flac_path, "flac", lossless=False)
        self.assertEqual(upload.path, self.recordings_path / "session.upload.ogg")
        self.assertEqual(upload.audio_format, "ogg")
        self.assertTrue(upload.path.is_file())
        self.assertTrue(self.flac_path.is_file())
        self.assertLess(upload.path.stat().st_size, self.flac_path.stat().st_size)
        info = sf.info(upload.path)
        self.assertEqual(info.format, "OGG")
        self.assertEqual(info.samplerate, 16000)
        self.assertEqual(info.channels, 1)
        actual_kbps = recording.measure_kbps(upload.path.stat().st_size, info.duration)
        self.assertLessEqual(abs(actual_kbps / 64 - 1), 0.10)

    def test_lossless_sends_flac_without_encoding(self):
        with patch.object(recording, "encode_opus_upload") as encode:
            upload = recording.prepare_upload(self.flac_path, "flac", lossless=True)
        encode.assert_not_called()
        self.assertEqual(upload, recording.Upload(self.flac_path, "flac", "FLAC (lossless)"))

    def test_main_with_lossless_sends_flac_and_skips_encoding(self):
        arguments = ["record_and_transcribe.py", "--file", str(self.flac_path), "--lossless"]
        with patch("sys.argv", arguments), patch.object(recording, "load_api_key", return_value="key"):
            with patch.object(recording, "transcribe_audio", return_value={}) as transcribe:
                with patch.object(recording, "encode_opus_upload") as encode:
                    with contextlib.redirect_stdout(io.StringIO()):
                        recording.main()
        encode.assert_not_called()
        self.assertEqual(transcribe.call_args.args[0], self.flac_path.resolve())
        self.assertEqual(transcribe.call_args.args[1], "flac")

    def test_size_guard_applies_to_the_uploaded_file(self):
        oversized_path = self.recordings_path / "big.ogg"
        with open(oversized_path, "wb") as oversized_file:
            oversized_file.truncate(37_500_000)
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit):
                recording.ensure_audio_within_size_limit(oversized_path)
        self.assertIn("base64 JSON body", errors.getvalue())
        self.assertIn("52,428,800", errors.getvalue())
        self.assertIn("saved locally", errors.getvalue())

    def test_compressed_inputs_pass_through_unchanged(self):
        for audio_format in ["m4a", "mp3", "ogg"]:
            with self.subTest(audio_format=audio_format):
                source_path = self.recordings_path / f"memo.{audio_format}"
                source_path.write_bytes(b"not decoded")
                with patch.object(recording, "encode_opus_upload") as encode:
                    upload = recording.prepare_upload(source_path, audio_format, lossless=False)
                encode.assert_not_called()
                self.assertEqual(upload.path, source_path)
                self.assertEqual(upload.audio_format, audio_format)

    def test_encode_failure_falls_back_to_flac_with_warning(self):
        with patch.object(recording, "encode_opus_upload", side_effect=RuntimeError("no opus")):
            with contextlib.redirect_stdout(io.StringIO()) as messages:
                upload = recording.prepare_upload(self.flac_path, "flac", lossless=False)
        self.assertEqual(upload.path, self.flac_path)
        self.assertEqual(upload.audio_format, "flac")
        self.assertIn("Warning:", messages.getvalue())

    def test_calibration_reaches_each_target_on_probe(self):
        samples = numpy.random.default_rng(2).standard_normal(16000 * 90).astype("float32") * 0.1
        for target_bitrate_kbps in [64, 48, 32]:
            with self.subTest(target_bitrate_kbps=target_bitrate_kbps):
                level = recording.calibrate_opus_compression_level(samples, target_bitrate_kbps)
                self.assertTrue(0.0 <= level <= 1.0)
                probe_samples = samples[:16000 * recording.OPUS_CALIBRATION_SECONDS]
                encoded_bytes = recording.encode_opus_bytes(probe_samples, level)
                actual_kbps = recording.measure_kbps(len(encoded_bytes), len(probe_samples) / 16000)
                self.assertLessEqual(abs(actual_kbps / target_bitrate_kbps - 1), 0.10)

    def test_duration_selects_encoder_target_and_upload_label(self):
        for duration_minutes, target_bitrate_kbps in [(59, 64), (60, 64), (61, 48), (90, 48), (91, 32)]:
            with self.subTest(duration_minutes=duration_minutes):
                mono_samples = unittest.mock.MagicMock()
                mono_samples.size = duration_minutes * 60 * 16000
                mono_samples.__len__.return_value = mono_samples.size
                with patch.object(recording, "resample_audio", return_value=mono_samples):
                    with patch.object(recording, "calibrate_opus_compression_level", return_value=0.5) as calibrate:
                        with patch.object(recording, "encode_opus_bytes", return_value=b"encoded"):
                            with contextlib.redirect_stdout(io.StringIO()):
                                upload = recording.prepare_upload(self.flac_path, "flac", lossless=False)
                calibrate.assert_called_once_with(mono_samples, target_bitrate_kbps)
                self.assertEqual(upload.codec_label, f"Opus ~{target_bitrate_kbps} kbps")
                self.assertEqual(upload.path.read_bytes(), b"encoded")

    def test_body_estimate_rounds_up_base64_groups_and_adds_overhead(self):
        for file_bytes, base64_bytes in [(0, 0), (1, 4), (2, 4), (3, 4), (4, 8), (37_500_000, 50_000_000)]:
            with self.subTest(file_bytes=file_bytes):
                self.assertEqual(recording.estimate_request_body_bytes(file_bytes), base64_bytes + 1024)

    def test_size_guard_accepts_safety_boundary_and_rejects_next_group(self):
        upload_path = self.recordings_path / "boundary.ogg"
        largest_audio_bytes = (50_000_000 - 1024) // 4 * 3
        with upload_path.open("wb") as upload_file:
            upload_file.truncate(largest_audio_bytes)
        recording.ensure_audio_within_size_limit(upload_path)
        with upload_path.open("wb") as upload_file:
            upload_file.truncate(largest_audio_bytes + 1)
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit):
                recording.ensure_audio_within_size_limit(upload_path)
        self.assertIn("50,000,000", errors.getvalue())


class LongAudioWarningTests(unittest.TestCase):
    def run_warning(self, duration_seconds):
        with patch.object(recording, "audio_duration_seconds", return_value=duration_seconds):
            with contextlib.redirect_stdout(io.StringIO()) as messages:
                recording.warn_if_audio_exceeds_recommended_length(Path("session.flac"))
        return messages.getvalue()

    def test_warns_only_above_tested_length(self):
        self.assertEqual(
            self.run_warning(91 * 60),
            "Recording is longer than 90 minutes (beyond tested length); it may time out. "
            "The full recording is saved locally.\n",
        )
        for duration_minutes in [20, 35, 36, 59, 60, 61, 90]:
            with self.subTest(duration_minutes=duration_minutes):
                self.assertEqual(self.run_warning(duration_minutes * 60), "")
        self.assertIn("beyond tested length", self.run_warning(90 * 60 + 1))

    def test_unreadable_duration_skips_warning_without_error(self):
        with patch.object(recording, "audio_duration_seconds", return_value=None):
            with contextlib.redirect_stdout(io.StringIO()) as messages:
                recording.warn_if_audio_exceeds_recommended_length(Path("memo.m4a"))
        self.assertIn("skipped", messages.getvalue())


class TranscriptionResponseTests(unittest.TestCase):
    def test_http_200_error_fails_clearly_without_success_message(self):
        for provider_error in [{"message": "Provider returned 524", "code": 524}, "Provider returned 524", None]:
            with self.subTest(provider_error=provider_error), tempfile.TemporaryDirectory() as directory:
                upload_path = Path(directory) / "session.ogg"
                upload_path.write_bytes(b"audio")
                response = unittest.mock.Mock(status_code=200)
                response.json.return_value = {"error": provider_error}
                with patch.object(recording, "post_with_retries", return_value=response) as request:
                    with contextlib.redirect_stdout(io.StringIO()) as messages:
                        with contextlib.redirect_stderr(io.StringIO()) as errors:
                            with self.assertRaises(SystemExit):
                                recording.transcribe_audio(upload_path, "ogg", "key", recording.ELEVENLABS_SCRIBE_V2_MODEL, None)
                self.assertIn("provider timed out or errored", errors.getvalue())
                self.assertIn("recording is saved locally", errors.getvalue())
                if provider_error is not None:
                    self.assertIn("Provider returned 524", errors.getvalue())
                self.assertNotIn("Transcription complete", messages.getvalue())
                request.assert_called_once()
                self.assertEqual(upload_path.read_bytes(), b"audio")

    def test_http_200_transcript_passes_through(self):
        with tempfile.TemporaryDirectory() as directory:
            upload_path = Path(directory) / "session.ogg"
            upload_path.write_bytes(b"audio")
            response = unittest.mock.Mock(status_code=200)
            response.json.return_value = {"text": "Hello", "words": []}
            with patch.object(recording, "post_with_retries", return_value=response):
                with contextlib.redirect_stdout(io.StringIO()):
                    transcript = recording.transcribe_audio(upload_path, "ogg", "key", recording.ELEVENLABS_SCRIBE_V2_MODEL, None)
            self.assertEqual(transcript, {"text": "Hello", "words": []})


class UploadDescriptionTests(unittest.TestCase):
    def test_header_shows_upload_format_size_and_latency(self):
        with tempfile.TemporaryDirectory() as directory:
            upload_path = Path(directory) / "session.upload.ogg"
            upload_path.write_bytes(b"x" * 1_500_000)
            upload = recording.Upload(upload_path, "ogg", "Opus ~64 kbps")
            description = recording.describe_upload(upload, 27.13)
            self.assertEqual(description, "Opus ~64 kbps, 1.50 MB, request took 27.1 s")
            output_path = Path(directory) / "transcript.md"
            recording.write_transcript_markdown(
                output_path, {}, "session.flac", datetime(2026, 10, 8), upload_description=description
            )
            self.assertIn(f"- Upload: {description}\n", output_path.read_text())

if __name__ == "__main__":
    unittest.main()
