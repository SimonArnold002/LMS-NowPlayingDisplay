#!/usr/bin/env python3
"""
npd-vizfft: the all-in-one server-side visualiser data source.

Replaces both CAVA and the older npd-vizbridge.py helper. Reads SqueezeLite's
-v shared-memory PCM directly, runs an FFT on each frame, and serves dB-per-bin
values to browsers over WebSocket. The browser side then runs the SAME
band-binning / dB curve / tilt / ballistics code as the Web Audio path — so the
look matches the original Bars exactly.

Pipeline position:
    SqueezeLite -v  ->  /squeezelite-<MAC> shmem (16-bit PCM)
        -> [THIS]: mmap + FFT + downsample to ~512 dB bins
        -> WebSocket (ascii ';'-separated)  -> browser renders

Output frame format (one per WS message):
    "<sr>;<binhz>;<v0>;<v1>;...;<vN-1>\n"
    sr      = sample rate (int)
    binhz  = Hz per dB bin (float, downsampled)
    v0..   = dB values per downsampled bin (float, typically -100..0)

The browser parses the first two as metadata and uses the rest as the analyser
bin array, then runs vizComputeBands exactly as before.

Requirements: python3, numpy. On DietPi:
    sudo apt install python3-numpy
"""

import argparse
import base64
import ctypes
import hashlib
import math
import mmap
import os
import socket
import struct
import sys
import threading
import time

try:
    import numpy as np
except ImportError:
    print("FATAL: numpy is required. Install with: sudo apt install -y python3-numpy")
    sys.exit(1)

# ---------------------------------------------------------------------------
# SqueezeLite vis_t shared-memory layout
# ---------------------------------------------------------------------------
# From squeezelite/output_vis.c. We don't need the full struct, just the
# header fields and the ring buffer of int16 samples. The struct is:
#
#   struct vis_t {
#       pthread_rwlock_t rwlock;     // sizeof depends on platform
#       u32 buf_size;                 // ring buffer size in SAMPLES (interleaved)
#       u32 buf_index;                // next write index in samples
#       bool running;                  // 1 if audio is flowing
#       u32 rate;                      // sample rate (Hz)
#       time_t updated;                // when last written
#       s16 buffer[VIS_BUF_SIZE];      // VIS_BUF_SIZE = 16384 stereo samples
#   };
#
# The total observed size is 32848 bytes, which matches a vis_t layout that
# uses a 56-byte pthread_rwlock_t (x86_64 glibc) + 4 u32s + a bool + time_t +
# 16384 * 2 bytes of int16 buffer.
#
# Rather than parse the rwlock (platform-specific), we locate fields by reading
# from the END of the segment: buffer occupies the last 16384*2 = 32768 bytes,
# and the integer header fields live just before it. This works as long as
# the buffer size is the standard 16384 samples.

VIS_BUF_SAMPLES = 16384  # SqueezeLite's VIS_BUF_SIZE constant
VIS_BUF_BYTES   = VIS_BUF_SAMPLES * 2  # int16 = 2 bytes per sample

# Sample rates we accept as a valid reading of the vis_t `rate` field. Used to
# sanity-check the deterministic read (and reject the transient 0 / garbage that
# can appear for a frame or two while squeezelite reconfigures the device at a
# track boundary or rate change). Covers the full range LMS can stream,
# including DSD-as-PCM (88.2/176.4) and very-hi-res content.
PLAUSIBLE_RATES = (
    8000, 11025, 16000, 22050, 32000, 44100, 48000,
    88200, 96000, 176400, 192000, 352800, 384000,
)


