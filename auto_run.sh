#!/bin/bash
set -euo pipefail

REGION="ap-south-1"
MAX_RETRIES=3
RETRY_SLEEP=60

# =============================
# AWS / ECR
# =============================
ACCOUNT_ID=$(aws ssm get-parameter \
  --name "/dhan/aws/account-id" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# =============================
# Telegram
# =============================
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
  echo "📩 Sending Telegram message..."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="$1" || echo "⚠️ Telegram failed"
}

# =============================
# EC2 TERMINATION
# =============================
terminate_ec2() {
  echo "🛑 Terminating EC2..."

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

# =============================
# SYSTEM SETUP
# =============================
sudo yum update -y
sudo yum install -y docker awscli
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

mkdir -p /home/ec2-user/logs
chown ec2-user:ec2-user /home/ec2-user/logs

# =============================
# DOCKER EXECUTION
# =============================
newgrp docker <<EOF
set -e

aws ecr get-login-password --region ${REGION} \
| docker login --username AWS --password-stdin ${ECR_REGISTRY}

docker pull ${ECR_REGISTRY}/dhan-token-refresh:latest
docker pull ${ECR_REGISTRY}/dhan-ohlc-job:latest

# -----------------------------
# TOKEN REFRESH (RETRY)
# -----------------------------
TOKEN_SUCCESS=false

for i in 1 2 3; do
  echo "🔁 Token Refresh attempt \$i"
  if docker run --rm \
    ${ECR_REGISTRY}/dhan-token-refresh:latest \
    >> /home/ec2-user/logs/token.log 2>&1; then
    TOKEN_SUCCESS=true
    break
  fi
  sleep ${RETRY_SLEEP}
done

if [ "\$TOKEN_SUCCESS" != "true" ]; then
  echo "TOKEN_FAILED" > /tmp/job_status
  exit 1
fi

# -----------------------------
# OHLC JOB (RETRY)
# -----------------------------
OHLC_SUCCESS=false

for i in 1 2 3; do
  echo "🔁 OHLC attempt \$i"
  if docker run --rm \
    ${ECR_REGISTRY}/dhan-ohlc-job:latest \
    >> /home/ec2-user/logs/ohlc.log 2>&1; then
    OHLC_SUCCESS=true
    break
  fi
  sleep ${RETRY_SLEEP}
done

if [ "\$OHLC_SUCCESS" != "true" ]; then
  echo "OHLC_FAILED" > /tmp/job_status
  exit 1
fi

echo "SUCCESS" > /tmp/job_status
EOF

# =============================
# RESULT HANDLING
# =============================
STATUS=$(cat /tmp/job_status || echo "FAILED")

if [ "$STATUS" = "SUCCESS" ]; then
  send_telegram "<b>✅ Token Refresh & OHLC SUCCESS</b>

All jobs completed successfully.
EC2 will now terminate.

<i>⚠️ Educational purpose only. No buy/sell recommendation.</i>" || true
else
  send_telegram "<b>❌ Job FAILED</b>

Token or OHLC failed after retries.
EC2 will now terminate." || true
fi

terminate_ec2
