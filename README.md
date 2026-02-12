# OpenClaw One-Click Installer for Ubuntu

> Deploy your personal AI agent on AWS Lightsail in under 5 minutes.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![Node.js](https://img.shields.io/badge/Node.js-22-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-Latest-FF6B6B?logo=lobster&logoColor=white)](https://openclaw.ai)

---

## What is OpenClaw?

[OpenClaw](https://openclaw.ai) is a free, open-source **autonomous AI agent** that runs on your own server. Connect it to WhatsApp, Telegram, Discord, or Signal — then control it with natural language to handle real-world tasks: scheduling, email triage, web automation, shopping, and more.

- **Self-hosted** — your data stays on your machine
- **Multi-platform** — WhatsApp, Telegram, Discord, Signal, Web UI
- **Multi-model** — Claude, GPT, DeepSeek, Gemini, and more
- **Extensible** — 3,000+ community skills on [ClawHub](https://clawhub.ai)

## Why This Script?

The official install works great on a local machine, but **deploying to a cloud VPS** (like AWS Lightsail) involves extra steps — swap config, firewall rules, npm permission fixes, systemd setup, etc.

This script handles **everything** in one command so you can go from a fresh Ubuntu server to a running OpenClaw instance without SSH-ing back and forth.

## Quick Start

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
