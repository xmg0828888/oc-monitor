#!/bin/bash
# OC Monitor - One-click agent install
set -e

SERVER="" TOKEN="" NAME="" ROLE="worker"
while getopts "s:t:n:r:" opt; do
  case $opt in s)SERVER="$OPTARG";;t)TOKEN="$OPTARG";;n)NAME="$OPTARG";;r)ROLE="$OPTARG";;esac
done

if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then
  echo "Usage: $0 -s SERVER_URL -t AUTH_TOKEN [-n NAME] [-r ROLE]"
  echo "  -s  Server URL (e.g. http://1.2.3.4:3800)"
  echo "  -t  Auth token"
  echo "  -n  Node name (default: hostname)"
  echo "  -r  Role: master|worker (default: worker)"
  exit 1
fi

[ -z "$NAME" ] && NAME=$(hostname)
AGENT="/usr/local/bin/oc-monitor-agent.sh"

echo "🐾 OC Monitor Agent Installer"
echo "=============================="

# Check deps
for cmd in python3 curl; do
  command -v $cmd &>/dev/null || { echo "❌ $cmd not found"; exit 1; }
done

# Download agent
echo "📦 Downloading agent..."
curl -fsSL https://raw.githubusercontent.com/xmg0828888/oc-monitor/main/agent/agent.sh -o "$AGENT"
chmod +x "$AGENT"

# Detect init system
if [ "$(uname)" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.oc-monitor.agent.plist"
  echo "🍎 Setting up launchd service..."
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.oc-monitor.agent</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string><string>$AGENT</string>
<string>-s</string><string>$SERVER</string>
<string>-t</string><string>$TOKEN</string>
<string>-n</string><string>$NAME</string>
<string>-r</string><string>$ROLE</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/oc-monitor-agent.log</string>
<key>StandardErrorPath</key><string>/tmp/oc-monitor-agent.log</string>
</dict></plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "✅ Agent running (launchd)"
else
  echo "🐧 Setting up systemd service..."
  cat > /etc/systemd/system/oc-monitor-agent.service <<EOF
[Unit]
Description=OC Monitor Agent
After=network.target
[Service]
ExecStart=/bin/bash $AGENT -s $SERVER -t $TOKEN -n $NAME -r $ROLE
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now oc-monitor-agent
  echo "✅ Agent running (systemd)"
fi

echo ""
echo "📡 Node '$NAME' reporting to $SERVER"
echo "📋 Logs: journalctl -u oc-monitor-agent -f"
