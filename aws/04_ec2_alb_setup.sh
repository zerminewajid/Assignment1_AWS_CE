#!/bin/bash
# ============================================================
# Script 4: EC2 Launch Template + ALB + Auto Scaling Group
# UniEvent - Assignment 1 CE 308/408 Cloud Computing
# Run AFTER 03_s3_setup.sh
# ============================================================
set -e
source ./vpc_ids.env

echo "========================================"
echo " UniEvent — EC2 + ALB Setup"
echo "========================================"

# ── EC2 settings ─────────────────────────────────────────────
AMI_ID="ami-0c02fb55956c7d316"   # Amazon Linux 2 us-east-1 (update for your region)
INSTANCE_TYPE="t2.micro"          # Free tier
KEY_NAME="unievents-key"          # Change to your existing key pair name
PROJECT="unievents"

# ── 1. Create Key Pair ────────────────────────────────────────
echo "[1/7] Creating Key Pair: $KEY_NAME ..."
aws ec2 create-key-pair \
  --key-name $KEY_NAME \
  --query 'KeyMaterial' --output text > ${KEY_NAME}.pem 2>/dev/null || echo "  Key pair already exists, skipping."
chmod 400 ${KEY_NAME}.pem 2>/dev/null || true
echo "  ✅ Key: ${KEY_NAME}.pem (keep this safe!)"

# ── 2. User Data Script (bootstraps Flask on EC2) ────────────
echo "[2/7] Preparing User Data bootstrap script..."
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
yum update -y
yum install -y git python3 python3-pip

# Clone the app from GitHub
cd /home/ec2-user
git clone https://github.com/zerminewajid/Assignment1_AWS_CE.git app
cd app/app

# Install dependencies
pip3 install -r requirements.txt

# Create .env from environment (values injected via Systems Manager
# Parameter Store in production — using direct env vars here for demo)
cat > .env <<'ENV'
PREDICTHQ_API_KEY=uLe2h5k6s1B-Eroi00y7S4knPelbwBmUB2Z3ICZN
S3_BUCKET_NAME=unievents-media-296886269163
AWS_REGION=us-east-1
SECRET_KEY=supersecretchangethis
ENV

# Start Flask with gunicorn on port 5000
nohup gunicorn --workers 2 --bind 0.0.0.0:5000 app:app \
  --access-logfile /var/log/unievents-access.log \
  --error-logfile /var/log/unievents-error.log &

echo "UniEvent started!" >> /var/log/unievents-startup.log
USERDATA
)

USER_DATA_B64=$(echo "$USER_DATA" | base64 -w 0)

# ── 3. Launch Template ─────────────────────────────────────────
echo "[3/7] Creating EC2 Launch Template..."
LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name ${PROJECT}-lt \
  --version-description "v1" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"KeyName\": \"$KEY_NAME\",
    \"SecurityGroupIds\": [\"$APP_SG\"],
    \"IamInstanceProfile\": {\"Name\": \"${PROJECT}-ec2-profile\"},
    \"UserData\": \"$USER_DATA_B64\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"${PROJECT}-app-server\"}]
    }]
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
echo "  ✅ Launch Template: $LT_ID"

# ── 4. Application Load Balancer ──────────────────────────────
echo "[4/7] Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name ${PROJECT}-alb \
  --subnets $PUB_SUB_1 $PUB_SUB_2 \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "  ✅ ALB ARN: $ALB_ARN"
echo "  ✅ ALB DNS: $ALB_DNS"

# ── 5. Target Group ────────────────────────────────────────────
echo "[5/7] Creating Target Group (health check on /health)..."
TG_ARN=$(aws elbv2 create-target-group \
  --name ${PROJECT}-tg \
  --protocol HTTP \
  --port 5000 \
  --vpc-id $VPC_ID \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "  ✅ Target Group: $TG_ARN"

# ALB Listener → forward to target group
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  > /dev/null
echo "  ✅ ALB Listener created (HTTP:80 → Flask:5000)"

# ── 6. Auto Scaling Group ──────────────────────────────────────
echo "[6/7] Creating Auto Scaling Group (2 instances across 2 AZs)..."
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name ${PROJECT}-asg \
  --launch-template LaunchTemplateId=$LT_ID,Version='$Latest' \
  --min-size 2 \
  --max-size 4 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$PRIV_SUB_1,$PRIV_SUB_2" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --tags Key=Name,Value=${PROJECT}-app-server,PropagateAtLaunch=true

# Scale-out policy: add instance if CPU > 70%
SCALE_OUT=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name ${PROJECT}-asg \
  --policy-name scale-out \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 70.0
  }' \
  --query 'PolicyARN' --output text)
echo "  ✅ ASG created with 2 instances + CPU auto-scaling policy"

# ── 7. Save IDs ─────────────────────────────────────────────
echo "[7/7] Saving IDs..."
cat >> vpc_ids.env <<EOF
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN
LT_ID=$LT_ID
EOF

echo ""
echo "========================================"
echo " ✅ EC2 + ALB Setup Complete!"
echo "========================================"
echo ""
echo " 🌐 Application URL: http://$ALB_DNS"
echo ""
echo " ALB:          $ALB_ARN"
echo " Target Group: $TG_ARN"
echo " ASG:          ${PROJECT}-asg (min=2, max=4)"
echo ""
echo " ⏳ Wait ~3 minutes for instances to pass health checks,"
echo "    then visit the URL above."
echo "========================================"
