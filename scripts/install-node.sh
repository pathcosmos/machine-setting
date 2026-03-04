#!/usr/bin/env bash
# Install NVM + Node.js LTS
set -euo pipefail

NODE_VERSION="${1:-lts}"

echo "=== Node.js Setup ==="

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Install NVM if not present
if [ ! -d "$NVM_DIR" ]; then
    echo "Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    echo "  NVM installed"
fi

# Load NVM
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

if ! command -v nvm &>/dev/null; then
    echo "Error: NVM failed to load"
    exit 1
fi

# Install Node
if [ "$NODE_VERSION" = "lts" ]; then
    echo "Installing Node.js LTS..."
    nvm install --lts
    nvm alias default lts/*
else
    echo "Installing Node.js ${NODE_VERSION}..."
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
fi

# Update npm
npm install -g npm@latest 2>/dev/null || true

echo "  Node $(node --version) + npm $(npm --version) ready"
