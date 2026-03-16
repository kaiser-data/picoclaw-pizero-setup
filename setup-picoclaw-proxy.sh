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
PICOCLAW_MODEL="${PICOCLAW_MODEL:-adaptive}"

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

# ── Step 3b: Local patches ─────────────────────────────────────────────────────
log "Step 3b: Local patches to proxy source"

# Patch: silent exhaustion — return empty 200 completion instead of 503 error.
#
# Without this patch: when all providers fail, the proxy returns:
#   HTTP 503  {"error":"all providers exhausted"}
# picoclaw forwards this to Telegram as a visible error message.
#
# With this patch: return a valid OpenAI-format 200 with empty content.
# picoclaw sees a successful (if empty) response — no error shown in chat.
# The chain already logs to journald at every failed attempt, so observability
# is preserved; only the user-visible disruption is eliminated.

SERVER_FILE="${REPO_DIR}/pkg/proxy/server.go"
PROVIDER_FILE="${REPO_DIR}/pkg/config/provider.go"
TRACKER_FILE="${REPO_DIR}/pkg/ratelimit/tracker.go"
FALLBACK_FILE="${REPO_DIR}/pkg/proxy/fallback.go"
PATCH_MARKER="// patched: silent exhaustion"

# ── Patch A: per-model cooldowns + key rotation in fallback.go ────────────────
# Problem: one 429 on groq/llama-3.3 marks the entire "groq" provider as
# cooling down, blocking all other Groq models for the duration.
# Fix 1: key 429 cooldowns on "providerID/modelID" instead of "providerID",
#         so other models from the same provider are still tried.
# Fix 2: split cooldown check — provider-level blocks the whole provider,
#         model-level only skips that one model (other models still attempted).
# Fix 3: rotate to next API key on 429 before setting cooldown,
#         so the next attempt uses a fresh key (GROQ_API_KEY_2, _3, etc.).

PATCH_MARKER_A="// patched: per-model cooldown"

if ! grep -q "$PATCH_MARKER_A" "$FALLBACK_FILE"; then
    python3 - "$FALLBACK_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
errors = []

# Fix 1: split cooldown check — provider-level vs model-level
old1 = (
    '\t\t// Skip any provider currently on rate-limit cooldown.\n'
    '\t\tif fc.RateLimiter.IsOnCooldown(r.ProviderID) {\n'
    '\t\t\tlog.Printf("fallback: %s on cooldown — skipping", r.ProviderID)\n'
    '\t\t\tfailedProviders[r.ProviderID] = true\n'
    '\t\t\tcontinue\n'
    '\t\t}'
)
new1 = (
    '\t\t// patched: per-model cooldown\n'
    '\t\t// Provider-level cooldown (auth errors) blocks the whole provider.\n'
    '\t\tif fc.RateLimiter.IsOnCooldown(r.ProviderID) {\n'
    '\t\t\tlog.Printf("fallback: %s on cooldown — skipping provider", r.ProviderID)\n'
    '\t\t\tfailedProviders[r.ProviderID] = true\n'
    '\t\t\tcontinue\n'
    '\t\t}\n'
    '\t\t// Model-level cooldown (429) only skips this model; other models still tried.\n'
    '\t\tif fc.RateLimiter.IsOnCooldown(r.ProviderID + "/" + r.ModelID) {\n'
    '\t\t\tlog.Printf("fallback: %s/%s rate-limited — skipping model", r.ProviderID, r.ModelID)\n'
    '\t\t\tcontinue\n'
    '\t\t}'
)
if old1 in content:
    content = content.replace(old1, new1, 1)
else:
    errors.append("cooldown-check block not found")

