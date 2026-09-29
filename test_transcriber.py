"""
test_transcriber.py — unit tests for the pure helpers in transcriber.py.

These tests intentionally avoid downloading a Whisper model or touching audio,
so they run fast and offline. They validate the two pieces most likely to
regress: timecode formatting and Markdown assembly.

Run:  python3 test_transcriber.py
"""

import unittest

import transcriber


class TestFormatTimestamp(unittest.TestCase):
    def test_zero(self):
        self.assertEqual(transcriber.format_timestamp(0), "[00:00.000]")

    def test_seconds_and_millis(self):
        self.assertEqual(transcriber.format_timestamp(5.25), "[00:05.250]")

    def test_minutes(self):
        self.assertEqual(transcriber.format_timestamp(65.5), "[01:05.500]")

    def test_hours_rollover(self):
        # 1h 1m 1.001s
        self.assertEqual(transcriber.format_timestamp(3661.001), "[01:01:01.001]")

    def test_negative_clamped(self):
        self.assertEqual(transcriber.format_timestamp(-3), "[00:00.000]")


class TestSegmentsToMarkdown(unittest.TestCase):
    def test_empty_segments(self):
        md = transcriber.segments_to_markdown([], "song.wav")
        self.assertIn("# Lyrics — song.wav", md)
        self.assertIn("No speech or lyrics were detected", md)

    def test_segments_render_with_timecodes(self):
        segments = [
            {"start": 0.0, "end": 2.0, "text": " Hello world "},
            {"start": 2.0, "end": 4.5, "text": "second line"},
        ]
        md = transcriber.segments_to_markdown(
            segments, "/tmp/track.mp3", language="en", model_name="base"
        )
        self.assertIn("[00:00.000] Hello world", md)
        self.assertIn("[00:02.000] second line", md)
        self.assertIn("Detected language: `en`", md)
        self.assertIn("Model: `base`", md)

    def test_blank_text_segments_skipped(self):
        segments = [
            {"start": 0.0, "end": 1.0, "text": "   "},
            {"start": 1.0, "end": 2.0, "text": "kept"},
        ]
        md = transcriber.segments_to_markdown(segments, "a.wav")
        self.assertIn("[00:01.000] kept", md)
        self.assertNotIn("[00:00.000] ", md.replace("[00:00.000] kept", ""))


class TestCheckDependencies(unittest.TestCase):
    def test_returns_status_object(self):
        status = transcriber.check_dependencies()
        self.assertIsInstance(status, transcriber.DependencyStatus)
        self.assertIsInstance(status.ok, bool)
        self.assertIsInstance(status.message, str)
        self.assertTrue(len(status.message) > 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
