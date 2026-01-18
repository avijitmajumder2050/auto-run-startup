#!/bin/bash

# ==============================
# EC2 Auto Setup - DHAN Jobs
# Amazon Linux 2023
# ==============================

set -e

REGION="ap-south-1"
ACCOUNT_ID=$(aws ssm get-parameter \
  --name "/dhan/aws/account-id" \
  --region $REGION \
  --query "Parameter.Value" \
  --output text)

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Using ECR registry: $ECR_REGISTRY"

# -----------------------------
# Telegram setup
# -----------------------------
TELEGRAM_BOT_TOKEN=$(aws ssm get-parameter \
  --name "/trading-bot/telegram/BOT_TOKEN" \
  --with-decryption \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

TELEGRAM_CHAT_ID=$(aws ssm get-parameter \
  --name "/trading-bot/telegram/CHAT_ID" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="$1" > /dev/null
}

echo "==== Updating system ===="
sudo yum update -y

echo "==== Installing Docker and utilities ===="
sudo yum install -y docker awscli

echo "==== Enable Docker ===="
sudo systemctl enable docker
sudo systemctl start docker

echo "==== Add ec2-user to docker group ===="
sudo usermod -aG docker ec2-user

echo "==== Create logs folder ===="
mkdir -p /home/ec2-user/logs
chown ec2-user:ec2-user /home/ec2-user/logs

echo "==== Switch to docker group and run jobs ===="

newgrp docker <<EOF
set -e

echo "==== Login to AWS ECR ===="
aws ecr get-login-password --region ${REGION} \
| docker login --username AWS --password-stdin ${ECR_REGISTRY}

echo "==== Pull DHAN Docker images ===="
docker pull ${ECR_REGISTRY}/dhan-token-refresh:latest
docker pull ${ECR_REGISTRY}/dhan-ohlc-job:latest

export PATH=/usr/local/bin:/usr/bin:/bin
export HOME=/home/ec2-user

echo "==== Token refresh job ===="
docker run --rm \
${ECR_REGISTRY}/dhan-token-refresh:latest \
>> /home/ec2-user/logs/token.log 2>&1

sleep 180

echo "==== OHLC job ===="
docker run --rm \
${ECR_REGISTRY}/dhan-ohlc-job:latest \
>> /home/ec2-user/logs/ohlc.log 2>&1

echo "==== Docker jobs completed ===="
EOF

echo "==== SCRIPT FINISHED SUCCESSFULLY ===="

# -----------------------------
# Send Telegram notification
# -----------------------------
send_telegram "<b>✅ Daily OHCL Jobs Completed</b>

Docker jobs finished successfully.
Instance will now terminate.

<i>⚠️ Educational purpose only. No buy/sell recommendation.</i>"

# -----------------------------
# Self-terminate EC2 instance
# -----------------------------
sleep 120
echo "==== Fetching EC2 instance ID via IMDSv2 ===="
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")

echo "==== Terminating instance: $INSTANCE_ID ===="
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"

echo "==== Termination request sent ===="
