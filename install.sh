#!/bin/bash
# OC Monitor - One-click server install
set -e

PORT=${PORT:-3800}
TOKEN=${TOKEN:-$(head -c 16 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')}
DIR="/opt/oc-monitor"

echo "🐾 OC Monitor Installer"
echo "========================"

# Check docker
if ! command -v docker &>/dev/null; then
  echo "❌ Docker not found. Install docker first."
  exit 1
fi

# Clone or update
if [ -d "$DIR" ]; then
  echo "📦 Updating existing installation..."
  cd "$DIR" && git pull
else
  echo "📦 Cloning repository..."
  git clone https://github.com/mango082888-bit/oc-monitor.git "$DIR"
  cd "$DIR"
fi

# Build and run
echo "🔨 Building Docker image..."
docker build -t oc-monitor .

docker rm -f oc-monitor 2>/dev/null || true
echo "🚀 Starting container..."
docker run -d --name oc-monitor --restart always \
  -p "$PORT:3800" \
  -v oc-monitor-data:/app/data \
  -e "AUTH_TOKEN=$TOKEN" \
  oc-monitor

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || curl -s ifconfig.me)

echo ""
echo "✅ OC Monitor is running!"
echo "========================"
echo "🌐 Dashboard: http://$IP:$PORT"
echo "🔑 Auth Token: $TOKEN"
echo ""
echo "📡 Install agent on each node:"
echo "  curl -fsSL https://raw.githubusercontent.com/mango082888-bit/oc-monitor/main/install-agent.sh | bash -s -- -s http://$IP:$PORT -t $TOKEN -n \"NodeName\""
