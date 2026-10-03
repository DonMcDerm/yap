# yap

Push-to-talk dictation for a Wayland/Hyprland desktop. You press a key, talk, press it
again, and the transcript is pasted into the window you *started* in. A resident whisper
daemon keeps the model loaded on the GPU, so a short utterance lands in well under a second.

Measured here (Ryzen 7 5800X3D + RTX 5070, `small.en`, 157 s speech fixture):

| device / compute            | time  | realtime |
|-----------------------------|-------|----------|
| cpu int8, 8 threads         | 7.7 s | 20x      |
| cpu int8, 16 threads        | 10.0 s| 16x      |
| cuda float16                | 8.9 s | 18x      |
| cuda int8_float16           | 1.8 s | 89x      |
| cuda float32                | 1.5 s | 103x     |

Two of those rows are the reason this exists as a project: on a consumer GPU `float16` is
the *slow* path and `float32` is the fast one, and asking for more threads than you have
physical cores makes ctranslate2 slower, not faster. Both were measured, not assumed.

## Why the delivery model is the way it is

On Wayland there is no way to inject keys into a *specific* window — `wtype` always writes to
whatever is focused. So the rule here is about **when** to type, not where:

- the transcript is written to the clipboard and to `~/.cache/yap/last.txt` *before* anything
  is typed, so it cannot be lost from that point on;
- if the window focused when recording **started** is still focused, it receives exactly
  **one paste keystroke**; if focus moved, nothing is typed at all and a notification says so;
- `SUPER+SHIFT+H` inserts the last transcript into whatever is focused *now*.

An earlier version streamed the transcript as synthetic keystrokes. A 5,500-character
transcript is thousands of key events spread over seconds, and any key pressed mid-stream
retargets the rest of the text — one Tab sent the remainder of a dictation into another
window, opening a browser tab on the way. Hence: one keystroke maximum, and never into a
window you did not start in.

## Requirements

- **Hyprland** — focus identity comes from `hyprctl -j activewindow`, the paste from `wtype`.
  Neither has a drop-in equivalent on other compositors; those two functions are the port.
- `ffmpeg` / `ffprobe` (capture), `pactl` (input device state), `jq`, `wl-clipboard`
  (`wl-copy`), `notify-send`
- Omarchy's `omarchy-osd` / `omarchy-shell` for the progress OSD. **Optional** — without it,
  progress degrades to a single replaced notification bubble (never a stack of them).
- python3 + `faster-whisper` in a venv for the daemon; CUDA wheels optional (CPU fallback).

## Install

    git clone <your-fork-url> ~/projects/yap
    cd ~/projects/yap
    ./install.sh                 # venv + CUDA wheels if an NVIDIA GPU is present + the service
    ./install.sh --cpu           # skip the CUDA wheels
    ./install.sh --no-service    # files and venv only

Then add the two binds from `examples/hyprland.lua` to `~/.config/hypr/bindings.lua`,
`hyprctl reload`, and give the daemon a second to load the model:

    ~/.local/bin/yap --check                 # which input device, and is it alive
    ~/.local/bin/yap --transcribe-test F.wav # real wav through the daemon: progress frames + transcript

`install.sh` never edits your Hyprland config — it prints the bind lines.

## Config

The client sources `~/.config/yap/config` if it exists, so nothing site-specific lives in
the script:

| key | default | meaning |
|---|---|---|
| `YAP_REMOTE` | *(empty)* | fallback command, see below |
| `YAP_REMOTE_TIMEOUT` | `180` | seconds before the fallback is abandoned |
| `YAP_DIR` | `~/.cache/yap` | clips, logs, last transcript |
| `YAP_SOCK` | `$YAP_DIR/stt.sock` | daemon socket (must match on both sides) |
| `YAP_MAX_SECS` | `600` | recording cap; hitting it stops and delivers like any other stop |
| `YAP_SILENCE_DB` | `-60` | clip peak at or below this = nothing was picked up |

The daemon takes its own environment (the unit sets it): `YAP_MODEL` (default `small.en`;
use `small`/`large-v3` for non-English), `YAP_LANGUAGE` (default `en`, empty = auto-detect),
`YAP_DEVICE` (`auto|cuda|cpu`), `YAP_THREADS`, `YAP_BATCH`, `YAP_BEAM` (default `5`),
`YAP_PROMPT` / `YAP_PROMPT_FILE` (default: no biasing), `YAP_SOCK`.