class ShmemReader:
    """Memory-maps the SqueezeLite shmem segment and reads recent PCM samples,
    tracking SqueezeLite's write position so we always read freshly-written
    audio (not stale/zero regions of the ring buffer)."""
    def __init__(self, shm_name):
        path = "/dev/shm/" + shm_name.lstrip("/")
        self.fd = os.open(path, os.O_RDONLY)
        st = os.fstat(self.fd)
        self.size = st.st_size
        if self.size < VIS_BUF_BYTES + 16:
            raise RuntimeError(f"shmem too small ({self.size} bytes)")
        self.mm = mmap.mmap(self.fd, self.size, prot=mmap.PROT_READ)
        # Buffer occupies the last VIS_BUF_BYTES of the segment.
        self.buf_offset = self.size - VIS_BUF_BYTES
        self._cached_rate = 44100
        # The header sits before the buffer. The vis_t fields just before the
        # sample buffer are (in declaration order): buf_size, buf_index,
        # running, rate, updated. We scan the header region to locate buf_size
        # (which equals VIS_BUF_SAMPLES = 16384) and read buf_index right after
        # it — robust to the platform-specific rwlock prefix size.
        self._idx_field_off = self._locate_index_field()
        # `rate` (u32) sits two fields past buf_index in vis_t:
        #   buf_index(u32) | running(bool, padded to 4) | rate(u32)
        # i.e. buf_index_off + 8. Reading it directly is immune to the old loose
        # scan's failure mode (latching onto a stray plausible-looking u32
        # elsewhere in the header / rwlock bytes and getting stuck at a wrong
        # rate). Falls back to the scan only if the buf_size anchor wasn't found.
        self._rate_field_off = (self._idx_field_off + 8) if self._idx_field_off is not None else None

    def _locate_index_field(self):
        """Find the offset of buf_index by locating buf_size (==VIS_BUF_SAMPLES)
        in the header region just before the buffer."""
        scan_from = max(0, self.buf_offset - 64)
        header = bytes(self.mm[scan_from:self.buf_offset])
        # buf_size is a u32 equal to VIS_BUF_SAMPLES. Find it; buf_index is the
        # next u32 right after it.
        for off in range(0, len(header) - 8, 4):
            val = int.from_bytes(header[off:off+4], "little")
            if val == VIS_BUF_SAMPLES:
                return scan_from + off + 4   # buf_index is the next u32
        return None   # fall back to physical-end reads if not found

    def _read_buf_index(self):
        if self._idx_field_off is None:
            return None
        raw = bytes(self.mm[self._idx_field_off:self._idx_field_off + 4])
        return int.from_bytes(raw, "little")

    def latest_samples(self, n):
        """Return the most recent `n` mono samples as float32 in [-1,1], read
        ending at SqueezeLite's current write index so we never read stale or
        unwritten (zero) regions."""
        raw = bytes(self.mm[self.buf_offset:self.buf_offset + VIS_BUF_BYTES])
        all_samples = np.frombuffer(raw, dtype=np.int16)   # interleaved stereo
        total = all_samples.size                            # = VIS_BUF_SAMPLES*?
        idx = self._read_buf_index()
        need = n * 2                                        # stereo
        if idx is not None and 0 <= idx <= total:
            # buf_index is in interleaved-sample units; read the `need` samples
            # ending at idx, wrapping the ring buffer if necessary.
            start = idx - need
            if start >= 0:
                tail = all_samples[start:idx]
            else:
                tail = np.concatenate((all_samples[start:], all_samples[:idx]))
        else:
            # Fallback: physical end of buffer.
            tail = all_samples[-need:] if total >= need else all_samples
        if tail.size % 2 == 1:
            tail = tail[:-1]
        if tail.size == 0:
            return np.zeros(n, dtype=np.float32)
        stereo = tail.reshape(-1, 2)
        mono = stereo.mean(axis=1).astype(np.float32) / 32768.0
        return mono

    def read_new_samples(self, last_idx):
        """Read all samples newly written since `last_idx` (interleaved-sample
        units). Returns (mono_float32_array, current_idx, lost_count).

        `lost_count > 0` means we fell behind the ring's capacity since the
        last call — the writer wrote more than (VIS_BUF_SAMPLES/2) samples
        before we polled. In that case the returned mono array is empty and
        the caller should clear any accumulated history (it's stale).

        Returns (None, None, 0) if buf_index is unavailable (header parse
        failure); caller should fall back to latest_samples() or skip the
        frame.
        """
        cur_idx = self._read_buf_index()
        if cur_idx is None or not (0 <= cur_idx <= VIS_BUF_SAMPLES):
            return None, None, 0

        if last_idx is None:
            # First call — establish the baseline; no samples returned.
            return np.zeros(0, dtype=np.float32), cur_idx, 0

        # Distance from last_idx to cur_idx around the ring, in interleaved
        # samples. We assume the writer only moves FORWARD (squeezelite never
        # rewinds buf_index).
        if cur_idx >= last_idx:
            new_count = cur_idx - last_idx
        else:
            new_count = VIS_BUF_SAMPLES - last_idx + cur_idx

        # Overrun detection. The ring is VIS_BUF_SAMPLES interleaved samples
        # (~186ms at 44.1kHz stereo). At 60 Hz polling we expect ~1470 per
        # poll. If we see more than half the ring's worth, the writer either
        # lapped us (we missed data) or buf_index reset (track boundary).
        # Either way, history is broken: tell caller to flush.
        if new_count > VIS_BUF_SAMPLES // 2:
            return np.zeros(0, dtype=np.float32), cur_idx, new_count

        if new_count == 0:
            return np.zeros(0, dtype=np.float32), cur_idx, 0

        # Pull just the new range from the ring, handling wrap.
        raw = bytes(self.mm[self.buf_offset:self.buf_offset + VIS_BUF_BYTES])
        all_samples = np.frombuffer(raw, dtype=np.int16)
        if last_idx + new_count <= VIS_BUF_SAMPLES:
            seg = all_samples[last_idx:last_idx + new_count]
        else:
            first = all_samples[last_idx:]
            second = all_samples[:new_count - first.size]
            seg = np.concatenate([first, second])

        # Drop a stray odd sample if any so the stereo reshape is valid.
        if seg.size % 2:
            seg = seg[:-1]
        if seg.size == 0:
            return np.zeros(0, dtype=np.float32), cur_idx, 0
        stereo = seg.reshape(-1, 2)
        mono = stereo.mean(axis=1).astype(np.float32) / 32768.0
        return mono, cur_idx, 0

    def sample_rate(self):
        return self._cached_rate

    def try_update_rate(self):
        # Preferred path: read the rate field at its known offset. Validate it's
        # a real rate; if it's transiently 0/garbage (device reconfiguring at a
        # boundary), keep the last-known-good cached rate rather than corrupting
        # the offset math or snapping back to the 44.1k default.
        if self._rate_field_off is not None and self._rate_field_off + 4 <= self.size:
            val = int.from_bytes(
                bytes(self.mm[self._rate_field_off:self._rate_field_off + 4]), "little")
            if val in PLAUSIBLE_RATES:
                self._cached_rate = val
                return val
            return None
        # Fallback (anchor not found): the old loose scan. Returns the first
        # plausible-looking u32 in the pre-buffer header window.
        header = bytes(self.mm[max(0, self.buf_offset - 64):self.buf_offset])
        for off in range(0, len(header) - 4, 4):
            val = int.from_bytes(header[off:off+4], "little")
            if val in PLAUSIBLE_RATES:
                self._cached_rate = val
                return val
        return None

    def close(self):
        try: self.mm.close()
        except Exception: pass
        try: os.close(self.fd)
        except Exception: pass


