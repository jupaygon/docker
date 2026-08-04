#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------
# setup-dnsmasq.sh — Configure dnsmasq on macOS for *.test → 127.0.0.1
# ---------------------------------------------------------------

echo "==> Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  echo "Error: Homebrew is not installed. Install it from https://brew.sh"
  exit 1
fi

echo "==> Installing dnsmasq (if not already installed)..."
brew install dnsmasq 2>/dev/null || true

DNSMASQ_CONF="$(brew --prefix)/etc/dnsmasq.conf"

echo "==> Configuring dnsmasq to resolve *.test → 127.0.0.1..."
if ! grep -q 'address=/test/127.0.0.1' "$DNSMASQ_CONF" 2>/dev/null; then
  echo 'address=/test/127.0.0.1' >> "$DNSMASQ_CONF"
  echo "   Added address=/test/127.0.0.1 to $DNSMASQ_CONF"
else
  echo "   Already configured in $DNSMASQ_CONF"
fi

echo "==> Restarting dnsmasq service..."
sudo brew services restart dnsmasq

echo "==> Creating /etc/resolver/test..."
sudo mkdir -p /etc/resolver
echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/test >/dev/null

echo "==> Verifying DNS resolution..."
sleep 1
if dig +short test-project.test @127.0.0.1 | grep -q '127.0.0.1'; then
  echo "   OK — *.test resolves to 127.0.0.1"
else
  echo "   WARNING — DNS resolution check failed. Try: dig test-project.test @127.0.0.1"
fi

echo ""
echo "Done! All *.test domains now resolve to 127.0.0.1."
