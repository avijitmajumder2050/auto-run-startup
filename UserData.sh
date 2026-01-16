#!/bin/bash
# =====================================
# User Data: Setup auto-run systemd
# Repo URL from AWS Parameter Store
# =====================================

set -e

REGION="ap-south-1"
PARAM_NAME="/auto-run/github/repo-url"

APP_USER="ec2-user"
HOME_DIR="/home/ec2-user"
APP_DIR="$HOME_DIR/auto-run-startup"
SERVICE_NAME="auto-run.service"

echo "==== User data started at $(date) ===="

# -----------------------------
# Install required packages
# -----------------------------
yum update -y
yum install -y git 



# -----------------------------
# Fetch GitHub repo URL
# -----------------------------
REPO_URL=$(aws ssm get-parameter \
  --name "$PARAM_NAME" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

if [ -z "$REPO_URL" ]; then
  echo "ERROR: Repo URL not found in Parameter Store"
  exit 1
fi

echo "Using repo: $REPO_URL"

# -----------------------------
# Clone repo into ec2-user home
# -----------------------------
if [ ! -d "$APP_DIR" ]; then
  git clone "$REPO_URL" "$APP_DIR"
else
  cd "$APP_DIR" && git pull
fi

# Set ownership & execute permission
chown -R ec2-user:ec2-user "$APP_DIR"
chmod +x "$APP_DIR/auto_run.sh"

# -----------------------------
# Create systemd service
# -----------------------------
cat <<EOF >/etc/systemd/system/auto-run.service
[Unit]
Description=Auto Run DHAN Jobs on Boot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/auto_run.sh
StandardOutput=append:/var/log/auto-run.log
StandardError=append:/var/log/auto-run-error.log
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable systemd service
systemctl daemon-reload
systemctl start auto-run.service
systemctl enable auto-run.service

echo "==== User data completed at $(date) ===="