# ---------------------------------------------------------------------------
# FFT pipeline — matches the Web Audio AnalyserNode spec EXACTLY so the data
# is byte-for-byte equivalent to what the browser's getFloatFrequencyData()
# would deliver. The browser's existing log-bin/tilt/dB/ballistics code then
# produces an identical visualization to the browser-audio mode.
#
# AnalyserNode (per W3C Web Audio spec):
#   - fftSize: 8192 (we set this in the page)
#   - window: Blackman
#   - smoothing on MAGNITUDE: Y_smooth[k] = 0.8 * Y_smooth[k] + 0.2 * |X[k]|
#   - output:  20 * log10(Y_smooth[k]),  fftSize/2 bins
# ---------------------------------------------------------------------------

FFT_SIZE  = 8192        # matches vizAnalyser.fftSize in the browser mode path
OUT_BINS  = FFT_SIZE // 2   # 4096 — same number of bins getFloatFrequencyData returns
DB_FLOOR  = -120.0
SMOOTH    = 0.0         # CRITICAL: the web app sets analyser.smoothingTimeConstant
                        # = 0.0 and gets ALL its smoothness from the per-bar
                        # ballistics (attack/decay) in vizComputeBands. So the
                        # helper must feed RAW per-frame FFT — any pre-smoothing
                        # here double-smooths vs web mode and feels sluggish.

