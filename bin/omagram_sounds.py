"""omagram_sounds -- a quiet notification sound of its own for every person, made from who they are.

A person's sound is two to four notes of a pentatonic scale picked from their Telegram id: the same
person always sounds the same, and two people rarely do. The style is the instrument it is played on,
and yours to choose. Everything is made here with the standard library, into a short mono WAV.
"""
import array
import hashlib
import io
import math
import sys
import wave

sys.dont_write_bytecode = True

RATE = 32000                  # samples a second: bells and plucks stay well under its 16 kHz
PEAK = 0.28                   # about -11 dBFS: a notification, not an alarm
LENGTH_MAX = 1.2              # seconds
FADE_OUT = 0.06               # seconds: every sound ends on a short fade, so nothing clicks
SCALE = (0, 2, 4, 7, 9)       # major pentatonic: any of its notes sound well together
STABLE = (0, 2, 3)            # its root, third and fifth: where a melody comes to rest
DEGREES = 8                   # the scale's notes over two octaves, less the top two
NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
STYLES = {"glass": "a soft bell", "wood": "a small marimba", "pluck": "a plucked string",
          "dot": "short digital dots", "air": "a breathy chime"}


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
    a Telegram id; `variant` gives them another sound when their first one is not liked."""
    dice = Dice(f"omagram-sound:{seed}:{variant}")
    root = 62 + dice.next() % 11                        # the key: D4 up to C5
    count = dice.pick((2, 3, 3, 3, 4, 4))
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


# ---------------------------------------------------------------- instruments

def _bell(out, start, freq, velocity, ring, _noise):
    """Glass: a sine bent by a quicker one (FM), bright as it is struck and pure as it fades."""
    w = 2 * math.pi * freq / RATE
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        env = min(1.0, t / 0.002) * math.exp(-t / 0.3)
        index = 1.1 * math.exp(-t / 0.05)
        overtone = 0.12 * math.exp(-t / 0.09) * math.sin(2 * w * n)
        out[start + n] += velocity * env * (math.sin(w * n + index * math.sin(3.5 * w * n)) + overtone)


def _mallet(out, start, freq, velocity, ring, _noise):
    """Wood: a marimba bar's first partials, the upper ones dying almost at once."""
    partials = [(2 * math.pi * freq * ratio / RATE, level, tau)
                for ratio, level, tau in ((1.0, 1.0, 0.16), (3.98, 0.3, 0.04), (9.2, 0.07, 0.015))
                if freq * ratio < RATE * 0.45]
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        attack = min(1.0, t / 0.001)
        out[start + n] += velocity * attack * sum(level * math.exp(-t / tau) * math.sin(w * n) for w, level, tau in partials)


def _string(out, start, freq, velocity, ring, noise):
    """Pluck: a string (Karplus-Strong), set going by a softened burst of noise."""
    period = RATE / freq - 0.5                            # the averaging below delays by half a sample
    burst = int(period) + 1
    raw = [noise.between(-1.0, 1.0) for _ in range(burst)]
    excite = [(raw[i - 1] + 2 * raw[i] + raw[(i + 1) % burst]) / 4 for i in range(burst)]
    size = min(len(out) - start, int(ring * RATE))
    line = [0.0] * size
    for n in range(size):
        x = excite[n] * velocity if n < burst else 0.0
        back = n - period
        if back >= 1:
            i = int(back)
            frac = back - i
            now = line[i] + (line[i + 1] - line[i]) * frac
            before = line[i - 1] + (line[i] - line[i - 1]) * frac
            x += 0.993 * 0.5 * (now + before)
        line[n] = x
        out[start + n] += 0.8 * x


def _dot(out, start, freq, velocity, ring, _noise):
    """Dot: a short pure tone with a tick at its start, settling a hair in pitch as it lands."""
    phase = 0.0
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        phase += 2 * math.pi * freq * (1 + 0.02 * math.exp(-t / 0.006)) / RATE
        env = min(1.0, t / 0.0015) * math.exp(-t / 0.03)
        tick = 0.35 * math.exp(-t / 0.0012) * math.sin(3 * phase)
        out[start + n] += velocity * (env * math.sin(phase) + tick)


def _air(out, start, freq, velocity, ring, _noise):
    """Air: a round tone that swells in and hangs, with a slow shimmer."""
    phase = 0.0
    for n in range(min(len(out) - start, int(ring * RATE))):
        t = n / RATE
        wobble = 1 + 0.0023 * math.sin(2 * math.pi * 5.2 * t) * min(1.0, t / 0.12)
        phase += 2 * math.pi * freq * wobble / RATE
        swell = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / 0.02))
        env = swell * math.exp(-t / 0.3)
        out[start + n] += velocity * env * (math.sin(phase) + 0.18 * math.sin(2 * phase) + 0.05 * math.sin(3 * phase))


SHAPES = {   # how long a note rings, how its notes are spaced, where the top is softened, and a repeat
    "glass": {"voice": _bell, "ring": 0.9, "spacing": 1.0, "cutoff": 7000, "echo": None},
    "wood": {"voice": _mallet, "ring": 0.5, "spacing": 0.9, "cutoff": 6500, "echo": None},
    "pluck": {"voice": _string, "ring": 0.7, "spacing": 1.0, "cutoff": 5500, "echo": None},
    "dot": {"voice": _dot, "ring": 0.16, "spacing": 0.85, "cutoff": 8000, "echo": (0.11, 0.35)},
    "air": {"voice": _air, "ring": 0.8, "spacing": 1.15, "cutoff": 4500, "echo": None},
}


# ---------------------------------------------------------------- the sound

def render(m, style):
    """A person's notes played in a style: 16-bit mono WAV bytes, ready to play."""
    if style not in SHAPES:
        raise ValueError(f"no such style: {style}")
    shape = SHAPES[style]
    notes = m["notes"]
    last = notes[-1]["at"] * shape["spacing"]
    tail = shape["ring"] + (shape["echo"][0] if shape["echo"] else 0.0)
    out = [0.0] * int(min(LENGTH_MAX, last + tail + FADE_OUT) * RATE)
    noise = Dice(f"omagram-noise:{m['seed']}:{m['variant']}")
    strikes = [(note["at"] * shape["spacing"], note["midi"], note["velocity"]) for note in notes]
    if shape["echo"]:
        delay, level = shape["echo"]
        strikes.append((last + delay, notes[-1]["midi"], notes[-1]["velocity"] * level))
    for at, midi, velocity in strikes:
        start = int(at * RATE)
        if start < len(out):
            shape["voice"](out, start, 440.0 * 2 ** ((midi - 69) / 12), velocity, shape["ring"], noise)
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
