# yap

Push-to-talk dictation for **Omarchy**: press a key, talk, press it again, and your words appear
in the window you were already in. The model runs on your own GPU and stays loaded, so a sentence
lands in well under a second.

## Getting it installed

Don't do this by hand. Hand it to your coding agent — paste this:

    Install yap from https://github.com/DonMcDerm/yap, following AGENTS.md.

That is the whole setup, and `AGENTS.md` is written for exactly that job. The likely outcome is
that the agent does everything and hands you back one small chore: adding the two keybind lines
to your Hyprland config, which it cannot do safely for you.

## Using it

    SUPER + H            start recording, press again to stop
    SUPER + SHIFT + H    put the last transcript wherever you are now

While you talk, a small popup shows a microphone and the seconds ticking. When you stop, it turns
into a progress bar (real progress, read off the decoder) and then flashes `pasted · 380ms` if the
text went in.

If you clicked over to another window before you stopped talking, yap does **not** type into it.
Nothing is lost: the transcript is on your clipboard and a notification says so, and
`SUPER+SHIFT+H` drops it wherever you are now.

The very first dictation after a login is slower, because the model has to load. After that it
stays resident and the wait disappears.

## Tips

- **You talk and nothing ever appears.** That is the microphone, not yap — usually the wrong
  input device, or a muted one. Run `yap --check`: it names the input device and shows a
  two-second live level.
- **The transcript is never only in the pasted place.** It also goes to the clipboard and to
  `~/.cache/yap/last.txt`, so Ctrl+V works even if an app ignored the paste.
- **Long recordings are fine but capped** (ten minutes by default). Hit the cap and it delivers
  what it has, marked in the popup, rather than throwing the recording away.
- **Anything you'd like different** — a bigger model, your own vocabulary, a fallback when the
  desktop is asleep — is a settings line rather than a fork. Ask your agent; the options are in
  `AGENTS.md`.

## License

MIT.
