#!/bin/bash
# bench-yap.sh -- what every piece of yap costs on this machine.
#
# One measurement per moving part: each external tool the client spawns, the capture stack,
# the stop press, the model, and finally one real press through the client itself so the
# parts can be reconciled against the whole. Medians of N runs.
#
#   bench-yap.sh [N]        runs per measurement (default 5; visible ones use fewer)
set -uo pipefail
N="${1:-5}"
SD="${YAP_DIR:-$HOME/.cache/yap}"
SRC_IDLE="alsa_input.pci-0000_2d_00.4.analog-stereo"   # unconnected line-in: a real device, no content

median_n() {   # median_n <runs> <label> <cmd...>
  local n="$1" label="$2"; shift 2
  local vals=() t0 t1
  for _ in $(seq 1 "$n"); do
    t0=$(date +%s%N)
    timeout 15 "$@" >/dev/null 2>&1
    t1=$(date +%s%N)
    vals+=("$(( (t1 - t0) / 1000000 ))")
  done
  printf '%-38s %5s\n' "$label" "$(printf '%s\n' "${vals[@]}" | sort -n | sed -n "$(( (n + 1) / 2 ))p")"
}
median_of() { median_n "$N" "$@"; }
section() { printf '\n%s\n' "$1"; }

echo "yap component benchmark -- $(date '+%Y-%m-%d %H:%M') -- median of $N runs, ms"

section "tools the client spawns (one call each)"
median_of "date +%s%N"                    date +%s%N
median_of "awk BEGIN{}"                   awk 'BEGIN{}'
median_of "grep -E"                       grep -E x /dev/null
median_of "sed -n"                        sed -n 1p /dev/null
median_of "cat (small file)"              cat /etc/hostname
median_of "python3 -c pass"               python3 -c pass
median_of "pactl get-default-source"      pactl get-default-source
median_of "pactl list sources"            pactl list sources
median_of "hyprctl -j activewindow"       hyprctl -j activewindow
median_of "hyprctl -j clients"            hyprctl -j clients
median_of "jq on a cached payload"        jq -r .address <<<"{\"address\":\"0x1\",\"class\":\"com.mitchellh.ghostty\"}"
median_of "wl-copy (write clipboard)"     wl-copy probe
median_n 2 "notify-send (post popup)"     notify-send -a yap -u low -t 400 bench "component timing"
median_n 2 "omarchy-osd -m (text mode)"   omarchy-osd -d 600 -m bench
median_n 2 "omarchy-shell osd show (bar)" omarchy-shell -q osd show '{"icon":"microphone","message":"","value":"42","max":"100","progressText":"1s","duration":"600"}'
median_of "wtype -h (startup only)"       wtype -h

section "composites, measured the way the client runs them"
t0=$(date +%s%N); hyprctl -j activewindow | jq -r '.address' >/dev/null 2>&1; t1=$(date +%s%N)
printf '%-38s %5s\n' "hyprctl -j activewindow | jq" "$(( (t1 - t0) / 1000000 ))"
t0=$(date +%s%N)
hyprctl -j activewindow | jq -r '.address' >/dev/null 2>&1
hyprctl -j activewindow | jq -r '.class' >/dev/null 2>&1
t1=$(date +%s%N)
printf '%-38s %5s\n' "2 x (hyprctl | jq) = one delivery" "$(( (t1 - t0) / 1000000 ))"
t0=$(date +%s%N); pactl get-default-source >/dev/null 2>&1; pactl list sources >/dev/null 2>&1; t1=$(date +%s%N)
printf '%-38s %5s\n' "pactl pair = one press input check" "$(( (t1 - t0) / 1000000 ))"

section "capture: same idle source, time to first 512 audio bytes"
for spec in "ffmpeg -f pulse:ffmpeg -hide_banner -nostdin -loglevel error -flush_packets 1 -f pulse -i $SRC_IDLE -ac 1 -ar 16000 -f s16le -" \
            "pw-record (native pipewire):pw-record --target $SRC_IDLE --raw --format=s16 --rate=16000 --channels=1 -" \
            "parec (libpulse):parec -d $SRC_IDLE --raw --format=s16le --rate=16000 --channels=1"; do
  label="${spec%%:*}"; cmd="${spec#*:}"
  vals=()
  for _ in 1 2 3; do
    t0=$(date +%s%N)
    timeout 8 bash -c "$cmd" 2>/dev/null | head -c 512 >/dev/null
    t1=$(date +%s%N)
    vals+=("$(( (t1 - t0) / 1000000 ))")
  done
  printf '%-38s %5s\n' "$label" "$(printf '%s\n' "${vals[@]}" | sort -n | sed -n 2p)"
done

