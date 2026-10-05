#!/usr/bin/env python3
"""Warm whisper daemon for yap dictation (v5: GPU when available, CPU fallback, live progress,
no-speech verdict).

Measured on an 8-core Ryzen 7 5800X3D + RTX 5070 with a 157s fixture (small.en):
    cpu/int8,  8 threads, serial   7.7 s   (20x realtime)
    cpu/int8, 16 threads, serial  10.0 s   (16x)  <- SMT hurts ctranslate2
    cuda/float16                   8.9 s   (18x)  <- slow path on this GPU
    cuda/int8_float16              1.8 s   (89x)
    cuda/float32                   1.5 s  (103x)  <- best
So: prefer CUDA float32, fall back to CUDA int8_float16, then CPU int8 with 8 threads.
CUDA needs the pip nvidia-* lib dirs on LD_LIBRARY_PATH **at process start** — setting
os.environ inside Python is too late for the dynamic loader; the unit file does it.

Protocol on ~/.cache/yap/stt.sock
    client -> daemon: 8 ASCII digits (byte length) then the raw audio bytes
    daemon -> client: framed replies, each FRAME = type byte + 8 ASCII digits (payload
        length) + payload
            b"\\x01" + len + b"<percent>"      progress, sent as the decoder advances
            b"\\x02" + len + <utf-8 transcript>  the final text, then the daemon closes
            b"\\x03" + len 0                    no speech: the VAD kept no audio at all, so this
                                              is sent instead of an empty transcript. A client
                                              can stop here instead of asking a fallback
                                              service -- the clip has nothing to say.
    The frame types are control bytes that never occur in a transcript, so a client can
    tell a framed daemon from an older one that replies with raw text: if the first byte
    is not 1, 2 or 3, treat the whole stream as the transcript.

Progress comes free: `transcribe()` returns a *generator* of segments, so each iteration
is one more decoded step and `segment.end / info.duration` is real completion. Frames are
throttled to one per 100 ms and only when the integer percent changes.

Config: YAP_MODEL (default small.en — use `small` or `large-v3` for non-English audio),
YAP_LANGUAGE (default en; empty = auto-detect), YAP_DEVICE (auto|cuda|cpu), YAP_THREADS,
YAP_BATCH, YAP_BEAM (default 5), YAP_PROMPT / YAP_PROMPT_FILE (default: no biasing), YAP_SOCK.
"""
from __future__ import annotations

import inspect
import logging
import os
import socket
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
SOCK = Path(os.environ.get("YAP_SOCK", HOME / ".cache" / "yap" / "stt.sock"))
MODEL_NAME = os.environ.get("YAP_MODEL", "small.en")
DEVICE = os.environ.get("YAP_DEVICE", "auto")
THREADS = int(os.environ.get("YAP_THREADS", 8))
BATCH = int(os.environ.get("YAP_BATCH", 1))
LANGUAGE = os.environ.get("YAP_LANGUAGE", "en")
BEAM = int(os.environ.get("YAP_BEAM", 5))

# Decoding context. Plain greedy decode mangles exactly the words that matter — names, jargon,
# acronyms — and beam search plus a vocabulary hint fixes them for a fraction of a second of
# extra decode (measured: 155s clip, +0.7s). Bias with `hotwords` (purpose-built for this) and
# fall back to `initial_prompt` on faster-whisper builds that don't have it.
#
# Nothing is biased by default: ship the tool, not somebody else's word list. To bias, either
# set YAP_PROMPT, or write the text to YAP_PROMPT_FILE (default ~/.config/yap/prompt.txt) —
# the file route exists because a systemd unit cannot carry an Environment value with spaces
# without quoting, and quoting brings its own escape rules. The env wins when it is set at all,
# including when it is set to the empty string to mean "explicitly no biasing".


def _read_prompt() -> str:
    if "YAP_PROMPT" in os.environ:
        return os.environ["YAP_PROMPT"]
    path = os.environ.get("YAP_PROMPT_FILE", str(HOME / ".config" / "yap" / "prompt.txt"))
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


DEFAULT_PROMPT = _read_prompt()
LOG = HOME / ".cache" / "yap" / "sttd.log"

FRAME_PROGRESS = b"\x01"
FRAME_TEXT = b"\x02"
FRAME_NO_SPEECH = b"\x03"
PROGRESS_MIN_INTERVAL = 0.1

LOG.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    filename=LOG, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("yap-sttd")

from faster_whisper import WhisperModel  # noqa: E402

try:
    from faster_whisper import BatchedInferencePipeline  # type: ignore
except Exception:
    BatchedInferencePipeline = None  # type: ignore


def candidates() -> list[tuple[str, str]]:
    order: list[tuple[str, str]] = []
    if DEVICE in ("auto", "cuda"):
        order += [("cuda", "float32"), ("cuda", "int8_float16")]
    if DEVICE in ("auto", "cpu"):
        order += [("cpu", "int8")]
    return order


