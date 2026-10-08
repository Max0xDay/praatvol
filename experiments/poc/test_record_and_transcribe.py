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


if __name__ == "__main__":
    unittest.main()
