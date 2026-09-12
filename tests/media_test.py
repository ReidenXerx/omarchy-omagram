#!/usr/bin/python3
"""python3 tests/media_test.py -- omagram_media without a microphone, camera or ffmpeg run."""
import base64
import os
import pathlib
import shutil
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import omagram_media as media  # noqa: E402
import omagram_state as model  # noqa: E402
import plugin_safety as safe  # noqa: E402


class Waveform(unittest.TestCase):
    def test_round_trip_with_the_decoder_the_window_uses(self):
        levels = [0, 31, 5, 17, 9] * 20
        encoded = base64.b64encode(media.waveform_bytes(levels)).decode()
        self.assertEqual(model.waveform(encoded, bars=100), levels)

    def test_values_are_clamped(self):
        encoded = base64.b64encode(media.waveform_bytes([40, -3, 12])).decode()
        self.assertEqual(model.waveform(encoded, bars=3), [31, 0, 12])

    def test_levels_follow_the_loudness(self):
        quiet = struct.pack("<400h", *([100] * 400))
        loud = struct.pack("<400h", *([-30000] * 400))
        self.assertEqual(media.levels_from_pcm(quiet + loud, samples=2), [0, 31])
        self.assertEqual(media.levels_from_pcm(b"", samples=10), [])
        self.assertEqual(len(media.levels_from_pcm(quiet, samples=100)), 100)
        self.assertEqual(media.levels_from_pcm(struct.pack("<3h", 0, 0, 0), samples=100), [0, 0, 0])


class Recordings(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-media-", dir=safe.runtime_dir()))
        self.addCleanup(shutil.rmtree, self.root, True)
        patch = mock.patch.object(media, "REC", self.root / "rec")
        patch.start()
        self.addCleanup(patch.stop)

    def test_only_regular_files_in_the_recording_directory(self):
        rec = media.rec_dir()
        self.assertEqual(os.stat(rec).st_mode & 0o777, 0o700)
        good = media.new_path("note", ".mp4")
        good.write_bytes(b"recorded")
        self.assertEqual(media.recorded_file(str(good)), good)
        outside = self.root / "outside.mp4"
        outside.write_bytes(b"x")
        link = rec / "link.mp4"
        link.symlink_to(outside)
        empty = rec / "empty.mp4"
        empty.write_bytes(b"")
        (rec / "dir.mp4").mkdir()
        for bad in (str(outside), str(link), str(empty), str(rec / "dir.mp4"), str(rec / "missing.mp4"),
                    "note.mp4", str(rec) + "/../outside.mp4", str(good) + "\0", None, 5):
            with self.assertRaises((safe.UnsafeError, OSError), msg=repr(bad)):
                media.recorded_file(bad)

    def test_remove_and_clean_touch_only_the_recording_directory(self):
        rec = media.rec_dir()
        old = rec / "voice-old.ogg"
        new = rec / "voice-new.ogg"
        old.write_bytes(b"x")
        new.write_bytes(b"x")
        past = time.time() - 2 * media.STALE_SECONDS
        os.utime(old, (past, past))
        outside = self.root / "keep.txt"
        outside.write_bytes(b"x")
        media.clean_stale()
        self.assertEqual((old.exists(), new.exists()), (False, True))
        media.remove(outside)
        self.assertTrue(outside.exists())
        media.remove(new)
        media.remove(new)   # already gone: no error
        self.assertFalse(new.exists())

    def test_commands_are_argument_lists_of_absolute_tools(self):
        with mock.patch.object(safe, "tool", lambda name: pathlib.Path("/usr/bin") / name):
            voice = media.voice_argv(self.root / "rec" / "voice-1.ogg")
            note = media.video_note_argv("/in.mp4", "/out.mp4")
        self.assertEqual(voice[0], "/usr/bin/ffmpeg")
        for part in ("pulse", "libopus", "ogg"):
            self.assertIn(part, voice)
        self.assertEqual(voice[-1], str(self.root / "rec" / "voice-1.ogg"))
        self.assertEqual((note[0], note[-1]), ("/usr/bin/ffmpeg", "/out.mp4"))
        self.assertIn(str(media.NOTE_MAX_SECONDS), note)
        self.assertTrue(any(f"scale={media.NOTE_SIZE}:{media.NOTE_SIZE}" in part for part in note))


if __name__ == "__main__":
    unittest.main(verbosity=1)
