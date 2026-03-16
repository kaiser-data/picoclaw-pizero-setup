#!/usr/bin/env bash
# =============================================================================
# setup-picoclaw-proxy.sh
# Raspberry Pi OS Bookworm (arm64) — Idempotent installer
# Chain: picoclaw -> http://127.0.0.1:8080/v1 -> free-llm-proxy-router -> cloud
# Repo:  https://github.com/kaiser-data/free-llm-proxy-router
# =============================================================================
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/kaiser-data/free-llm-proxy-router"
REPO_DIR="/opt/free-llm-proxy-router"
PROXY_CONFIG_DIR="${HOME}/.free-llm-proxy-router"
PICOCLAW_CONFIG_DIR="${HOME}/.picoclaw"
BIN_DIR="/usr/local/bin"
PROXY_PORT=8080
SERVICE_USER="${USER:-pi}"

# Go 1.23 is required (go.mod says `go 1.23`).
# Bookworm's apt ships Go 1.19 which is too old; we install from go.dev if needed.
GO_REQUIRED_MAJOR=1
GO_REQUIRED_MINOR=23
GO_INSTALL_VERSION="1.23.8"   # latest 1.23 patch — bump if needed
GO_INSTALL_DIR="/usr/local/go"
GO_ARCH="arm64"               # Pi Zero 2 W (Cortex-A53, 64-bit OS required)

# Model for picoclaw -> proxy.
# The proxy uses the model field to select a routing strategy or agent profile.
# Built-in strategies: adaptive, performance, speed, volume, balanced,
#                      small, tiny, coding, long_context, similar, parallel,
#                      reliable, economical
# Agent profiles (from config.yaml agents:): reliable, coding, summariser, long-context
#
# 'adaptive' — dynamically picks the fastest healthy free provider.
# Recommended for Pi Zero 2 W: minimises first-token latency.
# Alternative: 'reliable' (pinned to groq/llama-3.3-70b-versatile via agent profile).
PICOCLAW_MODEL="${PICOCLAW_MODEL:-reliable}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\n[%s] ===  %s\n' "$(date '+%H:%M:%S')" "$*"; }
info() { printf '  [info]  %s\n' "$*"; }
warn() { printf '  [warn]  %s\n' "$*" >&2; }
fail() { printf '  [fail]  %s\n' "$*" >&2; exit 1; }

go_version_ok() {
    local ver
    ver=$(go version 2>/dev/null | grep -oP '\d+\.\d+' | head -1) || return 1
    local maj min
    maj=$(echo "$ver" | cut -d. -f1)
    min=$(echo "$ver" | cut -d. -f2)
    [[ "$maj" -gt "$GO_REQUIRED_MAJOR" ]] \
        || { [[ "$maj" -eq "$GO_REQUIRED_MAJOR" ]] && [[ "$min" -ge "$GO_REQUIRED_MINOR" ]]; }
}

# ── Step 1: Prerequisites ──────────────────────────────────────────────────────
log "Step 1: Prerequisites"

command -v sudo &>/dev/null || fail "sudo required"
command -v systemctl &>/dev/null || fail "systemctl not found — requires systemd"

APT_NEEDED=()
for pkg in curl git jq make; do
    command -v "$pkg" &>/dev/null || APT_NEEDED+=("$pkg")
