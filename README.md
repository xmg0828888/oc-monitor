# OpenClaw Monitor

Multi-node monitoring dashboard for OpenClaw instances.

## Architecture

- **Server**: Node.js + SQLite + WebSocket (central dashboard)
- **Agent**: Bash script on each OpenClaw machine, reports heartbeat + metrics

## Quick Start

### Server (Docker)
```bash
docker run -d --name oc-monitor -p 3800:3800 -v oc-monitor-data:/app/data ghcr.io/mango082888-bit/oc-monitor
# Get auth token
docker logs oc-monitor 2>&1 | grep "Auth token"
```

### Agent
```bash
curl -sL https://raw.githubusercontent.com/mango082888-bit/oc-monitor/main/agent/agent.sh -o agent.sh
chmod +x agent.sh
./agent.sh -s http://YOUR_SERVER:3800 -t YOUR_TOKEN -n "My Node" -r master
```

## Features

- Real-time node status (CPU/mem/disk/swap)
- Provider health matrix across all nodes
- API request logging with TTFT/latency tracking
- Auto-detect OpenClaw config changes
- WebSocket live updates
- Dark theme UI

## API

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/api/dashboard` | GET | No | Full dashboard data |
| `/api/heartbeat` | POST | Yes | Agent heartbeat report |
| `/api/request` | POST | Yes | Log API request |
| `/api/node/rename` | POST | Yes | Rename a node |
| `/api/node/:id` | DELETE | Yes | Remove a node |

Auth: `Authorization: Bearer <token>`
