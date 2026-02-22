# 🐾 OC Monitor — OpenClaw Mission Control

Real-time monitoring dashboard for [OpenClaw](https://github.com/openclaw/openclaw) multi-node deployments.

![Dashboard](https://img.shields.io/badge/status-active-brightgreen) ![License](https://img.shields.io/badge/license-MIT-blue)

## ✨ Features

- **Real-time metrics** — CPU / Memory / Disk / Swap with live jitter animation (10s refresh)
- **Provider health checks** — Auto-detect all configured AI providers, latency monitoring
- **Default model detection** — Auto-identifies most-used provider per node (green dot indicator)
- **Request logging** — Track API calls across all nodes with filtering by node / provider / result
- **Multi-node support** — Lightweight bash+python agent, works on macOS & Linux
- **Dark / Light theme** — Toggle with localStorage persistence
- **WebSocket push** — Instant updates, no polling
- **Admin panel** — Node management, token display, one-click agent install command generator
- **Docker deployment** — Single container, SQLite storage

## 🚀 Quick Start

### 1. Deploy Server (Docker)

```bash
curl -fsSL https://raw.githubusercontent.com/xmg0828888/oc-monitor/main/install.sh | bash
```

This will:
- Pull the repo and build the Docker image
- Generate a random auth token
- Start the container on port **3800**
- Print the dashboard URL and token

### 2. Install Agent on Each Node

After server is running, install the agent on each OpenClaw node:

```bash
curl -fsSL https://raw.githubusercontent.com/xmg0828888/oc-monitor/main/install-agent.sh | bash -s -- \
  -s http://YOUR_SERVER_IP:3800 \
  -t YOUR_AUTH_TOKEN \
  -n "Node Name"
```

The agent auto-detects:
- OpenClaw config, providers, and models
- System metrics (CPU, memory, disk, swap)
- Gateway & daemon status
- Session count and token usage
- Default/most-used provider

### 3. Open Dashboard

Visit `http://YOUR_SERVER_IP:3800` in your browser.

## 📐 Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Node Agent  │     │  Node Agent  │     │  Node Agent  │
│  (bash+py)   │     │  (bash+py)   │     │  (bash+py)   │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │ HTTP POST          │                     │
       └────────────────────┼─────────────────────┘
                            ▼
                   ┌─────────────────┐
                   │  OC Monitor     │
                   │  Server         │
                   │  (Node.js+SQLite│
                   │   +WebSocket)   │
                   └────────┬────────┘
                            │ WS push
                            ▼
                   ┌─────────────────┐
                   │  Browser        │
                   │  Dashboard      │
                   └─────────────────┘
```

## 🔧 Configuration

| Env Variable | Default | Description |
|---|---|---|
| `PORT` | `3800` | Server listen port |
| `AUTH_TOKEN` | (required) | Bearer token for API auth |

## 📋 API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/api/dashboard` | Full dashboard data |
| POST | `/api/heartbeat` | Agent heartbeat report |
| POST | `/api/request` | API request log (single or batch) |
| POST | `/api/rename` | Rename a node |
| DELETE | `/api/node/:id` | Remove a node |

All POST/DELETE endpoints require `Authorization: Bearer <token>` header.

## License

MIT
