#!/bin/bash
# =====================================
# User Data: Auto-run + Log upload to S3
# =====================================

set -e

LOG=/var/log/auto-run-bootstrap.log
exec > >(tee -a $LOG) 2>&1

echo "🚀 Bootstrapping Trading Bot EC2"
# -----------------------------
# CONFIG
# -----------------------------
REGION="ap-south-1"
PARAM_NAME="/auto-run/github/repo-url"

APP_USER="ec2-user"
HOME_DIR="/home/ec2-user"
APP_DIR="$HOME_DIR/auto-run-startup"

LOG_FILE="/var/log/auto-run.log"
S3_BUCKET="s3://dhan-trading-data"
S3_PREFIX="trading-bot"

echo "==== User data started at $(date) ===="

# -----------------------------
# Install required packages
# -----------------------------
yum update -y
yum install -y git awscli 
timedatectl set-timezone Asia/Kolkata

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
# Clone or update repo
# -----------------------------
if [ ! -d "$APP_DIR" ]; then
  git clone "$REPO_URL" "$APP_DIR"
else
  cd "$APP_DIR" && git pull
fi

chown -R ec2-user:ec2-user "$APP_DIR"
chmod +x "$APP_DIR/auto_run.sh"

# -----------------------------
# auto-run systemd service
# -----------------------------
tee /etc/systemd/system/auto-run.service > /dev/null <<EOF
[Unit]
Description=Auto Run DHAN Jobs on Boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/auto_run.sh
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------
# Log upload script
# -----------------------------
tee /usr/local/bin/upload-auto-run-log.sh > /dev/null <<EOF
#!/bin/bash
if [ -f "$LOG_FILE" ]; then
  aws s3 cp "$LOG_FILE" \
    "$S3_BUCKET/$S3_PREFIX/logs/auto-run.log" \
    --region "$REGION" || true
fi
EOF

chmod +x /usr/local/bin/upload-auto-run-log.sh

# -----------------------------
# Log upload service
# -----------------------------
tee /etc/systemd/system/auto-run-log-upload.service > /dev/null <<EOF
[Unit]
Description=Upload auto-run.log to S3

[Service]
Type=oneshot
ExecStart=/usr/local/bin/upload-auto-run-log.sh
EOF

# -----------------------------
# Log upload timer (5 min)
# -----------------------------
tee /etc/systemd/system/auto-run-log-upload.timer > /dev/null <<EOF
[Unit]
Description=Upload auto-run.log to S3 every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# -----------------------------
# Enable services
# -----------------------------
systemctl daemon-reload
systemctl enable auto-run.service

systemctl enable --now auto-run-log-upload.timer
systemctl restart  auto-run.service
echo "==== User data completed at $(date) ===="

echo "✅ Trading Bot started; /var/log/auto-run-bootstrap.log uploads to S3 only"