# Time-domain output: send a downsampled copy of the FFT window alongside the
# spectrum so the page can drive the Scope and Waveform Ring visualizers in
# server mode (they need raw samples, not bins). The full 8192-sample window
# would be ~50 KB/frame as text at 60 fps (3 MB/s) — overkill since the visuals
# cap themselves at ~1440 points. Decimating 4× to 2048 samples preserves the
# same time span (~186 ms @ 44.1 kHz) at perfectly adequate resolution for line
# rendering. ~12 KB/frame, ~720 KB/s — comfortable for LAN.
WAVE_OUT_SAMPLES = 2048
WAVE_DECIMATE    = FFT_SIZE // WAVE_OUT_SAMPLES   # 4

# Pre-compute the Blackman window once (it's deterministic).
_blackman = None
def _get_window():
    global _blackman
    if _blackman is None:
        _blackman = np.blackman(FFT_SIZE).astype(np.float32)
    return _blackman


def compute_magnitude_bins(samples_mono):
    """Run FFT on a window of mono samples, return OUT_BINS linear magnitude
    values — exactly what the browser's AnalyserNode would compute BEFORE the
    smoothing/dB step."""
    n = samples_mono.size
    if n < FFT_SIZE:
        padded = np.zeros(FFT_SIZE, dtype=np.float32)
        padded[-n:] = samples_mono
        samples_mono = padded
    elif n > FFT_SIZE:
        samples_mono = samples_mono[-FFT_SIZE:]
    windowed = samples_mono * _get_window()
    spectrum = np.fft.rfft(windowed)              # rfft -> FFT_SIZE/2 + 1 bins
    # AnalyserNode normalises by fftSize (not fftSize/2). This matches the
    # browser's reference level so dB values land in the same range.
    mag = np.abs(spectrum) / FFT_SIZE
    # rfft returns one extra bin (Nyquist). Drop it so we have exactly OUT_BINS,
    # matching getFloatFrequencyData()'s output length.
    return mag[:OUT_BINS]


# ---------------------------------------------------------------------------
# Shared latest-frame state
# ---------------------------------------------------------------------------

_latest = {"frame": "", "rate": 44100}
_lock = threading.Lock()


