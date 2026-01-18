#!/bin/bash
set -euo pipefail

REGION="ap-south-1"
MAX_RETRIES=3
RETRY_SLEEP=60

# -----------------------------
# AWS / ECR
# -----------------------------
ACCOUNT_ID=$(aws ssm get-parameter \
  --name "/dhan/aws/account-id" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# -----------------------------
# Telegram
# -----------------------------
BOT_TOKEN=$(aws ssm get-parameter \
  --name "/trading-bot/telegram/BOT_TOKEN" \
  --with-decryption \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

CHAT_ID=$(aws ssm get-parameter \
  --name "/trading-bot/telegram/CHAT_ID" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="$1" > /dev/null
}

# -----------------------------
# Terminate EC2
# -----------------------------
terminate_ec2() {
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

  INSTANCE_ID=$(curl -s \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)

  aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

  exit 0
}

# -----------------------------
# System setup
# -----------------------------
sudo yum update -y
sudo yum install -y docker awscli
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

mkdir -p /home/ec2-user/logs
chown ec2-user:ec2-user /home/ec2-user/logs

# -----------------------------
# Docker block
# -----------------------------
newgrp docker <<EOF
set -e

aws ecr get-login-password --region ${REGION} \
| docker login --username AWS --password-stdin ${ECR_REGISTRY}

docker pull ${ECR_REGISTRY}/dhan-token-refresh:latest
docker pull ${ECR_REGISTRY}/dhan-ohlc-job:latest

# =============================
# TOKEN REFRESH (RETRY)
# =============================
TOKEN_SUCCESS=false

for i in 1 2 3; do
  echo "Token Refresh attempt \$i"
  if docker run --rm \
    ${ECR_REGISTRY}/dhan-token-refresh:latest \
    >> /home/ec2-user/logs/token.log 2>&1; then
    TOKEN_SUCCESS=true
    break
  fi
  sleep 60
done

if [ "\$TOKEN_SUCCESS" != "true" ]; then
  echo "TOKEN_FAILED" > /tmp/job_status
  exit 1
fi

# =============================
# OHLC JOB (RETRY)
# =============================
OHLC_SUCCESS=false

for i in 1 2 3; do
  echo "OHLC attempt \$i"
  if docker run --rm \
    ${ECR_REGISTRY}/dhan-ohlc-job:latest \
    >> /home/ec2-user/logs/ohlc.log 2>&1; then
    OHLC_SUCCESS=true
    break
  fi
  sleep 60
done

if [ "\$OHLC_SUCCESS" != "true" ]; then
  echo "OHLC_FAILED" > /tmp/job_status
  exit 1
fi

echo "SUCCESS" > /tmp/job_status
EOF

# -----------------------------
# Result handling
# -----------------------------
STATUS=$(cat /tmp/job_status || echo "FAILED")

if [ "$STATUS" = "SUCCESS" ]; then
  send_telegram "<b>✅ Token Refresh & OHLC Success</b>

Jobs completed successfully.
EC2 terminating.

<i>⚠️ Educational purpose only. No buy/sell recommendation.</i>"
else
  send_telegram "<b>❌ Job Failed</b>

Check logs on EC2.
Instance terminating."
fi

terminate_ec2
