#!/bin/bash

set -x

mkdir -p ~/.bin

# Install audio fix script
cat > ~/.bin/audio-fix.sh << 'EOF'
#!/bin/bash

fix_speakers() {
  amixer -c 2 set 'Headphone' mute
  amixer -c 2 set 'Speaker' unmute
  amixer -c 2 set 'Bass Speaker' unmute
  amixer -c 2 set 'Master' 100%
  amixer -c 2 set 'AMP1 Speaker' 100%
  amixer -c 2 set 'AMP2 Speaker' 100%
  amixer -c 2 set 'Speaker' 100%
  pactl set-sink-port alsa_output.pci-0000_65_00.6.analog-stereo analog-output-speaker
}

fix_headphones() {
  amixer -c 2 set 'Speaker' mute
  amixer -c 2 set 'Bass Speaker' mute
  amixer -c 2 set 'Headphone' unmute
  amixer -c 2 set 'Headphone' 100%
}

case "$1" in
speakers) fix_speakers ;;
headphones) fix_headphones ;;
*)
  echo "Usage: $0 speakers|headphones"
  ;;
esac
EOF
chmod +x ~/.bin/audio-fix.sh

# Install port watcher script
cat > ~/.bin/alc285-port-watch.sh << 'EOF'
#!/bin/bash

SINK="alsa_output.pci-0000_65_00.6.analog-stereo"
FIX_SCRIPT="$HOME/.bin/audio-fix.sh"
PREV_PORT=""

get_active_port() {
    pactl list sinks | grep -A 50 "$SINK" | grep 'Active Port' | awk '{print $3}'
}

# Sync immediately on startup instead of waiting for the first change event.
# Without this, if nothing touches the sink after boot, the watcher does
# nothing for the entire session.
INITIAL_PORT=$(get_active_port)
if [[ -n "$INITIAL_PORT" ]]; then
    PREV_PORT="$INITIAL_PORT"
    if [[ "$INITIAL_PORT" == "analog-output-headphones" ]]; then
        bash "$FIX_SCRIPT" headphones
    elif [[ "$INITIAL_PORT" == "analog-output-speaker" ]]; then
        bash "$FIX_SCRIPT" speakers
    fi
fi

pactl subscribe | grep --line-buffered "on sink #" | while read -r event; do
    PORT=$(get_active_port)
    if [[ "$PORT" != "$PREV_PORT" && -n "$PORT" ]]; then
        PREV_PORT="$PORT"
        if [[ "$PORT" == "analog-output-headphones" ]]; then
            bash "$FIX_SCRIPT" headphones
        elif [[ "$PORT" == "analog-output-speaker" ]]; then
            bash "$FIX_SCRIPT" speakers
        fi
    fi
done
EOF
chmod +x ~/.bin/alc285-port-watch.sh

# Install systemd user service
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/alc285-port-watch.service << 'EOF'
[Unit]
Description=ALC285 jack port switch fix
After=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=%h/.bin/alc285-port-watch.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now alc285-port-watch.service
systemctl --user status alc285-port-watch.service