def producer_loop(shm_name, fps, offset_file=None, max_offset_ms=4500, baseline_ms=2000):
    """Read shmem -> accumulate into Python ring -> offset-aware FFT -> serialise.

    The Python ring buffer gives us a much deeper history than squeezelite's
    shmem ring (which is fixed at ~186ms). This lets the FFT window be read
    from up to `max_offset_ms` of audio history back, so the visualizer can
    be time-shifted to align with rooms whose playback latency is much
    larger than the shmem ring (WISA systems, bridges with deep buffering).

    The current offset (in ms) is read from `offset_file` periodically. The
    plugin writes that file on user nudge / save / room change.

    Matches AnalyserNode.getFloatFrequencyData() byte-for-byte conceptually:
    Blackman window -> rfft -> magnitude -> smoothing 0.8 -> 20*log10.
    """
    reader = ShmemReader(shm_name)
    print(f"[vizfft] reading shmem: /dev/shm/{shm_name.lstrip('/')}")
    if offset_file:
        print(f"[vizfft] polling offset file: {offset_file}")
    sr_initial = reader.try_update_rate() or reader.sample_rate()
    print(f"[vizfft] initial sample rate: {sr_initial} Hz")
    # Baseline lead: the visualizer renders audio `baseline_ms` back from the
    # live capture edge by default, so the per-player offset is a BIDIRECTIONAL
    # trim around it. Effective read-back from the live edge = baseline + offset:
    #   offset 0      -> read `baseline_ms` back (neutral)
    #   offset -N     -> read (baseline-N) back  -> visuals EARLIER (toward live)
    #   offset +N     -> read (baseline+N) back  -> visuals LATER
    # Forward limit is the baseline (offset -baseline = live edge). Clamp baseline
    # into the ring so total read-back never exceeds what we buffer.
    if baseline_ms < 0:
        baseline_ms = 0
    if baseline_ms > max_offset_ms:
        baseline_ms = max_offset_ms
    print(f"[vizfft] baseline lead: {baseline_ms} ms "
          f"(offset range {-baseline_ms}..{max_offset_ms - baseline_ms} ms; "
          f"negative = visuals earlier, positive = later)")
    interval = 1.0 / fps
    silent_db = None
    smooth_mag = None

    # Python-side ring buffer for deep audio history. Sized for max_offset_ms
    # of audio at the HIGHEST supported rate, NOT the current one — otherwise a
    # ring sized at 44.1kHz would hold far less wall-clock history once playback
    # switches to hi-res (e.g. only ~1s at 192kHz), silently clamping large
    # offsets. Sizing for 192kHz guarantees the full max_offset_ms window holds
    # at any rate we'll see. 4.5s @ 192kHz float32 = ~3.4MB — trivial.
    RING_SIZE_RATE = 192000
    ring_size_samples = int((max_offset_ms / 1000.0) * RING_SIZE_RATE) + FFT_SIZE * 2
    ring = np.zeros(ring_size_samples, dtype=np.float32)
    ring_write = 0          # next write index in `ring`
    ring_filled = 0         # total samples ever written; min(this, ring_size_samples) is valid

    # Track buf_index across polls so we know which shmem samples are NEW
    # (haven't been appended to our ring yet).
    last_shmem_idx = None

    # Pause tracking — moved to use the SAME buf_index reads we're already
    # doing for read_new_samples, no extra header reads needed.
    last_pause_idx = None
    paused_count = 0

    # Offset state. current_offset_ms is what we use for FFT-read positioning.
    # We re-read offset_file every offset_poll_secs in case the plugin updated
    # it (user nudge, room change, etc.).
    current_offset_ms = 0
    offset_file_mtime = 0
    last_offset_check = 0.0
    offset_poll_secs = 0.1

    def _refresh_offset(now_t):
        nonlocal current_offset_ms, offset_file_mtime, last_offset_check
        if not offset_file:
            return
        if now_t - last_offset_check < offset_poll_secs:
            return
        last_offset_check = now_t
        try:
            m = os.path.getmtime(offset_file)
        except OSError:
            if current_offset_ms != 0:
                print("[vizfft] offset file missing; resetting offset to 0")
                current_offset_ms = 0
                offset_file_mtime = 0
            return
        if m == offset_file_mtime:
            return
        try:
            with open(offset_file, "r") as f:
                txt = f.read().strip()
            new_off = int(txt)
        except (OSError, ValueError):
            return
        # Offset is now bidirectional. Forward (negative) is limited by the
        # baseline lead (can't read past the live edge); backward (positive) by
        # the ring depth beyond the baseline.
        new_off = max(-baseline_ms, min(max_offset_ms - baseline_ms, new_off))
        if new_off != current_offset_ms:
            rb = baseline_ms + new_off
            if rb < 0:
                rb = 0
            # rb = how far behind the live capture edge the visuals are read,
            # i.e. the visual latency this offset produces. 0 = live edge.
            # This makes the sign explicit: negative offset -> smaller rb
            # (visuals earlier/nearer live), positive -> larger rb (later).
            print(f"[vizfft] offset updated: {current_offset_ms}ms -> {new_off}ms "
                  f"(reading {rb}ms behind live edge; baseline={baseline_ms}ms)")
            current_offset_ms = new_off
        offset_file_mtime = m

    last_logged_sr = sr_initial
    overrun_total = 0
    last_overrun_log_t = 0.0
    while True:
        try:
            now = time.time()
            sr = reader.try_update_rate() or reader.sample_rate()
            if sr != last_logged_sr:
                print(f"[vizfft] sample rate change: {last_logged_sr} -> {sr} Hz", flush=True)
                last_logged_sr = sr
            _refresh_offset(time.time())

            # Pull all newly-written samples since last poll and append to ring.
            new_mono, cur_idx, lost = reader.read_new_samples(last_shmem_idx)

            if cur_idx is None:
                # buf_index unavailable — couldn't parse header. Skip this poll.
                time.sleep(interval)
                continue

            if lost > 0:
                # We fell behind the tiny (~186ms) shmem ring by >half, or
                # buf_index jumped at a track boundary. We deliberately DO NOT
                # wipe the 4.5s history here any more: wiping forced the offset
                # to ramp back in from zero on every hiccup, which read as a
                # multi-second glitch/drift and meant the same offset value
                # didn't reproduce the same sync after a reset. Instead we keep
                # the ring (so the read position and offset stay rock-stable)
                # and simply resync to the current write index. The cost is a
                # single small discontinuity in the buffered waveform at the
                # splice, which is invisible for a few seconds (we read well
                # behind the write head) and never a full reset.
                overrun_total += 1
                if (now - last_overrun_log_t) > 5.0:
                    print(f"[vizfft] resynced after falling behind shmem "
                          f"({overrun_total} total; history kept, offset stable)")
                    last_overrun_log_t = now
                # ring / ring_write / ring_filled left intact on purpose.
            elif new_mono is not None and new_mono.size > 0:
                n = new_mono.size
                end = ring_write + n
                if end <= ring_size_samples:
                    ring[ring_write:end] = new_mono
                else:
                    first_part = ring_size_samples - ring_write
                    ring[ring_write:] = new_mono[:first_part]
                    ring[:end - ring_size_samples] = new_mono[first_part:]
                ring_write = end % ring_size_samples
                ring_filled = min(ring_filled + n, ring_size_samples)

            last_shmem_idx = cur_idx

            # Pause detection (same idea as before — buf_index advances when
            # squeezelite is decoding audio; if it stops moving for several
            # polls in a row, playback is paused or stopped).
            if last_pause_idx is not None and cur_idx == last_pause_idx:
                paused_count += 1
            else:
                paused_count = 0
            last_pause_idx = cur_idx

            # Compute the FFT-read window. Read-back from the live edge is the
            # baseline lead plus the (signed) offset, so 0 offset sits at the
            # baseline, negative reads nearer the edge (visuals earlier), positive
            # reads further back (visuals later). Clamp into [0, what we have].
            read_back_ms = baseline_ms + current_offset_ms
            if read_back_ms < 0:
                read_back_ms = 0
            read_back_samples = int(read_back_ms * sr / 1000)
            max_available = max(0, ring_filled - FFT_SIZE)
            if read_back_samples > max_available:
                read_back_samples = max_available
            offset_samples = read_back_samples

            if ring_filled < FFT_SIZE:
                # Ring hasn't accumulated enough history yet (just started).
                # Emit silent frame so the visualizer doesn't show garbage.
                samples = np.zeros(FFT_SIZE, dtype=np.float32)
            else:
                end_pos = (ring_write - offset_samples) % ring_size_samples
                start_pos = (end_pos - FFT_SIZE) % ring_size_samples
                if start_pos < end_pos:
                    samples = ring[start_pos:end_pos].copy()
                else:
                    samples = np.concatenate(
                        [ring[start_pos:], ring[:end_pos]]
                    )

            rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
            # Treat as silent if EITHER:
            #  - the writer has clearly stopped (paused), OR
            #  - the buffer is genuinely near-zero (stopped, or true silence)
            is_silent = (paused_count >= 5) or (rms < 3e-3)

            if is_silent:
                nyq = sr / 2.0
                binhz = nyq / OUT_BINS
                if silent_db is None or not silent_db.startswith(f"{sr};"):
                    parts = [f"{sr}", f"{binhz:.3f}"]
                    parts.extend([f"{DB_FLOOR:.1f}"] * OUT_BINS)
                    wave_part = ";".join(["0.000"] * WAVE_OUT_SAMPLES)
                    silent_db = ";".join(parts) + "|" + wave_part
                with _lock:
                    _latest["frame"] = silent_db
                    _latest["rate"]  = sr
                smooth_mag = None
                time.sleep(interval)
                continue

            mag = compute_magnitude_bins(samples)
            if smooth_mag is None or smooth_mag.shape != mag.shape:
                smooth_mag = mag.copy()
            else:
                smooth_mag = SMOOTH * smooth_mag + (1.0 - SMOOTH) * mag

            db = 20.0 * np.log10(np.maximum(smooth_mag, 1e-12))
            db = np.maximum(db, DB_FLOOR)

            # Time-domain wave block: the FFT-input samples, decimated.
            wave_src = samples
            if wave_src.size < FFT_SIZE:
                padded = np.zeros(FFT_SIZE, dtype=np.float32)
                padded[-wave_src.size:] = wave_src
                wave_src = padded
            elif wave_src.size > FFT_SIZE:
                wave_src = wave_src[-FFT_SIZE:]
            wave_out = wave_src[::WAVE_DECIMATE]

            nyq = sr / 2.0
            binhz = nyq / OUT_BINS
            parts = [f"{sr}", f"{binhz:.3f}"]
            parts.extend(f"{v:.1f}" for v in db)
            wave_parts = [f"{v:.3f}" for v in wave_out]
            line = ";".join(parts) + "|" + ";".join(wave_parts)
            with _lock:
                _latest["frame"] = line
                _latest["rate"]  = sr
        except Exception as e:
            print(f"[vizfft] read/FFT error: {e}")
            time.sleep(0.5)
        time.sleep(interval)