section "stop press and clip handling"
vals=()
for _ in 1 2 3; do
  ffmpeg -hide_banner -nostdin -loglevel error -f pulse -i "$SRC_IDLE" -ac 1 -ar 16000 -t 600 -af volumedetect -y /tmp/bench-clip.wav >/dev/null 2>&1 &
  REC=$!
  sleep 2
  t0=$(date +%s%N); kill -INT "$REC" 2>/dev/null; wait "$REC" 2>/dev/null; t1=$(date +%s%N)
  vals+=("$(( (t1 - t0) / 1000000 ))")
done
printf '%-38s %5s\n' "ffmpeg SIGINT -> exit (stop press)" "$(printf '%s\n' "${vals[@]}" | sort -n | sed -n 2p)"
median_of "ffprobe duration on the clip"  ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/bench-clip.wav
median_of "cp clip -> yap-failed.wav"     cp /tmp/bench-clip.wav "$SD/bench-copy.wav"
rm -f /tmp/bench-clip.wav "$SD/bench-copy.wav"

section "decode through the warm daemon (cuda/float32, small.en)"
if [ -S "$SD/stt.sock" ]; then
  cat >/tmp/bench_ask.py <<'PY'
import socket, os, sys, time
path, sock = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(300)
t0 = time.time(); s.connect(os.path.expanduser(sock))
s.sendall(b"%08d" % len(data) + data)
buf = b""
while True:
    c = s.recv(65536)
    if not c: break
    buf += c
ms = int((time.time() - t0) * 1000)
pos = 0; chars = 0; types = []
while pos + 9 <= len(buf):
    k = buf[pos]; n = int(buf[pos+1:pos+9].decode("ascii")); types.append(k)
    if k == 2: chars += n
    pos += 9 + n
print("DECODE %s %d %d %s" % (os.path.basename(path), ms, chars, types))
PY
  for f in "$SD/fixture.opus" "$SD/fixture80.wav"; do
    [ -f "$f" ] || continue
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
    res=$(python3 /tmp/bench_ask.py "$f" "$SD/stt.sock")
    printf '%-38s %5s  (%ss audio, %s chars, frames %s)\n' "$(basename "$f")" \
      "$(echo "$res" | awk '{print $3}')" "${dur%%.*}" "$(echo "$res" | awk '{print $4}')" "$(echo "$res" | awk '{print $5}')"
  done
  ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -y /tmp/bench-sil.wav
  res=$(python3 /tmp/bench_ask.py /tmp/bench-sil.wav "$SD/stt.sock")
  printf '%-38s %5s  (3s of silence, frames %s = the v5 no-speech verdict)\n' "3s of silence" \
    "$(echo "$res" | awk '{print $3}')" "$(echo "$res" | awk '{print $5}')"
  rm -f /tmp/bench-sil.wav /tmp/bench_ask.py
fi

section "one real press through the client (3s of the default source, notifications printed)"
# Uses the DEFAULT source, i.e. a real press. Two guards keep a missed stop press from turning
# into a ten-minute recording: the stop is timeboxed, and the recorder is swept afterwards.
export YAP_NOTIFY_DRY=1
rm -f "$SD/rec.pid" /tmp/bench-e2e.out
"$HOME/.local/bin/yap" --no-type >/tmp/bench-e2e.out 2>&1 &
FIRST=$!
sleep 1
if [ -f "$SD/rec.pid" ]; then
  echo "recording (pid $(cat "$SD/rec.pid")) -- 3s"
  sleep 3
  timeout 10 "$HOME/.local/bin/yap" --no-type >/dev/null 2>&1
  echo "stop press sent"
else
  echo "the start press did not record (check the input: ~/.local/bin/yap --check)"
fi
for _ in $(seq 1 40); do kill -0 "$FIRST" 2>/dev/null || break; sleep 0.5; done
kill -0 "$FIRST" 2>/dev/null && { echo "still running after 20s -- killing"; kill "$FIRST" 2>/dev/null; }
pgrep -f "/home/dmcderm/.local/bin/ya[p] --no-type" | while read -r pid; do kill "$pid" 2>/dev/null; done
grep -a "^timing:" "$SD/last.log" || echo "(no timing line)"
grep -a "^notify" /tmp/bench-e2e.out | head -2
rm -f /tmp/bench-e2e.out "$SD/clip.wav" "$SD/rec.pid" "$SD/.transcribing"

section "one-time and ambient costs"
grep -a "model .* ready in" "$SD/sttd.log" | tail -1
printf '%-38s %5s\n' "OSD tick while recording (1/s, forked)" "$(median_n 3 "osd tick" omarchy-osd -d 900 -m '3s' | awk '{print $2}')"
printf '%-38s\n' "readout: the recording phase forks one OSD per second, the transcribing phase one per 0.25s (only on change)"

section "machine"
printf 'cpu: %s\n' "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
printf 'gpu: %s\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
printf 'hyprland: %s\n' "$(hyprctl version 2>/dev/null | head -1)"
printf 'ffmpeg: %s\n' "$(ffmpeg -version 2>/dev/null | head -1 | cut -c1-60)"
