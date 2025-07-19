#!/bin/bash

# github_action_setup.sh
# Author: Lowil Ray Delos Reyes
# Description: Sets up a GitHub Actions self-hosted runner with systemd support.

set -e

echo "== GitHub Actions Runner Setup =="

# Automatically detect the current user
USERNAME=$(whoami)
echo "Detected Linux username: $USERNAME"

# Prompt for user input
read -rp "Enter app name (e.g. ${USERNAME}-api, ${USERNAME}-app, ${USERNAME}): " APPNAME

RUNNER_DIR="/home/${USERNAME}/actions-runner/${APPNAME}"
SERVICE_NAME="github-runner-${APPNAME}"

# 1. Create runner directory
echo "[1/6] Creating runner directory: $RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# 2. Download runner binary
echo "[2/6] Downloading GitHub Actions runner..."
curl -o actions-runner-linux-x64-2.326.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.326.0/actions-runner-linux-x64-2.326.0.tar.gz
echo "Verifying checksum..."
echo "9c74af9b4352bbc99aecc7353b47bcdfcd1b2a0f6d15af54a99f54a0c14a1de8  actions-runner-linux-x64-2.326.0.tar.gz" | shasum -a 256 -c
tar xzf actions-runner-linux-x64-2.326.0.tar.gz

# 3. Prompt to configure the runner
echo "[3/6] Please enter the following to register the runner"
read -rp "GitHub Repo URL (e.g. https://github.com/org/repo): " REPO_URL
read -rp "GitHub Runner Token: " RUNNER_TOKEN
read -rp "Runner Name (e.g. ${APPNAME}-runner): " RUNNER_NAME
read -rp "Runner Labels (comma-separated, e.g. laravel,backend,ubuntu): " LABELS
read -rp "Work Folder Name (e.g. ${APPNAME}-work): " WORK_NAME

./config.sh \
  --url "$REPO_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABELS" \
  --work "$WORK_NAME"

# 4. Add sudoers entry
echo "[4/6] Ensuring passwordless sudo for $USERNAME..."
SUDOERS_LINE="${USERNAME} ALL=(ALL) NOPASSWD:ALL"
REQUIRETTY_LINE="Defaults:${USERNAME} !requiretty"

sudo grep -qF "$SUDOERS_LINE" /etc/sudoers || echo "$SUDOERS_LINE" | sudo tee -a /etc/sudoers
sudo grep -qF "$REQUIRETTY_LINE" /etc/sudoers || echo "$REQUIRETTY_LINE" | sudo tee -a /etc/sudoers

# 4. Add sudoers entry (modular and safe)
echo "[4/6] Ensuring passwordless sudo for $USERNAME using /etc/sudoers.d..."

SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"

if [ ! -f "$SUDOERS_FILE" ]; then
  echo "Creating sudoers file: $SUDOERS_FILE"
  {
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL"
    echo "Defaults:${USERNAME} !requiretty"
  } | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  echo "Sudoers entry added safely."
else
  echo "Sudoers file already exists: $SUDOERS_FILE (skipping)"
fi

# 5. Create systemd service
echo "[5/6] Creating systemd service for auto-start..."

SERVICE_FILE="${RUNNER_DIR}/${SERVICE_NAME}.service"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=GitHub Actions Runner for ${APPNAME}
After=network.target

[Service]
User=${USERNAME}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable and start the service
echo "[6/6] Enabling and starting systemd service..."

sudo ln -sf "$SERVICE_FILE" "/etc/systemd/system/${SERVICE_NAME}.service"
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl start "${SERVICE_NAME}"

echo "✅ GitHub Actions runner for ${APPNAME} is set up and running!"