# ---------------------------------------------------------------------------
# WebSocket server (same minimal stdlib implementation as before)
# ---------------------------------------------------------------------------

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_handshake(conn):
    data = conn.recv(4096).decode("utf-8", "ignore")
    if "upgrade: websocket" not in data.lower():
        return False
    key = ""
    for line in data.split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
            break
    if not key:
        return False
    accept = base64.b64encode(
        hashlib.sha1((key + WS_MAGIC).encode()).digest()
    ).decode()
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    conn.send(resp.encode())
    return True


def ws_encode_text(message):
    payload = message.encode("utf-8")
    header = bytearray()
    header.append(0x81)
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header.extend(struct.pack(">H", n))
    else:
        header.append(127)
        header.extend(struct.pack(">Q", n))
    return bytes(header) + payload


def client_thread(conn, addr, fps):
    try:
        if not ws_handshake(conn):
            conn.close()
            return
        print(f"[vizfft] client connected: {addr}")
        interval = 1.0 / fps
        while True:
            with _lock:
                frame = _latest["frame"]
            if frame:
                conn.send(ws_encode_text(frame))
            time.sleep(interval)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        print(f"[vizfft] client disconnected: {addr}")
        try: conn.close()
        except Exception: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shmem", default="/squeezelite-38:f7:cd:c5:1a:2c",
                    help="POSIX shmem name (with leading /), e.g. /squeezelite-AA:BB:...")
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--fps", type=float, default=60.0,
                    help="Frames per second for both FFT and WS push")
    ap.add_argument("--offset-file", default=None,
                    help="Path to a file holding the current FFT-read offset in "
                         "milliseconds. The plugin writes this on user nudge / "
                         "save / room change. We poll it every 100ms. Missing or "
                         "unparseable file = 0 ms offset.")
    ap.add_argument("--max-offset-ms", type=int, default=4500,
                    help="Cap on offset honoured (and thus on the Python ring "
                         "buffer size). Defaults to 4500ms — enough for WISA "
                         "systems and deep-buffered bridges.")
    ap.add_argument("--baseline-ms", type=int, default=2000,
                    help="Built-in delay lead (ms). The visualizer renders audio "
                         "this far back from the live capture edge by default, "
                         "giving the per-player offset room to move BOTH ways: "
                         "negative offset pulls visuals earlier (toward the live "
                         "edge), positive pushes them later. 0 offset = exactly "
                         "this lead. Costs a one-time fill of this many ms at "
                         "playback start. Set smaller once real offsets are known.")
    ap.add_argument("--selftest", action="store_true",
                    help="Print buffer-index detection + live RMS for 5s and exit")
    args = ap.parse_args()

    if args.selftest:
        reader = ShmemReader(args.shmem)
        print(f"[selftest] shmem size: {reader.size} bytes")
        print(f"[selftest] buf_offset: {reader.buf_offset}")
        print(f"[selftest] buf_index field located at: {reader._idx_field_off} "
              f"({'OK' if reader._idx_field_off else 'NOT FOUND - will use fallback'})")
        print(f"[selftest] sample rate: {reader.try_update_rate() or reader.sample_rate()}")
        print("[selftest] live RMS (should be steady, NOT alternating with 0 while playing):")
        for i in range(25):
            s = reader.latest_samples(FFT_SIZE)
            rms = float(np.sqrt(np.mean(s * s))) if s.size else 0.0
            idx = reader._read_buf_index()
            print(f"  t={i:2d}  buf_index={idx}  rms={rms:.5f}")
            time.sleep(0.2)
        reader.close()
        return

    print(f"[vizfft] starting: shmem={args.shmem} port={args.port} fps={args.fps} "
          f"offset_file={args.offset_file} max_offset_ms={args.max_offset_ms} "
          f"baseline_ms={args.baseline_ms}")
    threading.Thread(target=producer_loop,
                     args=(args.shmem, args.fps, args.offset_file, args.max_offset_ms,
                           args.baseline_ms),
                     daemon=True).start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(8)
    print(f"[vizfft] listening on ws://0.0.0.0:{args.port}/")

    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=client_thread, args=(conn, addr, args.fps),
                             daemon=True).start()
    except KeyboardInterrupt:
        print("\n[vizfft] shutting down")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
