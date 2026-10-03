# yap — notes for coding agents

Read `README.md` first for what the tool is and how a user installs it. This file carries the
part that only matters if you are changing the code: architecture, protocol, measured numbers,
and the mistakes that cost real time here.

**Scope.** yap targets Omarchy (Hyprland + quickshell) and is not written to be portable. The
two Omarchy couplings are the progress OSD (`omarchy-osd` / `omarchy-shell -q osd show`) and
`examples/hyprland.lua`'s use of Omarchy's `o.bind` helper. Both have fallbacks — without
`omarchy-osd`, progress degrades to a single replaced `notify-send` bubble — and the keybinds
become plain `bind = SUPER, H, exec, ~/.local/bin/yap` on stock Hyprland.

## Layout

| path | what it is |
|---|---|
| `bin/yap` | the client: bash, ~590 lines. Capture, OSD, focus tracking, delivery, self-tests |
| `src/sttd.py` | the daemon: python, ~265 lines. Model load, socket, protocol, progress |
| `systemd/yap-sttd.service.in` | unit template; `install.sh` substitutes `@VENV@ @PYVER@ @MODEL@ @DATADIR@` |
| `install.sh` | venv + pinned deps, files, rendered unit, service. Never edits Hyprland config |
| `remote/transcribe-stdin` | optional fallback helper for another machine (stdin audio → stdout text) |
| `examples/hyprland.lua` | the two binds, for a human to paste |

State lives in `~/.cache/yap/` (clip, log, last transcript, progress file, socket). User
settings are two files, both optional: `~/.config/yap/config` (sourced by the client) and
`~/.config/yap/prompt.txt` (decoder vocabulary). **No site-specific value belongs in the code** —
if you find yourself typing a hostname, a username or a vocabulary list into `bin/yap` or
`src/sttd.py`, it belongs in one of those two files instead.

## Architecture

    bin/yap (bash) --unix socket--> sttd.py (model resident) --> cuda float32, else cpu int8

The client records 16 kHz mono with ffmpeg from the default PipeWire source, sends the bytes, and
pastes the reply. The daemon loads the model once at start and serves connections serially.

## Socket protocol (v4)

    client -> daemon:  8 ASCII digits (byte length) then the raw audio bytes
    daemon -> client:  FRAME = type byte + 8 ASCII digits (payload length) + payload
                         \x01 <len> <percent>            progress, as the decoder advances
                         \x02 <len> <utf-8 transcript>   final text, then the daemon closes

Control bytes cannot appear in a transcript, so the client decides framing from the first byte:
`1`/`2` means framed, anything else means an older daemon replying with raw text and the whole
stream is passed through. Progress is free: `transcribe()` returns a generator of segments, so
each iteration is one decoded step and `segment.end / info.duration` is real completion. Frames
are throttled to one per 100 ms and only on a percent change.

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
slower through SMT contention. Beam search (`YAP_BEAM=5`, the default) costs roughly 0.7 s on
that fixture versus greedy decode and is what fixed domain-word accuracy.

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

## Pitfalls (each of these was hit and diagnosed here)

- **`av` 19 breaks faster-whisper 1.2.1**, which calls `av.open(..., metadata_errors=...)`. The
  symptom is an empty transcript, not an error. `install.sh` pins `av==18.1.0`.
- **`LD_LIBRARY_PATH` must exist before python starts.** ctranslate2 dlopens
  `libcublas.so.12` / `libcudnn.so.9`; setting `os.environ` inside the script is too late, so the
  nvidia wheel paths live in the unit's `Environment=`.
- **A unix socket file outlives its daemon.** Stat-ing it proves nothing — poll by connecting.
- **`Environment=` values with spaces are silently truncated by systemd.** It logs
  `Invalid environment assignment, ignoring: <word>` and keeps only the first token. That is why
  the decoder prompt is a *file* (`~/.config/yap/prompt.txt`), not an inline unit value.
- **Silence transcribes to nothing.** VAD removes 100 % of a dead-mic clip and returns an empty
  string without complaint. The client checks the input port *before* recording and the clip peak
  *after*, and names which one failed.
- **USB mics publish `availability unknown`, not `available`.** Only `not available` on *all*
  ports means an empty jack; treating "unknown" as unplugged blocks every dictation.
- **Do not drive progress with `notify-send` on Omarchy** — quickshell re-shows the popup on each
  update, stacking a column of them. One OSD surface, or one replaced bubble elsewhere.

## Testing without a microphone or a desktop

Both halves run on a CPU-only box, so nothing here needs the desktop session:

    # daemon + protocol, using the Hermes uv store for faster-whisper (any env with it works)
    PYTHONPATH=$(ls -d ~/.hermes/cache/uv/archive-v0/*/ | tr '\n' ':')
    YAP_SOCK=/tmp/yap-test/stt.sock YAP_MODEL=tiny.en YAP_DEVICE=cpu python3 src/sttd.py &

    # the client's socket code, extracted from the heredoc in bin/yap, against that socket
    # (fixture: ~/.hermes/hermes-agent/tools/neutts_samples/jo.wav — real speech, no synthesis)
    python3 ask_local.py clip16k.wav /tmp/yap-test/stt.sock /tmp/yap-test/progress

Expect the daemon log to print `N s audio / N bytes -> N chars in N s (Nx realtime, cpu/int8, N
progress frames)` and the progress file to end at `100`.

    # the fallback helper: give it a "venv" whose python exports PYTHONPATH, then pipe audio in
    YAP_REMOTE_VENV=/tmp/fakevenv ./remote/transcribe-stdin < clip16k.wav

Self-tests that need no audio at all, runnable on a live desktop: `yap --bar-test`,
`yap --dry-run` (prints the delivery decision; send nothing), `yap --deliver-test` (asserts a
focus change routes to the clipboard). `yap --transcribe-test FILE` runs a wav through the real
daemon and prints the progress sequence.

## Repo conventions

One commit per change, plain imperative subject. Keep the client a single file and the daemon
free of Hermes imports — neither should grow a package tree or a second layer of indirection;
everything a reader needs to trace should stay visible in one file.
