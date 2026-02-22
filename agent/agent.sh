#!/bin/bash
# OpenClaw Monitor Agent
# Usage: ./agent.sh -s http://server:3800 -t TOKEN [-n name] [-r master|worker]

set -e

SERVER="" TOKEN="" NAME="" ROLE="worker" INTERVAL=30

while getopts "s:t:n:r:i:" opt; do
  case $opt in
    s) SERVER="$OPTARG";;
    t) TOKEN="$OPTARG";;
    n) NAME="$OPTARG";;
    r) ROLE="$OPTARG";;
    i) INTERVAL="$OPTARG";;
  esac
done

[ -z "$SERVER" ] || [ -z "$TOKEN" ] && echo "Usage: $0 -s SERVER_URL -t TOKEN [-n name] [-r role]" && exit 1

NODE_ID=$(hostname | md5sum 2>/dev/null | cut -c1-12 || hostname | md5 | cut -c1-12)
NAME="${NAME:-$(hostname)}"
HOST=$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo "unknown")
OS_INFO=$(uname -s -r -m)

# Detect OpenClaw config
find_oc_config() {
  for p in "$HOME/.openclaw/openclaw.json" "/root/.openclaw/openclaw.json" "/etc/openclaw/openclaw.json"; do
    [ -f "$p" ] && echo "$p" && return
  done
  echo ""
}

OC_CONFIG=$(find_oc_config)
OC_VERSION="unknown"
if command -v openclaw &>/dev/null; then
  OC_VERSION=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
fi

# Get providers from config
get_providers() {
  [ -z "$OC_CONFIG" ] && echo "[]" && return
  python3 -c "
import json,sys
try:
  c=json.load(open('$OC_CONFIG'))
  ps=[]
  for n,p in c.get('models',{}).get('providers',{}).items():
    if not isinstance(p,dict): continue
    for m in p.get('models',[]):
      ps.append({'name':n,'model':m.get('id',''),'api':p.get('api','')})
  print(json.dumps(ps))
except: print('[]')
" 2>/dev/null || echo "[]"
}

# System metrics
get_cpu() { top -bn1 2>/dev/null | grep 'Cpu' | awk '{print 100-$8}' || echo 0; }
get_mem() { free 2>/dev/null | awk '/Mem/{printf "%.1f",$3/$2*100}' || vm_stat 2>/dev/null | awk '/Pages active/{a=$3}/page size/{p=$8}END{printf "%.0f",a*p/1024/1024/1024*100/8}' || echo 0; }
get_disk() { df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}' || echo 0; }
get_swap() { free 2>/dev/null | awk '/Swap/{if($2>0)printf "%.1f",$3/$2*100;else print 0}' || echo 0; }
get_uptime() { awk '{printf "%d",$1}' /proc/uptime 2>/dev/null || sysctl -n kern.boottime 2>/dev/null | awk -F'[= ,]' '{print systime()-$6}' || echo 0; }

# Check gateway/daemon
check_gw() { pgrep -f "openclaw.*gateway" &>/dev/null && echo true || echo false; }
check_daemon() { pgrep -f "openclaw.*daemon\|openclaw-daemon" &>/dev/null && echo true || echo false; }

# Session count
get_sessions() {
  local sf="$HOME/.openclaw/sessions.json"
  [ -f "$sf" ] && python3 -c "import json;print(len(json.load(open('$sf'))))" 2>/dev/null || echo 0
}

CONFIG_MTIME=0

echo "OC Monitor Agent started: node=$NODE_ID name=$NAME server=$SERVER"

# Main loop
while true; do
  # Check config change
  PROVIDERS="[]"
  if [ -n "$OC_CONFIG" ] && [ -f "$OC_CONFIG" ]; then
    MT=$(stat -c %Y "$OC_CONFIG" 2>/dev/null || stat -f %m "$OC_CONFIG" 2>/dev/null || echo 0)
    if [ "$MT" != "$CONFIG_MTIME" ]; then
      PROVIDERS=$(get_providers)
      CONFIG_MTIME="$MT"
      echo "Config changed, providers updated"
    else
      PROVIDERS=$(get_providers)
    fi
  fi

  # Build payload
  PAYLOAD=$(cat <<EOF
{
  "id":"$NODE_ID","name":"$NAME","host":"$HOST",
  "os":"$OS_INFO","oc_version":"$OC_VERSION","role":"$ROLE",
  "providers":$PROVIDERS,
  "cpu":$(get_cpu),"mem":$(get_mem),"disk":$(get_disk),"swap":$(get_swap),
  "sessions":$(get_sessions),"gw_ok":$(check_gw),"daemon_ok":$(check_daemon),
  "uptime":$(get_uptime)
}
EOF
)

  # Send heartbeat
  curl -sS -X POST "$SERVER/api/heartbeat" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" -m 10 >/dev/null 2>&1 || echo "Heartbeat failed"

  sleep "$INTERVAL"
done
