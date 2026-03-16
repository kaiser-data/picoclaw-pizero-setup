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

## Multiple keys (key rotation)

The proxy supports numbered key variants and rotates across them automatically on 429:

```bash
# ~/.free-llm-proxy-router/.env
GROQ_API_KEY=gsk_...
GROQ_API_KEY_2=gsk_...   # picked up automatically
GROQ_API_KEY_3=gsk_...
GEMINI_API_KEY_2=AIza...  # same pattern for any provider
```

On 429, the proxy rotates to the next slot. Each slot has its own cooldown — one exhausted key doesn't block the others.

**Legitimate use:** different keys from different people sharing the same setup — household members or teammates who each signed up independently with their own account.

> **Warning:** Creating multiple accounts with the same provider specifically to bypass rate limits most likely violates that provider's Terms of Service. Groq, Google, GitHub, and OpenRouter all prohibit this. Doing so is entirely at your own risk and may result in all associated accounts being permanently banned. This project takes no responsibility for ToS violations or account loss.

---

## Local patches applied to the proxy

Patches live in [`patches/`](patches/) as standard unified diffs applied with `git apply` after cloning — no string manipulation, no code embedded in the setup script. Each patch is reviewable as a plain diff.

| Patch file | What it fixes |
|---|---|
| `01-silent-exhaustion.patch` | `server.go` — returns empty 200 instead of 503 so Telegram never shows an error |
| `02-per-model-cooldowns-and-key-rotation.patch` | `fallback.go` — 429 cools one model, not the whole provider; rotates key on 429 |
| `03-multi-key-tracker.patch` | `tracker.go` + `provider.go` — `RotateKey` / `AllKeys` / `NumKeys` |

**Re-run safe:** `git apply --check --reverse` detects already-applied patches and skips them.
**Upstream-change safe:** if a patch no longer applies cleanly, setup warns and continues — the build still succeeds, the feature is just missing until the patch is refreshed.

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
