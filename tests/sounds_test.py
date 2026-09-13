#!/usr/bin/env python3
"""A sound of their own for every person: the same person always the same, people apart, every style quiet and clean."""
import array
import io
import pathlib
import sys
import unittest
import wave

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "bin"))
import omagram_sounds as sounds  # noqa: E402


def samples_of(data):
    with wave.open(io.BytesIO(data)) as w:
        shape = (w.getnchannels(), w.getsampwidth(), w.getframerate())
        frames = w.readframes(w.getnframes())
    pcm = array.array("h")
    pcm.frombytes(frames)
    if sys.byteorder == "big":
        pcm.byteswap()
    return shape, pcm


class Melodies(unittest.TestCase):
    def test_a_person_always_sounds_the_same_and_people_sound_apart(self):
        self.assertEqual(sounds.motif(184467), sounds.motif(184467))
        self.assertNotEqual(sounds.motif(184467), sounds.motif(184467, variant=1))
        melodies = {tuple((n["midi"], n["at"]) for n in sounds.motif(seed)["notes"]) for seed in range(1, 201)}
        self.assertGreater(len(melodies), 195)
        tunes = {tuple(n["midi"] for n in sounds.motif(seed)["notes"]) for seed in range(1, 201)}
        self.assertGreater(len(tunes), 120, "most people differ by the notes alone, not only their timing")

    def test_a_melody_is_a_few_notes_of_the_scale_and_comes_to_rest(self):
        for seed in range(1, 400):
            m = sounds.motif(seed)
            notes = m["notes"]
            self.assertTrue(2 <= len(notes) <= 4, seed)
            self.assertGreater(len({n["midi"] for n in notes}), 1, seed)
            self.assertEqual([n["at"] for n in notes], sorted(n["at"] for n in notes))
            for n in notes:
                self.assertIn((n["midi"] - m["root"]) % 12, sounds.SCALE, seed)
                self.assertTrue(62 <= n["midi"] <= 88, seed)
                self.assertTrue(0 <= n["degree"] < sounds.DEGREES)
            self.assertIn(notes[-1]["degree"] % 5, sounds.STABLE, seed)
            self.assertLess(notes[-1]["at"], 0.7)

    def test_note_names(self):
        self.assertEqual([sounds.note_name(m) for m in (60, 69, 61, 88)], ["C4", "A4", "C#4", "E6"])


class Rendering(unittest.TestCase):
    def test_every_style_makes_a_short_quiet_wav_with_no_click_at_either_end(self):
        for style in sounds.STYLES:
            shape, pcm = samples_of(sounds.sound(4242, style))
            self.assertEqual(shape, (1, 2, sounds.RATE), style)
            peak = max(abs(v) for v in pcm) / 32767
            self.assertTrue(0.2 <= peak <= sounds.PEAK + 0.005, (style, peak))
            self.assertTrue(0.15 <= len(pcm) / sounds.RATE <= sounds.LENGTH_MAX, (style, len(pcm)))
            self.assertLess(abs(pcm[0]) + abs(pcm[-1]), 60, style)

    def test_the_same_person_in_the_same_style_is_the_same_file(self):
        self.assertEqual(sounds.sound(77, "pluck"), sounds.sound(77, "pluck"))
        self.assertNotEqual(sounds.sound(77, "pluck"), sounds.sound(78, "pluck"))

    def test_an_unknown_style_is_refused(self):
        with self.assertRaises(ValueError):
            sounds.sound(1, "trumpet")


if __name__ == "__main__":
    unittest.main()