# Fix 2: 429 sets per-model cooldown and rotates key
old2 = (
    '\t\t\t\tcase 429:\n'
    '\t\t\t\t\tfc.Catalog.MarkNeedsReverification(r.ProviderID, r.ModelID)\n'
    '\t\t\t\t\tinfo := ratelimit.ExtractRateLimitInfo(r.ProviderID, resp.Header, resp.Body)\n'
    '\t\t\t\t\twaitDur := info.WaitDuration()\n'
    '\t\t\t\t\tuntil := time.Now().Add(waitDur)\n'
    '\t\t\t\t\tfc.RateLimiter.SetCooldown(r.ProviderID, until)\n'
    '\t\t\t\t\tlog.Printf("fallback: %s rate limited — cooldown until %s", r.ProviderID, until.Format("15:04:05"))'
)
new2 = (
    '\t\t\t\tcase 429:\n'
    '\t\t\t\t\tfc.Catalog.MarkNeedsReverification(r.ProviderID, r.ModelID)\n'
    '\t\t\t\t\tinfo := ratelimit.ExtractRateLimitInfo(r.ProviderID, resp.Header, resp.Body)\n'
    '\t\t\t\t\twaitDur := info.WaitDuration()\n'
    '\t\t\t\t\tuntil := time.Now().Add(waitDur)\n'
    '\t\t\t\t\t// Per-model cooldown: other models from this provider still available.\n'
    '\t\t\t\t\tfc.RateLimiter.SetCooldown(r.ProviderID+"/"+r.ModelID, until)\n'
    '\t\t\t\t\t// Rotate API key so next attempt uses a fresh quota slot.\n'
    '\t\t\t\t\tif providerCfg != nil && providerCfg.NumKeys() > 1 {\n'
    '\t\t\t\t\t\tnewIdx := fc.RateLimiter.RotateKey(r.ProviderID, providerCfg.NumKeys())\n'
    '\t\t\t\t\t\tlog.Printf("fallback: %s/%s rate limited — rotated to key slot %d", r.ProviderID, r.ModelID, newIdx+1)\n'
    '\t\t\t\t\t} else {\n'
    '\t\t\t\t\t\tlog.Printf("fallback: %s/%s rate limited — cooldown until %s", r.ProviderID, r.ModelID, until.Format("15:04:05"))\n'
    '\t\t\t\t\t}'
)
if old2 in content:
    content = content.replace(old2, new2, 1)
else:
    errors.append("429-case block not found")

# Fix 3: inject active key before callProvider
old3 = (
    '\t\tbody := fc.buildBody(r.ProviderID, req.Raw, r.ModelID)\n'
    '\t\tresp, err := fc.callProvider(ctx, *providerCfg, body)'
)
new3 = (
    '\t\tbody := fc.buildBody(r.ProviderID, req.Raw, r.ModelID)\n'
    '\t\t// Apply active key slot for providers with multiple API keys.\n'
    '\t\tcallCfg := *providerCfg\n'
    '\t\tif keys := providerCfg.AllKeys(); len(keys) > 1 {\n'
    '\t\t\tkeyIdx := fc.RateLimiter.CurrentKeyIndex(r.ProviderID)\n'
    '\t\t\tif keyIdx < len(keys) {\n'
    '\t\t\t\tcallCfg.APIKey = keys[keyIdx]\n'
    '\t\t\t\tcallCfg.APIKeyEnv = "" // use literal key, skip env lookup\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t\tresp, err := fc.callProvider(ctx, callCfg, body)'
)
if old3 in content:
    content = content.replace(old3, new3, 1)
else:
    errors.append("callProvider call site not found")

