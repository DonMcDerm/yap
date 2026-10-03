# yap

Push-to-talk dictation for **Omarchy**. Hit `SUPER+H`, talk, hit it again — the transcript
appears in the window you started in, usually in well under a second.

This is Omarchy-specific on purpose. The progress popup is Omarchy's OSD, and the binds are
Omarchy's `o.bind` lines, so another desktop means porting it, not installing it. `AGENTS.md`
says which two functions to swap if you want to.

## Install

    git clone https://github.com/DonMcDerm/yap ~/projects/yap
    cd ~/projects/yap
    ./install.sh

Then paste the two lines from `examples/hyprland.lua` into `~/.config/hypr/bindings.lua`, reload,
and check the microphone before you trust it:

    hyprctl reload && ~/.local/bin/yap --check

`--check` names the input device and shows a two-second live level, so a muted or unplugged mic
is obvious instead of silently transcribing nothing.

## Use

    SUPER + H            start / stop recording
    SUPER + SHIFT + H    insert the last transcript where you are now

    yap --check          input device + live level
    yap --dry-run        print what it would do with the focused window; types nothing
    yap --last           insert (or only copy) the last transcript

Every transcript is written to the clipboard and to `~/.cache/yap/last.txt` before anything is
typed, so `SUPER+SHIFT+H` or Ctrl+V gets it back if the paste doesn't land.

## Settings

All optional, in `~/.config/yap/config`:

    YAP_REMOTE="ssh -i ~/.ssh/key user@host ~/.local/bin/transcribe-stdin"   # fallback, off by default
    YAP_MAX_SECS=600      # recording cap; hitting it stops and delivers like any other stop
    YAP_SILENCE_DB=-60    # a clip peaking at or below this counts as no audio at all

The daemon's settings live in the unit `install.sh` writes: `YAP_MODEL` (default `small.en`),
`YAP_DEVICE`, `YAP_THREADS`, `YAP_BEAM`, and `YAP_PROMPT` — or `~/.config/yap/prompt.txt` — for
your recurring vocabulary.

## What it needs

Omarchy, plus `ffmpeg`, `ffprobe`, `pactl`, `jq`, `wtype`, `wl-copy`, `notify-send` and python3.
An NVIDIA GPU is optional: without one it runs on the CPU, around 20x slower than realtime.

## More detail

- **The model stays loaded.** A small daemon holds the whisper model on the GPU and accepts
  clips over a unix socket, so there is no process start and no reload per utterance.
- **Delivery is one paste keystroke at most**, and only if the window focused when you started
  recording is still focused. An earlier version streamed the text as synthetic keystrokes; a
  keypress mid-stream sent the rest of the transcript into another window, so yap never streams.
  If focus moved, nothing is typed at all and a notification says so.
- **The progress bar is real** — percentages come from the decoder as it advances, not from an
  estimate.
- Everything else — measured numbers, the socket protocol, the pitfalls that cost real time, and
  how to test it without a microphone or a desktop — is in `AGENTS.md`.

## License

MIT.
