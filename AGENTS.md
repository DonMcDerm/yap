# yap — notes for coding agents

`yap` is push-to-talk dictation for **Omarchy**. The human-facing `README.md` is user experience
only; everything needed to actually put it on a machine is here. If a user handed you this repo
and asked you to install it, start at "Installing it".

## Installing it

Requirements: Omarchy (Hyprland + quickshell) and, on PATH, `ffmpeg`, `ffprobe`, `pactl`, `jq`,
`wtype`, `wl-copy`, `notify-send`, `python3`. A CUDA GPU is optional — without one the daemon
runs on the CPU at roughly 20x realtime instead of 100x.

    git clone https://github.com/DonMcDerm/yap ~/projects/yap
    cd ~/projects/yap
    ./install.sh              # venv + CUDA wheels if an NVIDIA GPU is present + the user service
    #   --cpu                  skip the CUDA wheels (CPU int8 inference)
    #   --no-service           files and venv only

`install.sh` creates the venv, pins the dependencies, installs `bin/yap` into `~/.local/bin` and
`src/sttd.py` into `~/.local/share/yap`, renders `systemd/yap-sttd.service.in` into
`~/.config/systemd/user/yap-sttd.service` (substituting the venv path, python version, model and
data dir) and starts it. An existing client is backed up as `yap.bak.<epoch>`, never clobbered.
**It never edits the Hyprland config** — the two binds are printed for you to add, from
`examples/hyprland.lua`:

    o.bind("SUPER + H", "Dictate (yap)", "$HOME/.local/bin/yap")
    o.bind("SUPER + SHIFT + H", "Insert last transcript (yap)", "$HOME/.local/bin/yap --last")

`o.bind` is Omarchy's helper; stock Hyprland takes the plain `bind = SUPER, H, exec, …` form.
Adding those lines is the one step worth handing back to the user, since `bindings.lua` is theirs
— or append them, then verify both ways:

    hyprctl reload && hyprctl configerrors                      # expect no output
    omarchy menu keybindings --print | grep -i yap

Finish with a real check of the input path, and report the result:

    ~/.local/bin/yap --check            # names the input device + a 2 s live level
    tail -2 ~/.cache/yap/sttd.log       # expect "listening on … (cuda/float32)" or (cpu/int8)

If the daemon came up on the CPU on a machine that has a CUDA GPU, the nvidia wheels or
`LD_LIBRARY_PATH` are the thing to look at — see the pitfalls.

## Settings and where state lives

Two optional config files, both created on demand:

- `~/.config/yap/config` — sourced by the client. `YAP_REMOTE` (a command that reads audio on
  stdin and prints text on stdout; empty = no fallback), `YAP_REMOTE_TIMEOUT` (180),
  `YAP_DIR` (`~/.cache/yap`), `YAP_SOCK` (`$YAP_DIR/stt.sock`), `YAP_MAX_SECS` (600),
  `YAP_SILENCE_DB` (-60), `YAP_REMOTE_ON_SILENCE` (set = send silent clips to the fallback
  anyway, the pre-v5 behaviour).
- `~/.config/yap/prompt.txt` — the decoder vocabulary (see Accuracy knobs).

Daemon environment, set in the unit: `YAP_MODEL` (default `small.en`; `small`/`large-v3` for
non-English), `YAP_LANGUAGE` (default `en`, empty = auto-detect), `YAP_DEVICE` (`auto|cuda|cpu`),
`YAP_THREADS`, `YAP_BATCH`, `YAP_BEAM` (default 5), `YAP_PROMPT` / `YAP_PROMPT_FILE`, `YAP_SOCK`.
`./install.sh` carries a `YAP_PROMPT` from your environment into `~/.config/yap/prompt.txt`.

Runtime state is all in `~/.cache/yap/`: `clip.wav`, `last.txt`, `last.log`, `sttd.log`,
`progress`, `stt.sock`. **No site-specific value belongs in the code** — if you catch yourself
typing a hostname, a username or a vocabulary list into `bin/yap` or `src/sttd.py`, it belongs in
one of those config files instead.

## Scope