if errors:
    print("patch-A errors: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(content)
print("patched fallback.go")
PYEOF
    if [[ $? -eq 0 ]]; then
        info "Patched $FALLBACK_FILE — per-model cooldowns + key rotation"
    else
        warn "Patch A failed — fallback.go may have changed upstream. Continuing with unpatched source."
    fi
else
    info "fallback.go already has per-model cooldown patch — skipping"
fi

# ── Patch B: AllKeys / NumKeys on ProviderConfig (provider.go) ────────────────
# Adds auto-discovery of numbered API key variants:
#   GROQ_API_KEY   → slot 0 (existing)
#   GROQ_API_KEY_2 → slot 1  (just add to .env)
#   GROQ_API_KEY_3 → slot 2  ...
# No config.yaml changes needed — just add numbered vars to .env.

PATCH_MARKER_B="// patched: AllKeys multi-key"

if ! grep -q "$PATCH_MARKER_B" "$PROVIDER_FILE"; then
    python3 - "$PROVIDER_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()

# Add "fmt" import — provider.go currently has no imports
if 'import ' not in content:
    content = content.replace(
        'package config\n',
        'package config\n\nimport "fmt"\n',
        1
    )

# Append new methods at end of file
addition = '''
// patched: AllKeys multi-key
// AllKeys returns all API keys available for this provider in order.
// It auto-discovers numbered variants of the base env var:
//   GROQ_API_KEY, GROQ_API_KEY_2, GROQ_API_KEY_3, ... GROQ_API_KEY_9
// Add GROQ_API_KEY_2=gsk_... to .env to double the free-tier quota.
// No config.yaml changes needed.
func (p *ProviderConfig) AllKeys() []string {
\tvar keys []string
\tif p.APIKey != "" {
\t\tkeys = append(keys, p.APIKey)
\t}
\tif p.APIKeyEnv != "" {
\t\tif v := lookupEnv(p.APIKeyEnv); v != "" {
\t\t\tkeys = append(keys, v)
\t\t}
\t\tfor i := 2; i <= 9; i++ {
\t\t\tif v := lookupEnv(fmt.Sprintf("%s_%d", p.APIKeyEnv, i)); v != "" {
\t\t\t\tkeys = append(keys, v)
\t\t\t}
\t\t}
\t}
\treturn keys
}

// NumKeys returns the number of API keys available for this provider.
func (p *ProviderConfig) NumKeys() int {
\treturn len(p.AllKeys())
}
'''

if 'AllKeys' not in content:
    content = content.rstrip() + '\n' + addition
    open(path, 'w').write(content)
    print("patched provider.go")
else:
    print("AllKeys already present — skipping")
PYEOF
    if [[ $? -eq 0 ]]; then
        info "Patched $PROVIDER_FILE — AllKeys/NumKeys multi-key support"
    else
        warn "Patch B failed — provider.go may have changed upstream. Continuing."
    fi
else
    info "provider.go already has AllKeys patch — skipping"
fi

# ── Patch C: RotateKey / CurrentKeyIndex on GlobalTracker (tracker.go) ────────
# Adds per-provider key rotation state and methods used by fallback.go.

PATCH_MARKER_C="// patched: key rotation"

if ! grep -q "$PATCH_MARKER_C" "$TRACKER_FILE"; then
    python3 - "$TRACKER_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
errors = []

# Add keyIndices field to GlobalTracker struct
old1 = (
    '// GlobalTracker holds per-provider trackers, keyed by provider ID.\n'
    'type GlobalTracker struct {\n'
    '\tmu        sync.RWMutex\n'
    '\ttrackers  map[string]*ProviderTracker\n'
    '\tcooldowns map[string]time.Time // provider_id → earliest time to retry\n'
    '}'
)
new1 = (
    '// GlobalTracker holds per-provider trackers, keyed by provider ID.\n'
    'type GlobalTracker struct {\n'
    '\tmu         sync.RWMutex\n'
    '\ttrackers   map[string]*ProviderTracker\n'
    '\tcooldowns  map[string]time.Time // provider_id → earliest time to retry\n'
    '\tkeyIndices map[string]int       // patched: key rotation — provider_id → active key index\n'
    '}'
)
if old1 in content:
    content = content.replace(old1, new1, 1)
else:
    errors.append("GlobalTracker struct not found")

# Initialise keyIndices in NewGlobalTracker
old2 = (
    '\treturn &GlobalTracker{\n'
    '\t\ttrackers:  make(map[string]*ProviderTracker),\n'
    '\t\tcooldowns: make(map[string]time.Time),\n'
    '\t}'
)
new2 = (
    '\treturn &GlobalTracker{\n'
    '\t\ttrackers:   make(map[string]*ProviderTracker),\n'
    '\t\tcooldowns:  make(map[string]time.Time),\n'
    '\t\tkeyIndices: make(map[string]int),\n'
    '\t}'
)
if old2 in content:
    content = content.replace(old2, new2, 1)
else:
    errors.append("NewGlobalTracker body not found")

# Append new methods at end of file
addition = '''
// patched: key rotation

// CurrentKeyIndex returns the active key index (0-based) for the given provider.
func (g *GlobalTracker) CurrentKeyIndex(providerID string) int {
\tg.mu.RLock()
\tdefer g.mu.RUnlock()
\treturn g.keyIndices[providerID]
}

// RotateKey advances to the next key slot for the provider and returns the new index.
// numKeys must equal ProviderConfig.NumKeys() for the provider.
func (g *GlobalTracker) RotateKey(providerID string, numKeys int) int {
\tif numKeys <= 1 {
\t\treturn 0
\t}
\tg.mu.Lock()
\tdefer g.mu.Unlock()
\tnext := (g.keyIndices[providerID] + 1) % numKeys
\tg.keyIndices[providerID] = next
\treturn next
}
'''

if 'RotateKey' not in content:
    content = content.rstrip() + '\n' + addition
else:
    errors.append("RotateKey already present — methods not appended")

if errors:
    print("patch-C errors: " + ", ".join(errors), file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(content)
print("patched tracker.go")
PYEOF
    if [[ $? -eq 0 ]]; then
        info "Patched $TRACKER_FILE — RotateKey/CurrentKeyIndex"
    else
        warn "Patch C failed — tracker.go may have changed upstream. Continuing."
    fi
else
    info "tracker.go already has key rotation patch — skipping"
fi

if ! grep -q "$PATCH_MARKER" "$SERVER_FILE"; then
    python3 - "$SERVER_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()

old = (
    '\tlog.Printf("fallback chain exhausted: %v", err)\n'
    '\t\thttp.Error(w, `{"error":"all providers exhausted"}`, http.StatusServiceUnavailable)\n'
    '\t\treturn'
)
new = (
    '\tlog.Printf("fallback chain exhausted: %v", err)\n'
    '\t\t// patched: silent exhaustion — return empty completion so client sees no error\n'
    '\t\tw.Header().Set("Content-Type", "application/json")\n'
    '\t\tw.WriteHeader(http.StatusOK)\n'
    '\t\tfmt.Fprintf(w, `{"id":"exhausted","object":"chat.completion","created":%d,"model":"none","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}`, time.Now().Unix())\n'
    '\t\treturn'
)

if old in content:
    open(path, 'w').write(content.replace(old, new, 1))
    print("patched")
else:
    print("target not found — check server.go diff", file=sys.stderr)
    sys.exit(1)
PYEOF
    if [[ $? -eq 0 ]]; then
        info "Patched $SERVER_FILE — exhaustion returns silent empty completion"
    else
        warn "Patch failed — server.go may have changed upstream. Build will use unpatched source."
    fi
else
    info "server.go already patched — skipping"
fi

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
  "api_base": "http://127.0.0.1:${PROXY_PORT}/v1",
  "api_key": "not-needed",
  "model": "${PICOCLAW_MODEL}",
  "max_tokens": 4096,
  "temperature": 0.7,
  "stream": true,
  "timeout": 60
}
JSONEOF
    info "Created $PICOCLAW_CONFIG  (model: ${PICOCLAW_MODEL})"
else
    info "$PICOCLAW_CONFIG exists — patching api_base"
    tmp=$(mktemp)
    jq --arg base "http://127.0.0.1:${PROXY_PORT}/v1" \
       '.api_base = $base' \
       "$PICOCLAW_CONFIG" > "$tmp" && mv "$tmp" "$PICOCLAW_CONFIG"
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

# Adjust ExecStart if picoclaw uses a different subcommand for daemon mode.
# Run: picoclaw --help
ExecStart=${AGENT_BIN} agent --config ${PICOCLAW_CONFIG}

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

if ! grep -q "precise:" "$CONFIG_FILE"; then
    python3 - "$CONFIG_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
block = (
    "\n  precise:\n"
    "    model: \"groq/llama-3.3-70b-versatile\"\n"
    "    overrides:\n"
    "      temperature: 0.1\n"
    "      max_tokens: 400\n"
)
content = open(path).read()
# Insert before fallback: section (known position in config.example.yaml)
if '\nfallback:' in content:
    content = content.replace('\nfallback:', block + '\nfallback:', 1)
else:
    content += block  # append if fallback section missing
open(path, 'w').write(content)
PYEOF
    info "Added 'precise' agent profile to $CONFIG_FILE"
else
    info "'precise' profile already in $CONFIG_FILE"
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

 ── multiply free quota with extra keys ───────────────────────────────────────
   Add numbered variants to ~/.free-llm-proxy-router/.env:
     GROQ_API_KEY_2=gsk_...        second Groq account → 2× daily limit
     GROQ_API_KEY_3=gsk_...        third  Groq account → 3× daily limit
     GEMINI_API_KEY_2=AIza...      same pattern for any provider

   No config.yaml changes. On 429 the proxy rotates to the next key slot
   automatically. Each slot gets its own cooldown so other slots stay live.

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
