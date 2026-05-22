#!/usr/bin/env bash

# VM Boot Init & Auto-Configuration Script for OpenClaw
# Runs as root on the newly created Ubuntu VM.

# Redirect output to log file for debugging
exec > >(tee -a /var/log/openclaw-startup.log) 2>&1
echo "=== OpenClaw Provisioning Started: $(date) ==="

set -euo pipefail

# 1. Update system & install baseline tools
echo "[...] Updating packages..."
apt-get update -y
apt-get install -y curl jq git build-essential

# 2. Install Node.js 24
echo "[...] Installing Node.js 24 LTS..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
echo "[✔] Node.js version: $(node -v)"
echo "[✔] NPM version: $(npm -v)"

# 3. Install OpenClaw CLI globally
echo "[...] Installing OpenClaw CLI globally..."
npm install -g openclaw@latest
(cd "$(npm root -g)/openclaw" && node scripts/postinstall-bundled-plugins.mjs)
echo "[✔] OpenClaw installed successfully."

# 4. Create dedicated user
echo "[...] Creating system user 'openclaw'..."
if ! id -u openclaw &>/dev/null; then
    useradd -m -s /bin/bash openclaw
    echo "[✔] User 'openclaw' created."
else
    echo "[✔] User 'openclaw' already exists."
fi

# 5. Fetch API Credentials from GCP Secret Manager via Metadata Server
echo "[...] Retrieving API keys from GCP Secret Manager..."

# Get Access Token from local Metadata Server
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
TOKEN_HEADERS="Metadata-Flavor: Google"

# Check if token is retrievable
TOKEN_RES=$(curl -s -H "$TOKEN_HEADERS" "$METADATA_URL/instance/service-accounts/default/token" || echo "failed")

if [[ "$TOKEN_RES" == "failed" || -z "$TOKEN_RES" ]]; then
    echo "Error: Failed to contact GCP Metadata Server or acquire access token."
    exit 1
fi

TOKEN=$(echo "$TOKEN_RES" | jq -r .access_token)
PROJECT_NUMBER=$(curl -s -H "$TOKEN_HEADERS" "$METADATA_URL/project/numeric-project-id")

fetch_secret() {
    local secret_name=$1
    local url="https://secretmanager.googleapis.com/v1/projects/${PROJECT_NUMBER}/secrets/${secret_name}/versions/latest:access"
    local res
    
    res=$(curl -s -H "Authorization: Bearer $TOKEN" "$url")
    
    # Check if payload is retrievable
    local payload
    payload=$(echo "$res" | jq -r '.payload.data' 2>/dev/null || echo "null")
    
    if [ "$payload" = "null" ] || [ -z "$payload" ]; then
        echo "Error: Failed to fetch secret $secret_name from Secret Manager API."
        echo "API Response: $res"
        exit 1
    fi
    
    echo "$payload" | base64 --decode
}

GEMINI_API_KEY=$(fetch_secret "openclaw-gemini-api-key")
TELEGRAM_BOT_TOKEN=$(fetch_secret "openclaw-telegram-bot-token")

echo "[✔] Credentials successfully fetched."

# 6. Non-interactive OpenClaw onboarding and configuration
echo "[...] Initializing OpenClaw environment..."

# Run onboard command under the openclaw user context
sudo -u openclaw -i openclaw onboard --non-interactive \
  --accept-risk \
  --skip-health \
  --skip-bootstrap \
  --skip-skills \
  --mode local \
  --auth-choice gemini-api-key \
  --gemini-api-key "$GEMINI_API_KEY"

# Configure LLM provider settings (timeouts, models)
echo "[...] Configuring Google Gemini provider timeout and settings..."
sudo -u openclaw -i openclaw config set models.providers.google-gemini "{\"api\": \"google-generative-ai\", \"baseUrl\": \"https://generativelanguage.googleapis.com\", \"timeoutSeconds\": 300, \"apiKey\": \"$GEMINI_API_KEY\", \"models\": [{\"id\": \"gemini-3.1-flash-lite\", \"name\": \"Gemini 3.1 Flash Lite\"}]}" --strict-json --merge

# Set default LLM model
echo "[...] Setting Gemini 3.1 Flash Lite as default model..."
sudo -u openclaw -i openclaw models set google-gemini/gemini-3.1-flash-lite

# Configure channels in openclaw.json
echo "[...] Configuring Telegram Channel..."
sudo -u openclaw -i openclaw config set channels.telegram.enabled true
sudo -u openclaw -i openclaw config set channels.telegram.botToken "$TELEGRAM_BOT_TOKEN"
sudo -u openclaw -i openclaw config set channels.telegram.dmPolicy "pairing"

# Configure subagent execution permissions (allowAgents)
echo "[...] Configuring subagent permissions..."
sudo -u openclaw -i openclaw config set agents.defaults.subagents.allowAgents '["thesis-pedant", "thesis-practitioner", "thesis-visionary", "session-moderator"]' --strict-json --merge
sudo -u openclaw -i openclaw config set agents.defaults.subagents.maxConcurrent 1
sudo -u openclaw -i openclaw config set agents.defaults.subagents.runTimeoutSeconds 300

# Configure tool profile to enable sessions_spawn / sessions_yield for orchestration
echo "[...] Configuring tool profile..."
sudo -u openclaw -i openclaw config set tools.profile '"coding"'

# Configure Telegram UX enhancements
echo "[...] Configuring Telegram UX (custom commands, streaming)..."
sudo -u openclaw -i openclaw config set channels.telegram.customCommands '[{"command":"defend","description":"Почати захист курсової роботи"},{"command":"end","description":"Завершити захист"}]' --strict-json --merge
sudo -u openclaw -i openclaw config set channels.telegram.streaming '{"mode":"partial"}' --strict-json --merge

# Configure session reset and isolation
echo "[...] Configuring session management..."
sudo -u openclaw -i openclaw config set session.reset '{"mode":"idle","idleMinutes":120}' --strict-json --merge

# Rebuild the plugin registry for the openclaw user to prevent stale/missing plugin errors
echo "[...] Rebuilding plugin registry..."
sudo -u openclaw -i openclaw doctor --fix

echo "[✔] OpenClaw configuration complete."

# 7. Create Systemd Service
echo "[...] Registering OpenClaw Gateway as a systemd service..."

# Write credentials to a protected environment file (never inline in unit files)
cat <<EOF > /home/openclaw/.env
GEMINI_API_KEY=$GEMINI_API_KEY
EOF
chmod 600 /home/openclaw/.env
chown openclaw:openclaw /home/openclaw/.env

OPENCLAW_PATH=$(which openclaw)

cat <<EOF > /etc/systemd/system/openclaw.service
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw
ExecStart=$OPENCLAW_PATH gateway --force
Restart=always
RestartSec=5
EnvironmentFile=/home/openclaw/.env
Environment=PATH=/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin
Environment=OPENCLAW_SERVICE_REPAIR_POLICY=external

[Install]
WantedBy=multi-user.target
EOF

# Reload and launch system service
systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw
echo "[✔] OpenClaw systemd service started."

# 8. Create system-wide shell alias
echo "[...] Installing global command alias..."
cat <<'EOF' > /etc/profile.d/openclaw.sh
# Global alias for running openclaw CLI commands safely as openclaw system user
alias openclaw='sudo -u openclaw -i openclaw'
EOF
chmod +x /etc/profile.d/openclaw.sh

# 9. Create finished indicator flag for setup-gcp.sh orchestrator
touch /var/tmp/startup-finished
echo "=== OpenClaw Provisioning Complete: $(date) ==="
