# picoclaw-pizero-setup

**Run a personal AI agent on a Raspberry Pi Zero 2W — free, always-on, zero ongoing cost.**

One script turns a €15 Pi Zero 2W into an AI assistant you can reach from anywhere via Telegram. No Anthropic API key. No subscription. No cloud bill.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Pi Zero 2W](https://img.shields.io/badge/hardware-Pi%20Zero%202W-red)](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/)
[![Free LLMs](https://img.shields.io/badge/LLM-free%20tier-brightgreen)](#providers)

---

## What you get

- **Always-on AI agent** — [picoclaw](https://github.com/badass-courses/picoclaw) runs as a systemd service, restarts on crash, starts on boot
- **Telegram interface** — message it from your phone from anywhere
- **Zero ongoing cost** — routes through [free-llm-proxy-router](https://github.com/kaiser-data/free-llm-proxy-router), which pulls from free-tier APIs (Groq, Gemini, OpenRouter, GitHub Models…)
- **Automatic fallback** — if one provider is down or rate-limited, the proxy silently tries the next. No error messages in chat
- **Multiply free quota** — add `GROQ_API_KEY_2`, `_3`… to `.env` and the proxy rotates across your accounts on 429
- **`ask-precise` tool** — a shell command that delegates quick subtasks (summarise a diff, explain a command) to a pinned high-quality model without spending your main budget

---

## Hardware

| | Minimum | Recommended |
|---|---|---|
| Board | Raspberry Pi Zero 2W | Raspberry Pi Zero 2W |
| RAM | 512MB (all you get) | — |
| Storage | 8GB microSD | 32GB microSD |
| OS | Raspberry Pi OS Lite 64-bit (Bookworm) | same |
| Architecture | arm64 | arm64 |

> **Pi Zero 2W only.** The setup script installs Go 1.23 from go.dev (arm64) and builds the proxy binary on-device. The Pi 4 version of this setup lives in [openclaw-pi-setup](https://github.com/kaiser-data/openclaw-pi-setup).

---

## Quick start

```bash
# On the Pi Zero 2W:
curl -fsSL https://raw.githubusercontent.com/kaiser-data/picoclaw-pizero-setup/main/setup-picoclaw-proxy.sh -o setup.sh
bash setup.sh
```

Then follow the prompts. The script is idempotent — safe to re-run after changes or updates.

---

## What the script does

| Step | What happens |
|---|---|
| 1 | Install prerequisites: `curl git jq make` |
| 2 | Install Go 1.23 from go.dev if system Go is too old |
| 3 | Clone / update `free-llm-proxy-router` |
| 3b | Apply local patches (silent fallback, per-model cooldowns, multi-key rotation) |
| 4 | Build proxy binaries on-device |
| 5 | Check for picoclaw binary |
| 6 | Create `~/.free-llm-proxy-router/.env` from template |
| 7 | Create `~/.free-llm-proxy-router/config.yaml` |
| 8 | Run provider scan (if keys present) |
| 9 | Install + start `free-llm-proxy.service` |
| 10 | Write `~/.picoclaw/config.json` pointing at the proxy |
| 11 | Install `picoclaw-agent.service` (disabled by default) |
| 12 | Verify: health check, model list, smoke test |
| 13 | Add `precise` agent profile to config |
| 14 | Install `/usr/local/bin/ask-precise` |

---

## Providers

Free-tier providers the proxy can route through:

| Provider | Free limit | Speed on Pi Zero |
|---|---|---|
| **Groq** | ~14,400 req/day | ⚡ fastest (recommended) |
| **Gemini** | 1,500 req/day | ⚡ fast |
| **GitHub Models** | ~150 req/day | fast |
| **OpenRouter** | varies by model | medium |
| **Cerebras** | rate-limited | fast |
| **Mistral** | rate-limited | medium |
| **HuggingFace** | rate-limited | slow (cold start) |

Add keys for multiple providers — the `adaptive` strategy picks the fastest healthy one automatically.

---

## Multiplying free quota

The proxy auto-discovers numbered key variants in `.env`:

```bash
# ~/.free-llm-proxy-router/.env
GROQ_API_KEY=gsk_first_account
GROQ_API_KEY_2=gsk_second_account   # 2× daily limit
GROQ_API_KEY_3=gsk_third_account    # 3× daily limit
GEMINI_API_KEY_2=AIza...            # same pattern for any provider
```

On 429, the proxy rotates to the next slot. Each slot has its own cooldown — one exhausted key doesn't block the others.

---

## Local patches applied to the proxy

The setup script patches three files in `free-llm-proxy-router` before building:

| Patch | File | What it fixes |
|---|---|---|
| Silent exhaustion | `pkg/proxy/server.go` | Returns empty 200 instead of 503 — no error message in Telegram |
| Per-model cooldowns | `pkg/proxy/fallback.go` | 429 on one model no longer blocks all models from that provider |
| Multi-key rotation | `pkg/proxy/fallback.go` + `pkg/ratelimit/tracker.go` + `pkg/config/provider.go` | Rotates API key on 429, discovers `_2`/`_3` variants automatically |

All patches are idempotent (re-run safe) and include markers so they survive `git pull`.

---

## ask-precise

A shell command installed at `/usr/local/bin/ask-precise` for delegating quick subtasks:

```bash
ask-precise "what does this bash one-liner do: awk '{print $1}' /var/log/syslog | sort | uniq -c"
ask-precise "summarise this in one sentence: $(cat some-diff.txt)"
ask-precise "what is the capital of France? one word."
```

Uses `groq/llama-3.3-70b-versatile` with `temperature=0.1` and `max_tokens=400` — deterministic, fast, token-efficient. Calls the local proxy directly (no MCP server, no extra process).

---

## Architecture

```
You (Telegram / phone)
        │
        ▼
   picoclaw agent
   (runs on Pi Zero 2W)
        │
        ▼  http://127.0.0.1:8080/v1
   free-llm-proxy-router
   (OpenAI-compatible, local)
        │
        ├── Groq          (GROQ_API_KEY, _2, _3…)
        ├── Gemini        (GEMINI_API_KEY, _2…)
        ├── GitHub Models (GITHUB_TOKEN, _2…)
        ├── OpenRouter    (OPENROUTER_API_KEY)
        └── …more
```

The proxy handles all fallback, rate-limit recovery, and key rotation. picoclaw only sees a single OpenAI-compatible endpoint and never knows a fallback happened.

---

## Related

- [openclaw-pi-setup](https://github.com/kaiser-data/openclaw-pi-setup) — Pi 4 setup with OpenClaw and a Claude API key (paid)
- [free-llm-proxy-router](https://github.com/kaiser-data/free-llm-proxy-router) — the proxy this script configures
- [picoclaw](https://github.com/badass-courses/picoclaw) — the agent framework

---

## Support

If this saved you money on cloud bills, [buy me a coffee](https://buymeacoffee.com/kaiserdata).