### Accuracy knobs

Greedy decode mangles exactly the words that matter — names, jargon, acronyms. Two settings
fix it for a fraction of a second of extra decode (measured: +0.7 s on a 155 s clip):

- `YAP_BEAM=5` (the default) replaces beam_size=1 greedy decode;
- `YAP_PROMPT` biases the decoder toward your own recurring vocabulary. It is **empty by
  default** — ship the tool, not somebody else's word list — and you set yours in the daemon's
  environment:

      YAP_PROMPT="Verbatim dictation, keep the speaker's own wording. Recurring vocabulary: Kubernetes, pgvector, gRPC, Terraform."

  The daemon uses faster-whisper's `hotwords` when the installed build supports it and falls
  back to `initial_prompt` when it does not. Set `YAP_PROMPT` when you run `./install.sh` and it
  writes the text to `~/.config/yap/prompt.txt`, which the daemon reads when `YAP_PROMPT` is not
  in its environment (`YAP_PROMPT_FILE` overrides the path). The file route exists because a
  systemd `Environment=` value containing spaces has to be quoted, and quoting adds escape rules
  of its own. An empty `YAP_PROMPT` means "bias nothing", deliberately.

### The remote fallback

`YAP_REMOTE` is **any command that reads an audio file on stdin and prints the transcript on
stdout**. It runs only when the local daemon returns nothing, so a dead socket on a laptop
still produces text:

    # transcribe on another machine over ssh
    YAP_REMOTE="ssh -i $HOME/.ssh/yap-remote user@host ~/.local/bin/transcribe-stdin"

`remote/transcribe-stdin` is a generic one built on the same venv layout. Anything that
honours the stdin/stdout contract works — including a call into some other agent's STT tool.

## Usage

    SUPER+H          start / stop recording
    SUPER+SHIFT+H    insert the last transcript where you are now
    yap --check [--source NAME]      input device + 2 s live level
    yap --last [--no-type]           insert (or only copy) the last transcript
    yap --dry-run                    print the delivery decision, send nothing
    yap --deliver-test               assert a focus change can't type into the wrong window
    yap --transcribe-test [FILE]     wav through the daemon, print the progress sequence
    yap --bar-test, --progress-test [secs]   drive the OSD looks

## How it works

    yap (bash)  --unix socket-->  sttd.py (python, model resident)  -->  cuda, or cpu

The client records 16 kHz mono with ffmpeg, then speaks a two-line protocol: 8 ASCII digits
of byte length followed by the raw audio. The daemon answers with framed replies — type byte
`\x01` + length + percentage while the decoder advances, then `\x02` + length + the
transcript, then closes. Control bytes cannot appear in a transcript, so a client that sees
anything else treats the whole stream as raw text and stays compatible with an older daemon.
Because `transcribe()` returns a generator of segments, each iteration is real completion —
the progress bar is measured, not estimated. The full spec is in `src/sttd.py`'s docstring.

## Pitfalls (each of these was hit for real)

- **`av` 19 breaks `faster-whisper` 1.2.1**, which calls `av.open(..., metadata_errors=...)`.
  The symptom is not an error: the daemon accepts the connection and returns an empty string.
  Pin `av==18.1.0`.
- **`LD_LIBRARY_PATH` must be set before python starts.** ctranslate2 `dlopen`s
  `libcublas.so.12`/`libcudnn.so.9`; setting `os.environ` inside the script is too late for the
  dynamic loader, so the env lives in the systemd unit.
- **A unix socket file outlives its daemon.** Stat-ing it proves nothing — poll by connecting.
- **Silence transcribes to nothing.** VAD removes 100 % of a dead-mic recording and returns an
  empty string with no complaint. The client therefore checks the input port *before* recording
  and the clip's peak *after*, and says which one failed.
- **USB mics publish `availability unknown`, not `available`.** Only `not available` on *all*
  ports means the jack is empty; treating "unknown" as unplugged blocks every dictation.
- **Don't drive progress with `notify-send` on Omarchy**: quickshell re-shows the popup on each
  update, stacking a column of them. One OSD surface, or one replaced bubble elsewhere.

## License

MIT — see LICENSE.
