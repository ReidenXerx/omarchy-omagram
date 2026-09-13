"""omagram_sounds -- a quiet notification sound of its own for every person, made from who they are.

A person's sound is two or three soft pops on notes of a pentatonic scale picked from their Telegram id:
the same person always sounds the same, and two people rarely do. Pops, not chimes: low, round and over
in a moment. A high ringing tone startles, and heard all day it wears you down; a low short one is simply
noticed. The style is what makes the pop, and yours to choose. Everything is made here with the standard
library, into a short mono WAV.
"""
import array
import hashlib
import io
import math
import sys
import wave

sys.dont_write_bytecode = True

RATE = 32000                  # samples a second, far above anything these sounds hold
PEAK = 0.28                   # about -11 dBFS: a notification, not an alarm
LENGTH_MAX = 1.2              # seconds
FADE_OUT = 0.06               # seconds: every sound ends on a short fade, so nothing clicks
SCALE = (0, 2, 4, 7, 9)       # major pentatonic: any of its notes sound well together
STABLE = (0, 2, 3)            # its root, third and fifth: where a melody comes to rest
DEGREES = 8                   # the scale's notes over two octaves, less the top two
NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
STYLES = {"pop": "soft and round", "drop": "a drop of water", "knock": "a knuckle on wood"}
DEFAULT_STYLE = "drop"          # the user's pick, heard on the design page


class Dice:
    """SplitMix64 started from a text: a fixed algorithm, so nobody's sound changes with Python."""

    MASK = (1 << 64) - 1

    def __init__(self, text):
        self.state = int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], "big")

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def unit(self):
        return self.next() / float(1 << 64)

    def between(self, low, high):
        return low + (high - low) * self.unit()

    def pick(self, options):
        return options[self.next() % len(options)]


