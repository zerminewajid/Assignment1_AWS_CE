#!/bin/bash
# ============================================================
# Script 3: S3 Bucket Setup
# UniEvent - Assignment 1 CE 308/408 Cloud Computing
# Run AFTER 02_iam_setup.sh
# ============================================================
set -e
source ./vpc_ids.env

echo "========================================"
echo " UniEvent — S3 Bucket Setup"
echo "========================================"

# ── Create bucket ───────────────────────────────────────────
echo "[1/4] Creating S3 bucket: $S3_BUCKET_NAME ..."

if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket $S3_BUCKET_NAME \
    --region $AWS_REGION
else
  aws s3api create-bucket \
    --bucket $S3_BUCKET_NAME \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION
fi
echo "  ✅ Bucket created: $S3_BUCKET_NAME"

# ── Block public access (security best practice) ────────────
echo "[2/4] Blocking all public access..."
aws s3api put-public-access-block \
  --bucket $S3_BUCKET_NAME \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  ✅ Public access blocked"

# ── Enable versioning ────────────────────────────────────────
echo "[3/4] Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket $S3_BUCKET_NAME \
  --versioning-configuration Status=Enabled
echo "  ✅ Versioning enabled"

# ── Lifecycle rule: auto-delete old versions after 30 days ──
echo "[4/4] Setting lifecycle policy (auto-delete old versions after 30 days)..."
cat > ./lifecycle.json <<'LIFECYCLE'
{
  "Rules": [
    {
      "ID": "expire-old-versions",
      "Status": "Enabled",
      "Filter": { "Prefix": "posters/" },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
    }
  ]
}
LIFECYCLE

aws s3api put-bucket-lifecycle-configuration \
  --bucket $S3_BUCKET_NAME \
  --lifecycle-configuration file://./lifecycle.json
echo "  ✅ Lifecycle policy applied"

rm -f ./lifecycle.json

echo ""
echo "========================================"
echo " ✅ S3 Setup Complete!"
echo "========================================"
echo " Bucket: s3://$S3_BUCKET_NAME"
echo " Region: $AWS_REGION"
echo " Access: Private (via IAM role only)"
echo ""
echo " Run 04_ec2_setup.sh next."
echo "========================================"