yap targets Omarchy (Hyprland + quickshell) and is not written to be portable. The two couplings
are the progress OSD (`omarchy-osd`, or `omarchy-shell -q osd show` for a custom readout) and
`o.bind`. Both degrade gracefully — with no `omarchy-osd`, progress becomes a single replaced
`notify-send` bubble — and the binds are plain config lines on stock Hyprland. If you are porting
to another compositor, the two functions to replace are `focused_addr` (window identity) and
`send_paste` (a paste chord via `wtype`) in `bin/yap`.

## Layout

| path | what it is |
|---|---|
| `bin/yap` | the client: bash, ~700 lines. Capture, OSD, focus tracking, delivery, self-tests |
| `src/sttd.py` | the daemon: python, ~280 lines. Model load, socket, protocol, progress |
| `systemd/yap-sttd.service.in` | unit template; `install.sh` substitutes `@VENV@ @PYVER@ @MODEL@ @DATADIR@` |
| `install.sh` | venv + pinned deps, files, rendered unit, service |
| `remote/transcribe-stdin` | optional fallback helper for another machine (stdin audio → stdout text) |
| `examples/hyprland.lua` | the two binds |

## Architecture

    bin/yap (bash) --unix socket--> sttd.py (model resident) --> cuda float32, else cpu int8

The client records 16 kHz mono with ffmpeg from the default PipeWire source, sends the bytes over
the socket, and pastes the reply. The daemon loads the model once at start and serves connections
serially. Keep the daemon free of any agent-framework imports — it needs `faster_whisper` and
nothing else.

## Socket protocol (v5)

    client -> daemon:  8 ASCII digits (byte length) then the raw audio bytes
    daemon -> client:  FRAME = type byte + 8 ASCII digits (payload length) + payload
                         \x01 <len> <percent>            progress, as the decoder advances
                         \x02 <len> <utf-8 transcript>   final text, then the daemon closes
                         \x03 <len 0>                    no speech: the VAD kept no audio at all

Control bytes cannot appear in a transcript, so the client decides framing from the first byte:
`1`/`2`/`3` means framed, anything else means an older daemon replying with raw text and the whole
stream is passed through; an unknown control frame is skipped rather than treated as text. `\x03`
exists because an empty transcript from the local model is exactly what the remote fallback is
for, so by the text alone the client cannot tell "the VAD found no speech" from "the local model
missed" — it exits 6 on that frame, which skips the fallback and reports no speech directly.

Progress is free: `transcribe()` returns a generator of segments, so
each iteration is one decoded step and `segment.end / info.duration` is real completion. Frames
are throttled to one per 100 ms and only on a percent change. After changing the daemon, restart
it and confirm the `listening on …` line before testing the client.

## Measured performance

157 s speech fixture, `small.en`, Ryzen 7 5800X3D + RTX 5070:

| config | time | realtime |
|---|---|---|
| cpu int8, 8 threads | 7.7 s | 20x |
| cpu int8, 16 threads | 10.0 s | 16x |
| cuda float16 | 8.9 s | 18x |
| cuda int8_float16 | 1.8 s | 89x |
| cuda float32 | 1.5 s | 103x |

Two non-obvious results drive the device ladder: `float16` is the *slow* path on a consumer GPU
while `float32` is the fast one, and threads above the physical core count make ctranslate2
slower through SMT contention.

### Accuracy knobs

Greedy decode mangles exactly the words that matter — names, jargon, acronyms. `YAP_BEAM=5` (the
default) replaces `beam_size=1`, and a vocabulary list biases the decoder toward the user's own
terms (measured: +0.7 s on the 155 s clip). Bias with `hotwords` when the installed
faster-whisper supports it, `initial_prompt` otherwise. The vocabulary is **empty by default** —
ship the tool, not somebody else's word list. The user sets theirs in
`~/.config/yap/prompt.txt`, or in `YAP_PROMPT` (which wins when set at all, including when set to
the empty string to mean "bias nothing"). The file route exists because a systemd `Environment=`
value containing spaces must be quoted, and quoting adds escape rules of its own.

## Delivery model — the constraints are real, do not relax them

On Wayland there is no way to inject keys into a *specific* window; `wtype` writes to whatever is
focused. Therefore:

1. the transcript is written to the clipboard and `~/.cache/yap/last.txt` **before** any typing,
   so it cannot be lost;
2. exactly **one** keystroke is sent — a paste chord — and only if the window focused at record
   start is still focused (compare `hyprctl -j activewindow` addresses, never titles: titles
   change and a reopened window gets a new address);
3. otherwise nothing is typed and a notification says the text is on the clipboard.

Never reintroduce keystroke streaming. A 5.5k-character transcript is thousands of synthetic
events over seconds, and any key pressed during that window retargets the remainder into another
window — observed for real, with a Tab that opened a browser tab.

## Pitfalls (each of these was hit and diagnosed on a real setup)

- **`av` 19 breaks faster-whisper 1.2.1**, which calls `av.open(..., metadata_errors=...)`. The
  symptom is an empty transcript, not an error. `install.sh` pins `av==18.1.0`.
- **`LD_LIBRARY_PATH` must exist before python starts.** ctranslate2 dlopens
  `libcublas.so.12` / `libcudnn.so.9`; setting `os.environ` inside the script is too late, so the
  nvidia wheel paths live in the unit's `Environment=`.
- **A unix socket file outlives its daemon.** Stat-ing it proves nothing — poll by connecting.
- **`Environment=` values with spaces are silently truncated by systemd.** It logs
  `Invalid environment assignment, ignoring: <word>` and keeps only the first token. That is why
  the decoder prompt is a file, not an inline unit value.
- **Silence transcribes to nothing, and an empty transcript is what the fallback retries.** VAD
  removes 100 % of a dead-mic clip and returns an empty string without complaint, so a silent press
  used to cost the whole remote round trip — measured at 4.8 s, with the clip uploaded to the other
  machine — before the popup could say anything. The daemon now reports that case as its own
  verdict (`duration_after_vad` ≈ 0 → frame `\x03`) and the client skips the fallback on it. The
  input port is still checked *before* recording and the clip peak *after*, so a dead microphone is
  named before any of this runs.
- **USB mics publish `availability unknown`, not `available`.** Only `not available` on *all*
  ports means an empty jack; treating "unknown" as unplugged blocks every dictation.
- **Do not drive progress with `notify-send` on Omarchy** — quickshell re-shows the popup on each
  update, stacking a column of them. One OSD surface, or one replaced bubble elsewhere.
- **Starting the daemon in a test and killing it in the same shell command** costs you the
  wrapper process if you use `pkill -f` with a pattern that also matches your own command line.
  Kill by explicit PID.

## Testing without a microphone or a desktop

Both halves run on a CPU-only box, so nothing here needs the desktop session:

    # daemon + protocol (any python with faster-whisper; the model downloads on first use)
    YAP_SOCK=/tmp/yap-test/stt.sock YAP_MODEL=tiny.en YAP_DEVICE=cpu python3 src/sttd.py &

    # the client's socket code, extracted from the <<'PY' … PY heredoc in bin/yap
    python3 ask_local.py clip16k.wav /tmp/yap-test/stt.sock /tmp/yap-test/progress

Expect the daemon log to print `N s audio / N bytes -> N chars in N s (Nx realtime, cpu/int8, N
progress frames, vad N s)` and the progress file to end at `100`. Any 16 kHz mono speech wav will do.

    # the fallback helper: a "venv" whose python exports PYTHONPATH, then pipe audio in
    YAP_REMOTE_VENV=/tmp/fakevenv ./remote/transcribe-stdin < clip16k.wav

Self-tests that need no audio at all, runnable on a live desktop: `yap --bar-test`,
`yap --dry-run` (prints the delivery decision; sends nothing), `yap --deliver-test` (asserts a
focus change routes to the clipboard), `yap --fail-test` (prints every failure message with
`YAP_NOTIFY_DRY=1`, so nothing is posted and no audio is needed). `yap --transcribe-test FILE` runs a wav through the real
daemon and prints the progress sequence.

## Repo conventions

One commit per change, plain imperative subject. The client stays a single file and the daemon
stays free of framework imports: everything a reader needs to trace should stay visible in one
file, and neither should grow a package tree or a layer of indirection.
