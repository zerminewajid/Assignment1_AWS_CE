#!/bin/bash
# ============================================================
# Teardown Script — DELETE all UniEvent AWS resources
# ⚠️  WARNING: This permanently deletes everything. Use after viva!
# ============================================================
set -e
source ./vpc_ids.env

PROJECT="unievents"
echo "⚠️  Deleting ALL UniEvent AWS resources in 10 seconds..."
echo "   Press Ctrl+C to cancel!"
sleep 10

echo "[1] Deleting Auto Scaling Group..."
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name ${PROJECT}-asg --force-delete 2>/dev/null || true
sleep 5

echo "[2] Deleting ALB & Target Group..."
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN 2>/dev/null || true
sleep 10
aws elbv2 delete-target-group --target-group-arn $TG_ARN 2>/dev/null || true

echo "[3] Deleting Launch Template..."
aws ec2 delete-launch-template --launch-template-id $LT_ID 2>/dev/null || true

echo "[4] Deleting NAT Gateway..."
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW 2>/dev/null || true
echo "  Waiting for NAT GW deletion..."
sleep 60

echo "[5] Releasing Elastic IP..."
EIP_ALLOC=$(aws ec2 describe-addresses \
  --query 'Addresses[?Tags[?Key==`Name` && Value==`unievents*`]].AllocationId' \
  --output text 2>/dev/null)
[ -n "$EIP_ALLOC" ] && aws ec2 release-address --allocation-id $EIP_ALLOC 2>/dev/null || true

echo "[6] Deleting Subnets..."
for SUB in $PUB_SUB_1 $PUB_SUB_2 $PRIV_SUB_1 $PRIV_SUB_2; do
  aws ec2 delete-subnet --subnet-id $SUB 2>/dev/null || true
done

echo "[7] Deleting Route Tables..."
aws ec2 delete-route-table --route-table-id $PUB_RT 2>/dev/null || true
aws ec2 delete-route-table --route-table-id $PRIV_RT 2>/dev/null || true

echo "[8] Detaching & deleting Internet Gateway..."
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>/dev/null || true
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID 2>/dev/null || true

echo "[9] Deleting Security Groups..."
aws ec2 delete-security-group --group-id $APP_SG 2>/dev/null || true
aws ec2 delete-security-group --group-id $ALB_SG 2>/dev/null || true

echo "[10] Deleting VPC..."
aws ec2 delete-vpc --vpc-id $VPC_ID 2>/dev/null || true

echo "[11] Deleting S3 Bucket (empties it first)..."
aws s3 rm s3://$S3_BUCKET_NAME --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket $S3_BUCKET_NAME 2>/dev/null || true

echo "[12] Deleting IAM Role & Instance Profile..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name ${PROJECT}-ec2-profile \
  --role-name ${PROJECT}-ec2-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name ${PROJECT}-ec2-profile 2>/dev/null || true
aws iam delete-role-policy \
  --role-name ${PROJECT}-ec2-role \
  --policy-name ${PROJECT}-s3-access 2>/dev/null || true
aws iam delete-role --role-name ${PROJECT}-ec2-role 2>/dev/null || true

echo ""
echo "✅ All resources deleted. Check the AWS console to confirm."