def load() -> tuple[object, str, str]:
    """Return (pipeline, pipeline_kind, device_label)."""
    for device, compute in candidates():
        started = time.time()
        try:
            model = WhisperModel(
                MODEL_NAME,
                device=device,
                compute_type=compute,
                cpu_threads=THREADS if device == "cpu" else 0,
            )
        except Exception as exc:
            log.warning("%s/%s unavailable: %s: %s", device, compute, type(exc).__name__, str(exc)[:160])
            continue
        kind = "serial"
        pipe: object = model
        if BATCH > 1 and BatchedInferencePipeline is not None:
            try:
                pipe = BatchedInferencePipeline(model=model)
                kind = f"batched(batch={BATCH})"
            except Exception:
                log.exception("batched pipeline unavailable on %s — using serial", device)
        label = f"{device}/{compute}"
        log.info(
            "model %s ready in %.1fs (%s, %s, threads=%s)",
            MODEL_NAME, time.time() - started, label, kind, THREADS,
        )
        return pipe, kind, label
    raise SystemExit("no usable device for whisper")


def send_frame(conn: socket.socket, kind: bytes, payload: bytes) -> None:
    conn.sendall(kind + b"%08d" % len(payload) + payload)


_SUPPORTS_HOTWORDS = None       # resolved on first use against the installed faster-whisper


def supports_hotwords(pipe: object) -> bool:
    global _SUPPORTS_HOTWORDS
    if _SUPPORTS_HOTWORDS is None:
        try:
            _SUPPORTS_HOTWORDS = "hotwords" in inspect.signature(pipe.transcribe).parameters
        except (TypeError, ValueError):
            _SUPPORTS_HOTWORDS = False
    return bool(_SUPPORTS_HOTWORDS)


def transcribe(pipe: object, kind: str, path: str, on_progress=None) -> tuple[str, float, float | None]:
    # language=None lets whisper auto-detect; YAP_LANGUAGE decides.
    kwargs: dict[str, object] = {"language": LANGUAGE or None, "vad_filter": True}
    if kind.startswith("batched"):
        kwargs["batch_size"] = BATCH
    else:
        kwargs["beam_size"] = BEAM          # greedy decode was the accuracy problem
    if DEFAULT_PROMPT:
        kwargs["hotwords" if supports_hotwords(pipe) else "initial_prompt"] = DEFAULT_PROMPT
    segments, info = pipe.transcribe(path, **kwargs)  # type: ignore[attr-defined]
    total = float(getattr(info, "duration", 0.0) or 0.0)
    # Audio that survived the VAD. 0.0 alongside empty text means nobody spoke, which the
    # caller reports as its own verdict instead of as an empty transcript. None = older lib.
    kept_raw = getattr(info, "duration_after_vad", None)
    kept = float(kept_raw) if kept_raw is not None else None
    parts: list[str] = []
    last_pct = -1
    last_sent = 0.0
    for segment in segments:                      # generator: one step per decoded segment
        parts.append(segment.text)
        if on_progress and total > 0:
            pct = int(min(99, max(0, (float(getattr(segment, "end", 0.0)) / total) * 100)))
            now = time.time()
            if pct != last_pct and (now - last_sent) >= PROGRESS_MIN_INTERVAL:
                last_pct, last_sent = pct, now
                try:
                    on_progress(pct)
                except OSError:
                    return "".join(parts).strip(), total, kept
    return "".join(parts).strip(), total, kept


def read_exactly(conn: socket.socket, count: int) -> bytes:
    buf = b""
    while len(buf) < count:
        chunk = conn.recv(min(65536, count - len(buf)))
        if not chunk:
            break
        buf += chunk
    return buf


def handle(conn: socket.socket, pipe: object, kind: str, label: str) -> None:
    header = read_exactly(conn, 8)
    if len(header) < 8:
        log.warning("short header (%d bytes) — client protocol mismatch?", len(header))
        return
    try:
        size = int(header.decode("ascii", "ignore").strip() or 0)
    except ValueError:
        log.warning("bad header %r", header)
        return
    payload = read_exactly(conn, size)
    if not payload:
        conn.sendall(b"")
        return

    started = time.time()
    tmp_path = None
    sent = 0

    def progress(pct: int) -> None:
        nonlocal sent
        send_frame(conn, FRAME_PROGRESS, b"%d" % pct)
        sent += 1

    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
            fh.write(payload)
            tmp_path = fh.name
        text, audio_dur, kept = transcribe(pipe, kind, tmp_path, on_progress=progress)
        elapsed = time.time() - started
        log.info(
            "%.1fs audio / %d bytes -> %d chars in %.2fs (%.0fx realtime, %s, %d progress frames, vad %.2fs)",
            audio_dur, len(payload), len(text), elapsed,
            (audio_dur / elapsed if elapsed else 0), label, sent,
            kept if kept is not None else -1.0,
        )
        if not text and kept is not None and kept <= 0.05:
            # The VAD removed the whole clip: nothing to transcribe, here or anywhere.
            # Saying it explicitly is what lets the client skip a fallback round trip.
            send_frame(conn, FRAME_NO_SPEECH, b"")
        else:
            send_frame(conn, FRAME_TEXT, text.encode("utf-8"))
    except Exception:
        log.exception("transcription failed")
        try:
            conn.sendall(b"")
        except OSError:
            pass
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def main() -> int:
    SOCK.parent.mkdir(parents=True, exist_ok=True)
    if SOCK.exists():
        SOCK.unlink()
    pipe, kind, label = load()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCK))
    os.chmod(SOCK, 0o600)
    server.listen(8)
    log.info("listening on %s (%s)", SOCK, label)

    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            continue
        try:
            handle(conn, pipe, kind, label)
        finally:
            conn.close()


if __name__ == "__main__":
    sys.exit(main())
