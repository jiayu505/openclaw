# OpenClaw One-Click Deploy Toolkit for Ubuntu

> From zero to a fully working AI agent with Matrix chat — two scripts, two commands.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Node.js](https://img.shields.io/badge/Node.js-22-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-Latest-FF6B6B?logo=lobster&logoColor=white)](https://openclaw.ai)
[![Matrix](https://img.shields.io/badge/Matrix-Synapse-0DBD8B?logo=matrix&logoColor=white)](https://matrix.org)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)

---

## What's Included

| Script | What it does |
|--------|-------------|
| `install-openclaw.sh` | Install OpenClaw + Node.js + swap + firewall on a fresh Ubuntu VPS |
| `setup-matrix-for-openclaw.sh` | Deploy a full Matrix stack (Synapse + Element Web + Nginx + SSL) and wire it to OpenClaw |

Run them in order — first install OpenClaw, then set up Matrix as the chat channel.

---

## What is OpenClaw?

[OpenClaw](https://openclaw.ai) is a free, open-source **autonomous AI agent** that runs on your own server. Connect it to WhatsApp, Telegram, Discord, or Signal — then control it with natural language to handle real-world tasks: scheduling, email triage, web automation, shopping, and more.

- **Self-hosted** — your data stays on your machine
- **Multi-platform** — WhatsApp, Telegram, Discord, Signal, Web UI
- **Multi-model** — Claude, GPT, DeepSeek, Gemini, and more
- **Extensible** — 3,000+ community skills on [ClawHub](https://clawhub.ai)

## Why This Toolkit?

The official OpenClaw install works great on a local machine, but **deploying to a cloud VPS** involves extra steps — swap, firewall, npm permissions, systemd, and especially setting up a self-hosted Matrix server for chat.

This toolkit handles **everything** in two commands, taking you from a fresh Ubuntu server to a fully working OpenClaw + Matrix setup.

## Step 1: Install OpenClaw

### Prerequisites

| Item | Requirement |
|------|-------------|
| Server | AWS Lightsail Ubuntu 22.04 LTS (recommended: 4 vCPU / 16 GB) |
| Access | SSH access to the server |
| API Key | Anthropic, OpenAI, Google, or other LLM provider |
| Chat App | Telegram, WhatsApp, Discord, or Signal account |

### One-Line Install

SSH into your server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/jiayu505/openclaw/master/install-openclaw.sh | sudo bash
```

That's it. The script will:

1. Update system packages
2. Install all dependencies (Node.js 22, Chromium, build tools)
3. Create and configure 4 GB swap space
4. Set up npm global path (no permission issues)
5. Install OpenClaw via npm
6. Configure UFW firewall (SSH only, port 18789 blocked from public)
7. Enable systemd linger for persistent background service

After installation, run the onboarding wizard:

```bash
source ~/.bashrc
openclaw onboard --install-daemon
```

### Verify Installation

```bash
openclaw doctor    # check configuration
openclaw status    # check gateway status
```

## Access Web Dashboard

**Do NOT expose port 18789 to the public internet.** Use an SSH tunnel instead:

```bash
# Run this on your LOCAL machine
ssh -L 18789:localhost:18789 ubuntu@<YOUR_SERVER_IP>
```

Then open [http://localhost:18789](http://localhost:18789) in your browser.

## What the Script Does

```
Step 1/7  System Update         apt update & upgrade
Step 2/7  Dependencies          Core tools + Chromium (optional)
Step 3/7  Swap                  4 GB swapfile + sysctl tuning
Step 4/7  Node.js 22            Via NodeSource official repo
Step 5/7  npm Config            Global prefix → ~/.npm-global
Step 6/7  OpenClaw              npm install -g openclaw@latest
Step 7/7  Firewall & systemd    UFW (SSH only) + loginctl linger
```

**Idempotent** — safe to run multiple times. Already-completed steps are automatically skipped.

## Security Notes

- The script runs with `sudo` but installs OpenClaw under your **normal user account**
- UFW is configured to **only allow SSH** — the OpenClaw web port (18789) is not exposed
- Always access the dashboard via **SSH tunnel** or **Tailscale**
- Your Gateway Token is equivalent to a password — keep it safe
- Review the [OpenClaw security docs](https://docs.openclaw.ai) for production hardening

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `openclaw: command not found` | Run `source ~/.bashrc` to reload PATH |
| npm install hangs | Check available memory with `free -h`, ensure swap is active |
| Permission denied | Make sure you run with `sudo`, not as root directly |
| Firewall blocks SSH | Script uses `ufw allow OpenSSH` before enabling — this shouldn't happen. If locked out, use Lightsail web console |

---

## Step 2: Matrix Chat Channel (Optional)

After OpenClaw is installed and onboarded, deploy a self-hosted Matrix server so you can chat with your AI agent via a web UI.

### What it Deploys

```
Synapse          Matrix homeserver (Docker)
Element Web      Web chat client (Docker)
Nginx            Reverse proxy with SSL (Docker)
Let's Encrypt    Auto-renewing TLS certificates
Bot account      Auto-created with access token
OpenClaw config  Auto-wired to the Matrix channel
```

### Prerequisites

| Item | Requirement |
|------|-------------|
| OpenClaw | Already installed and gateway running |
| Domain | Two DNS A records pointing to your server IP |
| Ports | 80 and 443 available |

### Usage

1. Edit the config section at the top of the script (domain, email, etc.)
2. Run:

```bash
chmod +x setup-matrix-for-openclaw.sh && sudo bash setup-matrix-for-openclaw.sh
```

3. Open `https://your-domain.com` in a browser and register your user account
4. Create a room, invite the bot: `/invite @openclaw:your-domain.com`
5. Send a message — the bot replies with a pairing code
6. Approve on the server:

```bash
openclaw pairing approve matrix <pairing-code>
```

7. **Important** — After pairing, disable public registration:

```bash
sed -i 's/enable_registration: true/enable_registration: false/' /opt/matrix/synapse/homeserver.yaml
sed -i 's/enable_registration_without_verification: true/enable_registration_without_verification: false/' /opt/matrix/synapse/homeserver.yaml
docker restart synapse
```

### Architecture

```
User (Browser)
  │
  ▼
Element Web ◄──── https://your-domain.com
  │
  ▼
Nginx (SSL termination)
  │
  ├──► Synapse ◄── https://matrix.your-domain.com
  │       ▲
  │       │
  │    OpenClaw Bot (matrix-bot-sdk)
  │       ▲
  │       │
  └──► OpenClaw Gateway
```

### Gotchas

> These are hard-won lessons from actual deployment — documented so you don't repeat them.

- The OpenClaw Matrix plugin config field is `homeserver`, **NOT** `homeserverUrl`
- You must manually `npm install @vector-im/matrix-bot-sdk` into OpenClaw's `node_modules` — the script does this automatically
- Pairing requires sending a message in Element first, then approving on the server
- SSL certificates auto-renew via cron (daily at 3 AM)

---

## Supported Platforms

This script is tested on:

- **AWS Lightsail** — Ubuntu 22.04 LTS
- **DigitalOcean Droplets** — Ubuntu 22.04
- **Vultr** — Ubuntu 22.04
- **Any VPS** running Ubuntu 22.04+ with systemd

## Related Resources

- [OpenClaw Official Site](https://openclaw.ai)
- [OpenClaw Documentation](https://docs.openclaw.ai)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [ClawHub Skills Marketplace](https://clawhub.ai)

## License

MIT