def midi_of(root, degree):
    return root + 12 * (degree // len(SCALE)) + SCALE[degree % len(SCALE)]


def note_name(midi):
    return f"{NOTE_NAMES[midi % 12]}{midi // 12 - 1}"


def motif(seed, variant=0):
    """This person's notes: which, when (seconds from the start) and how hard. `seed` is who they are,
    a Telegram id; `variant` gives them another sound when their first one is not liked. A style sounds
    the notes lower than they are written here (its `shift`)."""
    dice = Dice(f"omagram-sound:{seed}:{variant}")
    root = 62 + dice.next() % 11                        # the key: D4 up to C5, as written
    count = dice.pick((2, 2, 3, 3, 3))                   # two or three: enough to know who, not a tune to sit through
    gap = dice.between(0.085, 0.15)                      # seconds from one note to the next
    swing = dice.between(0.0, 0.3)                       # every second note a little late
    degrees = [dice.pick((0, 1, 2, 2, 3, 4))]
    for _ in range(count - 1):
        degrees.append(max(0, min(DEGREES - 1, degrees[-1] + dice.pick((-2, -1, 1, 1, 2, 2, 3)))))
    if degrees[-1] % len(SCALE) not in STABLE:           # come to rest on the nearest root, third or fifth
        degrees[-1] = dice.pick([d for d in (degrees[-1] + 1, degrees[-1] - 1)
                                 if 0 <= d < DEGREES and d % len(SCALE) in STABLE])
    if len(set(degrees)) == 1:                            # one note over and over is not a melody
        degrees[0] = degrees[0] + 1 if degrees[0] + 1 < DEGREES else degrees[0] - 1
    notes = []
    at = 0.0
    for i, degree in enumerate(degrees):
        if i:
            at += gap * (1 + swing if i % 2 else 1 - swing / 2)
        notes.append({"midi": midi_of(root, degree), "degree": degree, "at": round(at, 4),
                      "velocity": round(dice.between(0.72, 1.0), 3)})
    notes[-1]["velocity"] = max(notes[-1]["velocity"], 0.9)   # the last note carries the sound
    return {"seed": str(seed), "variant": variant, "root": root, "notes": notes}


# ---------------------------------------------------------------- what makes the pop

def _soft_noise(noise, cutoff):
    """White noise through a one-pole low-pass: a breath, with nothing hissing above `cutoff`."""
    a = math.exp(-2 * math.pi * cutoff / RATE)
    y = 0.0
    while True:
        y = (1 - a) * noise.between(-1.0, 1.0) + a * y
        yield y


def _pop(out, start, freq, velocity, ring, noise):
    """Pop: a breath of soft noise, then a round low tone that falls into its note as it starts -- chpok."""
    breath = _soft_noise(noise, 1500)
    lead = 0.005                                          # the tone comes just after the breath
    phase = 0.0
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        value = 1.2 * math.exp(-t / 0.004) * next(breath) if t < 0.02 else 0.0
        if t >= lead:
            u = t - lead
            phase += 2 * math.pi * freq * (1 + 0.5 * math.exp(-u / 0.008)) / RATE
            body = min(1.0, u / 0.002) * math.exp(-u / 0.04)
            value += body * (math.sin(phase) + 0.18 * math.exp(-u / 0.01) * math.sin(2 * phase))
        out[start + n] += velocity * value


def _drop(out, start, freq, velocity, ring, _noise):
    """Drop: a round tone that rises into its note, like a drop falling into water -- bloop."""
    phase = 0.0
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        phase += 2 * math.pi * freq * (1 - 0.3 * math.exp(-t / 0.02)) / RATE
        body = min(1.0, t / 0.004) * math.exp(-t / 0.055)
        out[start + n] += velocity * body * (math.sin(phase) + 0.1 * math.sin(2 * phase))


def _knock(out, start, freq, velocity, ring, noise):
    """Knock: a knuckle on a wooden table -- a short wooden tone over a soft thud."""
    modes = [(2 * math.pi * freq * ratio / RATE, level, tau)
             for ratio, level, tau in ((1.0, 1.0, 0.035), (2.57, 0.4, 0.014), (4.9, 0.12, 0.006))]
    thud = _soft_noise(noise, 700)
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        value = sum(level * math.exp(-t / tau) * math.sin(w * n) for w, level, tau in modes)
        if t < 0.03:
            value += 2.0 * math.exp(-t / 0.006) * next(thud)
        out[start + n] += velocity * min(1.0, t / 0.0008) * value


SHAPES = {   # how long a pop sounds, how far apart they fall, how much lower than written, where the top is softened
    "pop": {"voice": _pop, "ring": 0.25, "spacing": 1.0, "shift": -9, "cutoff": 3000},
    "drop": {"voice": _drop, "ring": 0.32, "spacing": 1.1, "shift": -5, "cutoff": 2400},
    "knock": {"voice": _knock, "ring": 0.2, "spacing": 0.95, "shift": -9, "cutoff": 3500},
}


# ---------------------------------------------------------------- the sound

def render(m, style):
    """A person's notes in a style: 16-bit mono WAV bytes, ready to play."""
    if style not in SHAPES:
        raise ValueError(f"no such style: {style}")
    shape = SHAPES[style]
    notes = m["notes"]
    last = notes[-1]["at"] * shape["spacing"]
    out = [0.0] * int(min(LENGTH_MAX, last + shape["ring"] + FADE_OUT) * RATE)
    noise = Dice(f"omagram-noise:{m['seed']}:{m['variant']}")
    for note in notes:
        start = int(note["at"] * shape["spacing"] * RATE)
        if start < len(out):
            freq = 440.0 * 2 ** ((note["midi"] + shape["shift"] - 69) / 12)
            shape["voice"](out, start, freq, note["velocity"], shape["ring"], noise)
    finish(out, shape["cutoff"])
    return wav_bytes(out)


def sound(seed, style, variant=0):
    return render(motif(seed, variant), style)


def finish(out, cutoff):
    """Softens the top, rounds the peaks, sets the level, and fades both ends so nothing clicks."""
    a = math.exp(-2 * math.pi * cutoff / RATE)
    y = 0.0
    for i, x in enumerate(out):
        y = (1 - a) * x + a * y
        out[i] = y
    peak = max((abs(v) for v in out), default=0.0) or 1.0
    for i, v in enumerate(out):
        out[i] = math.tanh(1.4 * v / peak) / math.tanh(1.4)
    peak = max((abs(v) for v in out), default=0.0) or 1.0
    total = len(out)
    fade_in = max(1, int(0.002 * RATE))
    fade_out = max(1, min(total, int(FADE_OUT * RATE)))
    for i in range(total):
        gain = PEAK / peak
        if i < fade_in:
            gain *= i / fade_in
        if i >= total - fade_out:
            gain *= 0.5 + 0.5 * math.cos(math.pi * (i - (total - fade_out) + 1) / fade_out)
        out[i] *= gain


def wav_bytes(samples):
    pcm = array.array("h", (int(round(max(-1.0, min(1.0, v)) * 32767)) for v in samples))
    if sys.byteorder == "big":
        pcm.byteswap()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    return buffer.getvalue()
