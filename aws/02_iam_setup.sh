#!/bin/bash
# ============================================================
# Script 2: IAM Role, Policy & Instance Profile
# UniEvent - Assignment 1 CE 308/408 Cloud Computing
# Run AFTER 01_vpc_setup.sh
# ============================================================
set -e

PROJECT="unievents"

echo "========================================"
echo " UniEvent — IAM Setup"
echo "========================================"

# ── Trust policy: allow EC2 to assume this role ─────────────
cat > ./ec2-trust-policy.json <<'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST

echo "[1/4] Creating IAM Role: ${PROJECT}-ec2-role ..."
ROLE_ARN=$(aws iam create-role \
  --role-name ${PROJECT}-ec2-role \
  --assume-role-policy-document file://./ec2-trust-policy.json \
  --description "Role for UniEvent EC2 instances to access S3" \
  --query 'Role.Arn' --output text)
echo "  ✅ Role ARN: $ROLE_ARN"

# ── Inline policy: allow S3 read/write on our bucket ────────
S3_BUCKET_NAME="${PROJECT}-media-$(aws sts get-caller-identity --query 'Account' --output text)"
echo "  (Target S3 bucket will be: $S3_BUCKET_NAME)"

cat > ./s3-policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_NAME}",
        "arn:aws:s3:::${S3_BUCKET_NAME}/*"
      ]
    }
  ]
}
POLICY

echo "[2/4] Attaching S3 inline policy to role..."
aws iam put-role-policy \
  --role-name ${PROJECT}-ec2-role \
  --policy-name ${PROJECT}-s3-access \
  --policy-document file://./s3-policy.json
echo "  ✅ S3 policy attached"

# ── Instance Profile ────────────────────────────────────────
echo "[3/4] Creating Instance Profile..."
aws iam create-instance-profile \
  --instance-profile-name ${PROJECT}-ec2-profile 2>/dev/null || true

aws iam add-role-to-instance-profile \
  --instance-profile-name ${PROJECT}-ec2-profile \
  --role-name ${PROJECT}-ec2-role
echo "  ✅ Instance profile: ${PROJECT}-ec2-profile"

# Save for next scripts
echo "[4/4] Saving IAM info..."
cat >> vpc_ids.env <<EOF
IAM_ROLE=${PROJECT}-ec2-role
IAM_PROFILE=${PROJECT}-ec2-profile
S3_BUCKET_NAME=$S3_BUCKET_NAME
EOF

echo ""
echo "========================================"
echo " ✅ IAM Setup Complete!"
echo "========================================"
echo " Role name:        ${PROJECT}-ec2-role"
echo " Instance profile: ${PROJECT}-ec2-profile"
echo " S3 bucket target: $S3_BUCKET_NAME"
echo ""
echo " Run 03_s3_setup.sh next."
echo "========================================"

# Cleanup temp files
rm -f ./ec2-trust-policy.json ./s3-policy.json