done
if [[ ${#APT_NEEDED[@]} -gt 0 ]]; then
    info "apt-get install: ${APT_NEEDED[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${APT_NEEDED[@]}"
fi

# ── Step 2: Go ≥ 1.23 ─────────────────────────────────────────────────────────
log "Step 2: Go >= ${GO_REQUIRED_MAJOR}.${GO_REQUIRED_MINOR}"

if go_version_ok; then
    info "Go ok: $(go version)"
else
    warn "Go < ${GO_REQUIRED_MAJOR}.${GO_REQUIRED_MINOR} or missing — installing ${GO_INSTALL_VERSION} from go.dev"

    GO_TARBALL="go${GO_INSTALL_VERSION}.linux-${GO_ARCH}.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TARBALL}"
    TMP_TAR="/tmp/${GO_TARBALL}"

    if [[ ! -f "$TMP_TAR" ]]; then
        info "Downloading $GO_URL ..."
        curl -fL --progress-bar "$GO_URL" -o "$TMP_TAR"
    else
        info "Using cached $TMP_TAR"
    fi

    sudo rm -rf "$GO_INSTALL_DIR"
    sudo tar -C /usr/local -xzf "$TMP_TAR"
    rm -f "$TMP_TAR"

    # Persist in PATH for this script and future shells
    export PATH="/usr/local/go/bin:${PATH}"

    GO_PROFILE="/etc/profile.d/go.sh"
    echo 'export PATH="/usr/local/go/bin:$PATH"' | sudo tee "$GO_PROFILE" > /dev/null
    info "PATH updated: /etc/profile.d/go.sh"

    go_version_ok || fail "Go install failed — check architecture and tarball"
    info "Installed: $(go version)"
fi

export PATH="/usr/local/go/bin:${PATH}"

# ── Step 3: Clone / update repo ───────────────────────────────────────────────
log "Step 3: Clone/update repo"

if [[ -d "${REPO_DIR}/.git" ]]; then
    info "Updating $REPO_DIR ..."
    sudo git -C "$REPO_DIR" pull --ff-only \
        || warn "git pull failed — continuing with existing code"
else
    info "Cloning $REPO_URL -> $REPO_DIR"
    sudo git clone "$REPO_URL" "$REPO_DIR"
fi

sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "$REPO_DIR"

# ── Step 4: Build ─────────────────────────────────────────────────────────────
log "Step 4: Build binaries"

cd "$REPO_DIR"

# Cross-compilation not needed: we're running ON the Pi.
# GOARCH defaults to the host arch (arm64). Verify:
info "GOARCH=$(go env GOARCH)  GOOS=$(go env GOOS)"
[[ "$(go env GOARCH)" == "arm64" ]] \
    || warn "GOARCH is not arm64 — building for host arch anyway"

info "go mod download ..."
go mod download

# Build all three binaries (matches Makefile targets)
mkdir -p bin
info "Building free-llm-proxy ..."
go build -ldflags="-s -w" -o bin/free-llm-proxy ./cmd/proxy

info "Building free-llm-scan ..."
go build -ldflags="-s -w" -o bin/free-llm-scan ./cmd/scan

info "Building free-llm-bench ..."
go build -ldflags="-s -w" -o bin/free-llm-bench ./cmd/bench || \
    warn "free-llm-bench build failed (non-fatal)"

# Install to system bin
sudo install -m 755 bin/free-llm-proxy "${BIN_DIR}/free-llm-proxy"
sudo install -m 755 bin/free-llm-scan  "${BIN_DIR}/free-llm-scan"
[[ -f bin/free-llm-bench ]] && sudo install -m 755 bin/free-llm-bench "${BIN_DIR}/free-llm-bench"

info "Installed:"
ls -lh "${BIN_DIR}/free-llm-"{proxy,scan} 2>/dev/null | awk '{print "    "$NF, $5}'

cd - > /dev/null

# ── Step 5: picoclaw binary ────────────────────────────────────────────────────
log "Step 5: picoclaw"

if command -v picoclaw &>/dev/null; then
    info "picoclaw: $(command -v picoclaw)"
elif [[ -x /usr/local/bin/picoclaw ]]; then
    info "picoclaw: /usr/local/bin/picoclaw"
else
    warn "picoclaw not found in PATH or /usr/local/bin."
    warn "Install picoclaw, then rerun this script."
    warn "Proxy and configs will be configured regardless."
fi

# ── Step 6: Config dir + .env ─────────────────────────────────────────────────
log "Step 6: ${PROXY_CONFIG_DIR} and .env"

mkdir -p "$PROXY_CONFIG_DIR"
ENV_FILE="${PROXY_CONFIG_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    cp "${REPO_DIR}/.env.example" "$ENV_FILE"
    info "Created $ENV_FILE from .env.example"
    printf '\n'
    warn "══════════════════════════════════════════════════════════"
    warn " ACTION REQUIRED: fill in at least one API key"
    warn "   nano ${ENV_FILE}"
    warn ""
    warn " Fastest free tier for Pi Zero 2 W:"
    warn "   GROQ_API_KEY   — https://console.groq.com/keys (daily reset)"
    warn "   GEMINI_API_KEY — https://aistudio.google.com/app/apikey"
    warn "   GITHUB_TOKEN   — any GitHub PAT works (free)"
    warn ""
    warn " To double/triple a provider's free quota, add numbered variants:"
    warn "   GROQ_API_KEY_2=gsk_...   (second Groq account)"
    warn "   GROQ_API_KEY_3=gsk_...   (third Groq account)"
    warn "   GEMINI_API_KEY_2=AIza... etc."
    warn " On 429, the proxy automatically rotates to the next key slot."
    warn "══════════════════════════════════════════════════════════"
    printf '\n'
else
    info "$ENV_FILE already exists"
fi

# ── Step 7: config.yaml ───────────────────────────────────────────────────────
log "Step 7: config.yaml"

CONFIG_FILE="${PROXY_CONFIG_DIR}/config.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
    # Start from the repo's example config (maintained upstream)
    cp "${REPO_DIR}/configs/config.example.yaml" "$CONFIG_FILE"
    info "Created $CONFIG_FILE from config.example.yaml"

    # Patch port and ensure localhost-only binding.
    # The example already sets port 8080, auth_token: "", strategy: adaptive —
    # all correct for local use. Only override if PROXY_PORT differs.
    if [[ "$PROXY_PORT" -ne 8080 ]]; then
        # Replace port value (simple sed — YAML is flat enough here)
        sed -i "s/port: 8080/port: ${PROXY_PORT}/" "$CONFIG_FILE"
        info "Set port: ${PROXY_PORT}"
    fi
else
    info "$CONFIG_FILE already exists — skipping"
fi

# ── Step 8: Provider scan ──────────────────────────────────────────────────────
log "Step 8: Provider scan"

# Source .env to check for keys (set +u to tolerate unbound vars in .env)
set +u
# shellcheck disable=SC1090
source "$ENV_FILE" 2>/dev/null || true
set -u

KEYS_PRESENT=false
for k in GROQ_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY GITHUB_TOKEN \
          CEREBRAS_API_KEY HF_API_KEY MISTRAL_API_KEY NVIDIA_API_KEY \
          COHERE_API_KEY; do
    val="${!k:-}"
    if [[ -n "$val" ]]; then
        KEYS_PRESENT=true
        info "Key found: $k"
    fi
done

if $KEYS_PRESENT; then
    info "Running: free-llm-scan update -c $CONFIG_FILE"
    # Run from REPO_DIR so relative paths (configs/families.yaml etc.) resolve
    (cd "$REPO_DIR" && free-llm-scan update -c "$CONFIG_FILE") \
        || warn "Scan returned non-zero — check output. Proxy will warn of empty catalog on start."
else
    warn "No API keys found in $ENV_FILE — skipping scan."
    warn "After adding keys, run:"
    warn "  cd $REPO_DIR && free-llm-scan update -c $CONFIG_FILE"
fi

# ── Step 9: Systemd — free-llm-proxy.service ──────────────────────────────────
log "Step 9: free-llm-proxy.service"

PROXY_SERVICE="/etc/systemd/system/free-llm-proxy.service"

# WorkingDirectory MUST be REPO_DIR — the binary reads configs/families.yaml
# and other YAML files with paths relative to CWD.
sudo tee "$PROXY_SERVICE" > /dev/null << SVCEOF
[Unit]
Description=Free LLM Proxy Router (OpenAI-compatible, free providers)
Documentation=${REPO_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}

# Binary reads configs/families.yaml etc. relative to CWD — must stay here.
WorkingDirectory=${REPO_DIR}

# Inject API keys from .env
EnvironmentFile=${ENV_FILE}

# Flags: -c config path, -p port override, -s strategy override
ExecStart=${BIN_DIR}/free-llm-proxy \
    -c ${CONFIG_FILE} \
    -p ${PROXY_PORT}

Restart=on-failure
RestartSec=5
StartLimitIntervalSec=120
StartLimitBurst=5

StandardOutput=journal
StandardError=journal
SyslogIdentifier=free-llm-proxy

# Resource caps for Pi Zero 2 W (512 MB RAM, 4× Cortex-A53 @ 1 GHz)
MemoryMax=200M
CPUQuota=75%

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable free-llm-proxy.service
info "Enabled: free-llm-proxy.service"

if $KEYS_PRESENT; then
    if sudo systemctl is-active --quiet free-llm-proxy.service 2>/dev/null; then
        info "Restarting ..."
        sudo systemctl restart free-llm-proxy.service
    else
        info "Starting ..."
        sudo systemctl start free-llm-proxy.service
    fi
else
    warn "Not starting — no API keys. After adding keys:"
    warn "  sudo systemctl start free-llm-proxy.service"
fi

# ── Step 10: picoclaw config ───────────────────────────────────────────────────
log "Step 10: picoclaw config"

mkdir -p "$PICOCLAW_CONFIG_DIR"
PICOCLAW_CONFIG="${PICOCLAW_CONFIG_DIR}/config.json"

# Model field notes:
#   The proxy interprets the model string as either:
#     (a) A strategy name: adaptive, reliable, speed, coding, long_context, ...
#     (b) An agent profile (from config.yaml agents:): reliable, coding, summariser
#     (c) A provider/model pair: groq/llama-3.3-70b-versatile, gemini/gemini-2.0-flash-lite
#
#   Using 'adaptive' as the model name:
#   — triggers the adaptive routing strategy (default in config.yaml)
#   — picks fastest healthy provider dynamically
#   — ideal for Pi Zero 2 W where first-token latency matters
#   — no single-provider dependency
#
#   If picoclaw strips or rewrites the model name before sending,
#   check /v1/models output and use a literal model ID instead.
#
#   Run after start: curl http://127.0.0.1:8080/v1/models | jq '.data[].id'

if [[ ! -f "$PICOCLAW_CONFIG" ]]; then
    cat > "$PICOCLAW_CONFIG" << JSONEOF
{
  "agents": {
    "defaults": {
      "workspace": "~/.picoclaw/workspace",
      "restrict_to_workspace": true,
      "model_name": "${PICOCLAW_MODEL}",
      "max_tokens": 4096,
      "temperature": 0.7,
      "max_tool_iterations": 6,
      "summarize_message_threshold": 20,
      "summarize_token_percent": 75
    }
  },
  "model_list": [
    {
      "model_name": "${PICOCLAW_MODEL}",
      "model": "${PICOCLAW_MODEL}",
      "api_key": "not-needed",
      "api_base": "http://127.0.0.1:${PROXY_PORT}/v1"
    }
  ],
  "channels": {
    "telegram": {
      "enabled": false,
      "token": "YOUR_BOT_TOKEN",
      "allow_from": ["YOUR_TELEGRAM_USER_ID"]
    }
  },
  "heartbeat": {
    "enabled": false
  },
  "tools": {
    "exec": { "enabled": true, "enable_deny_patterns": true },
    "web": { "enabled": true, "duckduckgo": { "enabled": true, "max_results": 5 } },
    "read_file": { "enabled": true },
    "write_file": { "enabled": true },
    "list_dir": { "enabled": true }
  }
}
JSONEOF
    chmod 600 "$PICOCLAW_CONFIG"
    info "Created $PICOCLAW_CONFIG  (model: ${PICOCLAW_MODEL})"
else
    info "$PICOCLAW_CONFIG exists — patching api_base in model_list"
    tmp=$(mktemp)
    jq --arg base "http://127.0.0.1:${PROXY_PORT}/v1" \
       '(.model_list[]? | select(.model_name != null)) .api_base = $base
        | .api_base = $base' \
       "$PICOCLAW_CONFIG" > "$tmp" && mv "$tmp" "$PICOCLAW_CONFIG"
    chmod 600 "$PICOCLAW_CONFIG"
    info "Patched api_base -> http://127.0.0.1:${PROXY_PORT}/v1"
fi

# ── Step 11: picoclaw-agent.service (optional, disabled) ──────────────────────
log "Step 11: picoclaw-agent.service (disabled by default)"

AGENT_BIN="/usr/local/bin/picoclaw"
command -v picoclaw &>/dev/null && AGENT_BIN="$(command -v picoclaw)"

AGENT_SERVICE="/etc/systemd/system/picoclaw-agent.service"

sudo tee "$AGENT_SERVICE" > /dev/null << AGENTSVCEOF
[Unit]
Description=Picoclaw Agent (persistent background session)
After=free-llm-proxy.service network.target
Requires=free-llm-proxy.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${HOME}

ExecStart=${AGENT_BIN} gateway

Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal
SyslogIdentifier=picoclaw-agent

MemoryMax=100M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
AGENTSVCEOF

sudo systemctl daemon-reload
# NOT enabled — user opt-in only
info "Installed $AGENT_SERVICE (NOT enabled)"
info "To enable: sudo systemctl enable --now picoclaw-agent.service"

# ── Step 12: Verification ──────────────────────────────────────────────────────
log "Step 12: Verification"

VERIFY_OK=true

if $KEYS_PRESENT && sudo systemctl is-active --quiet free-llm-proxy.service 2>/dev/null; then
    sleep 3  # let service bind port

    info "── /health ──"
    if curl -sf --max-time 5 "http://127.0.0.1:${PROXY_PORT}/health"; then
        echo ""
        info "✓ health ok"
    else
        warn "✗ /health failed (may still be starting)"
        VERIFY_OK=false
    fi

    info "── /v1/models ──"
    MODELS=$(curl -sf --max-time 5 "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null || echo "")
    if [[ -n "$MODELS" ]]; then
        echo "$MODELS" | jq -r '.data[]?.id // empty' 2>/dev/null | head -10 | sed 's/^/    /'
        info "✓ /v1/models ok"
    else
        warn "✗ /v1/models failed or empty catalog — run free-llm-scan update"
        VERIFY_OK=false
    fi
else
    warn "Service not running — skipping live checks"
fi

info "── Systemd status ──"
for svc in free-llm-proxy picoclaw-agent; do
    enabled=$(systemctl is-enabled "${svc}.service" 2>/dev/null || echo "not-found")
    active=$(systemctl is-active "${svc}.service" 2>/dev/null || echo "inactive")
    printf '    %-28s  enabled=%-12s active=%s\n' "${svc}.service" "$enabled" "$active"
done

info "── ask-precise smoke test ──"
if command -v ask-precise &>/dev/null && \
   sudo systemctl is-active --quiet free-llm-proxy.service 2>/dev/null && \
   $KEYS_PRESENT; then
    RESULT=$(ask-precise "What is 2+2? One word." 2>/dev/null || echo "")
    if [[ -n "$RESULT" ]]; then
        info "✓ ask-precise: $RESULT"
    else
        warn "✗ ask-precise returned empty — check proxy logs"
    fi
fi

# ── Step 13: precise agent profile ────────────────────────────────────────────
log "Step 13: 'precise' agent profile in $CONFIG_FILE"

# precise: is now in configs/config.example.yaml upstream — new installs get it
# automatically. This step just verifies it landed (or patches legacy configs).
if grep -q "precise:" "$CONFIG_FILE"; then
    info "'precise' profile present in $CONFIG_FILE"
else
    warn "'precise' profile missing — config.yaml may predate upstream fix"
    warn "Re-run setup to regenerate config, or add manually under proxy.agents:"
    warn "    precise:"
    warn "      model: \"groq/llama-3.3-70b-versatile\""
    warn "      overrides:"
    warn "        temperature: 0.1"
    warn "        max_tokens: 400"
fi

# ── Step 14: ask-precise wrapper script ───────────────────────────────────────
log "Step 14: ask-precise wrapper"

ASK_PRECISE_SCRIPT="/usr/local/bin/ask-precise"
if [[ ! -f "$ASK_PRECISE_SCRIPT" ]]; then
    sudo tee "$ASK_PRECISE_SCRIPT" > /dev/null << 'SCRIPTEOF'
#!/usr/bin/env bash
set -euo pipefail
# ask-precise "your question"
# Delegates to proxy's 'precise' agent profile.
# Profile: groq/llama-3.3-70b-versatile, temp=0.1, max_tokens=400
# No MCP server needed — direct curl to the local proxy.

PROXY_BASE="http://localhost:8080/v1"
SYSTEM="Respond in under 100 words. Structured, no preamble. Lead with the answer."

[[ $# -gt 0 ]] || { echo "Usage: ask-precise \"question\"" >&2; exit 1; }

jq -n --arg s "$SYSTEM" --arg u "$*" \
    '{model:"precise",stream:false,messages:[{role:"system",content:$s},{role:"user",content:$u}]}' \
| curl -sf -X POST "${PROXY_BASE}/chat/completions" \
    -H "Content-Type: application/json" \
    -d @- \
| jq -r '.choices[0].message.content'
SCRIPTEOF
    sudo chmod +x "$ASK_PRECISE_SCRIPT"
    info "Installed $ASK_PRECISE_SCRIPT"
else
    info "$ASK_PRECISE_SCRIPT already exists — skipping"
fi

# ── Next steps ────────────────────────────────────────────────────────────────
cat << 'NEXTSTEPS'

╔══════════════════════════════════════════════════════════════════════════════╗
║                              NEXT STEPS                                    ║
╚══════════════════════════════════════════════════════════════════════════════╝

 ① ADD API KEYS  (add at least one — daily-resetting free tiers)
   nano ~/.free-llm-proxy-router/.env

   Fastest for Pi Zero 2 W (lowest latency, recommended first):
     GROQ_API_KEY=gsk_...      https://console.groq.com/keys
     GEMINI_API_KEY=AIza...    https://aistudio.google.com/app/apikey
     GITHUB_TOKEN=ghp_...      any GitHub PAT, free with any account

 ② SCAN PROVIDERS  (builds ~/.free-llm-proxy-router/catalog.json)
   cd /opt/free-llm-proxy-router
   free-llm-scan update -c ~/.free-llm-proxy-router/config.yaml

 ③ (RE)START PROXY
   sudo systemctl start free-llm-proxy.service
   sudo systemctl status free-llm-proxy.service
   journalctl -u free-llm-proxy -f          # live logs

 ④ VERIFY
   curl http://127.0.0.1:8080/health
   curl http://127.0.0.1:8080/v1/models | jq '.data[].id'

 ⑤ TEST PICOCLAW
   picoclaw "Hello from Raspberry Pi Zero 2 W"

   ── Model / strategy options (set in ~/.picoclaw/config.json) ─────────────
   "model": "adaptive"          default — fastest healthy provider (recommended)
   "model": "reliable"          agent profile — pinned to groq/llama-3.3-70b-versatile
   "model": "coding"            agent profile — coding strategy, temp 0.2
   "model": "speed"             minimises TTFT, small max_tokens cap
   "model": "groq/llama-3.3-70b-versatile"   pin to specific provider+model

   If picoclaw rejects the model name, check what /v1/models returns and use
   a literal model ID from that list.

 ⑥ (OPTIONAL) Auto-refresh catalog weekly via cron
   cp /opt/free-llm-proxy-router/scripts/cron-refresh.sh ~/bin/
   crontab -e
   # Add: 0 4 * * 1 ~/bin/cron-refresh.sh >> ~/.free-llm-proxy-router/refresh.log 2>&1

 ⑦ (OPTIONAL) Enable picoclaw-agent persistent daemon
   # Verify subcommand: picoclaw --help
   sudo systemctl enable --now picoclaw-agent.service

 ── multiple keys / key rotation ──────────────────────────────────────────────
   Add numbered variants to ~/.free-llm-proxy-router/.env:
     GROQ_API_KEY_2=gsk_...
     GROQ_API_KEY_3=gsk_...
     GEMINI_API_KEY_2=AIza...

   On 429 the proxy rotates to the next key slot automatically. Each slot
   gets its own cooldown so other slots stay live.

   Legitimate use: keys from different people sharing the same setup
   (household, team) where each person signed up independently.

   WARNING: Creating multiple accounts to bypass rate limits likely violates
   provider ToS (Groq, Google, GitHub, OpenRouter all prohibit this) and
   may result in permanent bans. Your risk, your responsibility.

 ── precise tool ──────────────────────────────────────────────────────────────
   ask-precise "summarise this in one sentence: <text>"
   ask-precise "what does this bash one-liner do: <cmd>"

   In picoclaw sessions, use ask-precise for subtasks to save Claude tokens:
     - summarising diffs / log output
     - quick factual lookups
     - structured extraction from text
     - code snippet explanation

   Model: groq/llama-3.3-70b-versatile  temp=0.1  max_tokens=400
   Profile name in proxy: "precise"

 ── Rollback: see bottom of script comments ──────────────────────────────────

NEXTSTEPS

$VERIFY_OK && log "Setup complete ✓" || log "Setup complete with warnings — see above"
