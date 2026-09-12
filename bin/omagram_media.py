"""omagram_media -- recording and preparing voice and video messages, with ffmpeg.

Voice messages are recorded from the default PipeWire/PulseAudio source straight into Opus in
an Ogg container with one channel, as Telegram requires. Video messages are recorded by the
window's camera and cut here to a centred square, H.264 and AAC in MP4, at most a minute long.

Every program runs by absolute path as an argument list, under a deadline and with bounded
output. Recordings live in a 0700 directory in the runtime directory: the service only ever
reads a recording from there, and stale ones are deleted.
"""
import base64
import os
import pathlib
import secrets
import stat
import struct
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import plugin_safety as safe  # noqa: E402

REC = pathlib.Path(safe.runtime_dir()) / "omagram" / "rec"

VOICE_MAX_SECONDS = 600
NOTE_MAX_SECONDS = 60           # Telegram's limit for a video message
NOTE_SIZE = 480                 # square side in pixels; Telegram allows up to 640
RECORDING_MAX = 512 * 1024 * 1024
WAVEFORM_SAMPLES = 100
PCM_RATE = 4000                 # enough to see loudness; a 10-minute message is 4.8 MB of samples
PROBE_TIMEOUT = 20
DECODE_TIMEOUT = 60
TRANSCODE_TIMEOUT = 180
STALE_SECONDS = 3600


def rec_dir():
    safe.ensure_dir(REC, 0o700)
    return REC


def new_path(prefix, suffix):
    return rec_dir() / f"{prefix}-{secrets.token_hex(8)}{suffix}"


def remove(path):
    """Delete a file of ours in the recording directory; anything else is left alone."""
    path = pathlib.Path(path)
    if os.path.dirname(str(path)) != str(REC):
        return
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def clean_stale(max_age=STALE_SECONDS, now=None):
    now = time.time() if now is None else now
    try:
        with os.scandir(REC) as entries:
            old = [e.path for e in entries
                   if e.is_file(follow_symlinks=False) and now - e.stat(follow_symlinks=False).st_mtime > max_age]
    except FileNotFoundError:
        return
    for path in old:
        remove(path)


def recorded_file(path):
    """A recording the window made in Omagram's recording directory, and nothing else: no
    other directory, no symbolic link, a regular non-empty file of yours of bounded size."""
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path or len(path) > 4096:
        raise safe.UnsafeError("not a recording")
    if os.path.dirname(path) != os.path.realpath(rec_dir()):
        raise safe.UnsafeError("not a recording")
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or not 0 < st.st_size <= RECORDING_MAX:
        raise safe.UnsafeError("not a recording")
    return pathlib.Path(path)


# ---------------------------------------------------------------- voice

def voice_argv(path):
    """Record the default microphone into `path`; an interrupt (SIGINT) finishes the file."""
    ffmpeg = str(safe.tool("ffmpeg"))
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "pulse", "-i", "default", "-t", str(VOICE_MAX_SECONDS),
            "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k", "-application", "voip",
            "-f", "ogg", str(path)]


def levels_from_pcm(pcm, samples=WAVEFORM_SAMPLES):
    """Loudness over time as `samples` values 0-31, from signed 16-bit little-endian PCM."""
    count = len(pcm) // 2
    if count == 0:
        return []
    values = struct.unpack(f"<{count}h", pcm[:count * 2])
    buckets = min(samples, count)
    step = count / buckets
    peaks = []
    for i in range(buckets):
        chunk = values[int(i * step):max(int(i * step) + 1, int((i + 1) * step))]
        peaks.append(max(abs(v) for v in chunk))
    top = max(peaks) or 1
    return [round(31 * p / top) for p in peaks]


def waveform_bytes(levels):
    """Telegram's waveform format: 5 bits per value, least significant first."""
    packed = 0
    for i, value in enumerate(levels):
        packed |= (max(0, min(31, int(value))) & 31) << (i * 5)
    return packed.to_bytes((len(levels) * 5 + 7) // 8, "little")


def duration_of(path):
    ffprobe = str(safe.tool("ffprobe"))
    r = safe.run([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
                 timeout=PROBE_TIMEOUT, max_output=4096)
    if not r.ok:
        raise safe.UnsafeError("could not read the recording")
    try:
        return float(r.text().strip().splitlines()[0])
    except (ValueError, IndexError):
        raise safe.UnsafeError("could not read the recording")


def prepare_voice(path):
    """(duration in seconds, waveform as base64) for a finished voice recording."""
    duration = duration_of(path)
    ffmpeg = str(safe.tool("ffmpeg"))
    r = safe.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path),
                  "-ac", "1", "-ar", str(PCM_RATE), "-f", "s16le", "-"],
                 timeout=DECODE_TIMEOUT, max_output=(VOICE_MAX_SECONDS + 5) * PCM_RATE * 2)
    if not r.ok:
        raise safe.UnsafeError("could not read the recording")
    pcm = r.stdout if isinstance(r.stdout, bytes) else bytes(r.stdout)
    levels = levels_from_pcm(pcm)
    return max(0, round(duration)), base64.b64encode(waveform_bytes(levels)).decode("ascii")


# ---------------------------------------------------------------- video messages

def video_note_argv(source, target):
    ffmpeg = str(safe.tool("ffmpeg"))
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(source),
            "-t", str(NOTE_MAX_SECONDS),
            "-vf", f"crop='min(iw,ih)':'min(iw,ih)',scale={NOTE_SIZE}:{NOTE_SIZE},fps=30",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "64k", "-ac", "1", "-movflags", "+faststart", str(target)]


def prepare_video_note(source, target):
    """Convert the camera recording into a Telegram video message; returns its duration."""
    r = safe.run(video_note_argv(source, target), timeout=TRANSCODE_TIMEOUT, max_output=64 * 1024)
    if not r.ok:
        raise safe.UnsafeError("could not convert the recording")
    return duration_of(target)
