#!/bin/bash
# Webhook Mode Auto-on Instabox.sh — Setup Script
# Usage: ./setup-webhook.sh <machine-id-or-name>
# Example: ./setup-webhook.sh m_agqw2hddxvemzakrynuxpwd6mi

set -e

MACHINE="${1:-}"
if [ -z "$MACHINE" ]; then
    echo "Usage: $0 <machine-id-or-name>"
    echo "Example: $0 m_agqw2hddxvemzakrynuxpwd6mi"
    exit 1
fi

echo "🔍 Checking machine..."
instabox get "$MACHINE" --json | jq '. | {name, state}' || { echo "❌ Machine not found"; exit 1; }

echo ""
echo "📡 Step 1: Publishing port 8443..."
PORT_RESULT=$(instabox-port publish 8443 --name hermes-telegram-webhook --json 2>&1)
WEBHOOK_URL=$(echo "$PORT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null || echo "")
if [ -z "$WEBHOOK_URL" ]; then
    echo "⚠️  Could not parse URL, checking existing ports..."
    WEBHOOK_URL=$(instabox-port list 2>/dev/null | grep 8443 | head -1 | awk '{print $2}')
fi
echo "   URL: $WEBHOOK_URL"

echo ""
echo "🔐 Step 2: Generating webhook secret..."
SECRET=$(openssl rand -hex 32)
echo "   Secret generated: ${SECRET:0:12}..."

echo ""
echo "📝 Step 3: Adding config to ~/.hermes/.env..."
grep -v "TELEGRAM_WEBHOOK_" ~/.hermes/.env > /tmp/.env_clean 2>/dev/null || cp ~/.hermes/.env /tmp/.env_clean
cat >> /tmp/.env_clean << EOF

TELEGRAM_WEBHOOK_URL=${WEBHOOK_URL}/telegram
TELEGRAM_WEBHOOK_SECRET=${SECRET}
TELEGRAM_WEBHOOK_PORT=8443
EOF
cp /tmp/.env_clean ~/.hermes/.env
chmod 600 ~/.hermes/.env
echo "   ✅ .env updated"

echo ""
echo "⚙️  Step 4: Disabling drop_pending_on_cold_boot..."
hermes config set platforms.telegram.extra.drop_pending_on_cold_boot false 2>/dev/null || echo "   ⚠️  Could not set config (may need separate shell)"

echo ""
echo "📨 Step 5: Registering webhook with Telegram API..."
TOKEN=$(grep TELEGRAM_BOT_TOKEN ~/.hermes/.env | cut -d= -f2)
if [ -z "$TOKEN" ]; then
    echo "❌ TELEGRAM_BOT_TOKEN not found in .env"
    exit 1
fi

RESULT=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  --data-urlencode "url=${WEBHOOK_URL}/telegram" \
  --data-urlencode "secret_token=${SECRET}")

echo "   Response: $RESULT"
if echo "$RESULT" | grep -q '"ok": true'; then
    echo "   ✅ Webhook registered!"
else
    echo "   ⚠️  Registration failed — check token and URL"
fi

echo ""
echo "🔄 Step 6: Restart gateway..."
echo "   Run this in a SEPARATE terminal/shell (not from inside Hermes chat):"
echo ""
echo "   hermes gateway restart"
echo ""
echo "   Or restart the whole sandbox:"
echo ""
echo "   instabox stop $MACHINE && instabox start $MACHINE"
echo ""

echo "📊 Step 7: Verify..."
echo "   After restart, check with:"
echo ""
echo "   curl -s \"https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/getWebhookInfo\" | jq '.result | {url, pending_update_count, last_error_message}'"
echo ""

echo "✅ Setup complete! Webhook URL: ${WEBHOOK_URL}/telegram"