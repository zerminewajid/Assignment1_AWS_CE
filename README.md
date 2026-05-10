# UniEvent — Cloud-Hosted University Event Management System
### CE 308/408 Cloud Computing · Assignment 1 · GIKI

---

## 📋 Project Overview

**UniEvent** is a cloud-hosted web application that acts as a centralised platform where students can browse university events, register for activities, and upload event-related media. The application is deployed on AWS using a fully fault-tolerant, multi-AZ architecture.

Event data is automatically fetched from the **PredictHQ Events API** (a real, publicly available events API providing structured JSON with title, date, venue, description, and category) and displayed as "University Events" on the platform.

---

## 🏗️ AWS Architecture

```
                        ┌──────────────────────────────────────────────────┐
                        │                    AWS Cloud                     │
                        │                                                  │
   Internet Users       │  ┌─────────────────────────────────────────┐    │
        │               │  │         VPC (10.0.0.0/16)               │    │
        ▼               │  │                                          │    │
  ┌──────────┐          │  │  Public Subnets (10.0.1.0/24, 2.0/24)  │    │
  │ Internet │──────────┼─▶│  ┌─────────────────────────────────┐   │    │
  │ Gateway  │          │  │  │ Application Load Balancer (ALB) │   │    │
  └──────────┘          │  │  └────────────────┬────────────────┘   │    │
                        │  │                   │ forward             │    │
                        │  │  Private Subnets (10.0.11.0/24, 12.0)  │    │
                        │  │  ┌───────────┐  ┌───────────┐          │    │
                        │  │  │  EC2 #1   │  │  EC2 #2   │          │    │
                        │  │  │ (AZ: 1a)  │  │ (AZ: 1b)  │          │    │
                        │  │  │  Flask    │  │  Flask    │          │    │
                        │  │  └─────┬─────┘  └─────┬─────┘          │    │
                        │  │        │               │                │    │
                        │  │        ▼               ▼                │    │
                        │  │  ┌──────────────────────────────────┐   │    │
                        │  │  │     NAT Gateway (Public Subnet)  │   │    │
                        │  │  └──────────────┬───────────────────┘   │    │
                        │  │                 │ (fetch from API)       │    │
                        │  └─────────────────┼───────────────────────┘    │
                        │                    ▼                             │
                        │          ┌──────────────────┐                    │
                        │          │  Amazon S3 Bucket│                    │
                        │          │  (Event Posters) │                    │
                        │          └──────────────────┘                    │
                        └──────────────────────────────────────────────────┘
                                             │
                                             ▼
                                   PredictHQ Events API
                                   (External Events)
```

### AWS Services Used

| Service | Purpose |
|---------|---------|
| **IAM** | EC2 instance role granting S3 access without hardcoded credentials |
| **VPC** | Isolated network with public/private subnets across 2 Availability Zones |
| **EC2** | Application servers running Flask in private subnets (Auto Scaling Group) |
| **S3** | Secure, durable storage for event posters/media |
| **ALB** | Application Load Balancer distributes traffic and provides health checks |
| **NAT Gateway** | Allows private EC2 instances to reach the PredictHQ API |
| **Auto Scaling** | Automatically replaces failed instances; scales out under load |

---

## 📁 Repository Structure

```
Assignment1_AWS_CE/
│
├── app/                         # Flask web application
│   ├── app.py                   # Main application (routes, API fetch, S3 upload)
│   ├── requirements.txt         # Python dependencies
│   ├── .env.example             # Environment variable template
│   └── templates/
│       ├── base.html            # Shared navigation, footer, styles
│       ├── index.html           # Home page with featured events
│       ├── events.html          # Events listing with category filter
│       └── upload.html          # Event poster upload page
│
├── aws/                         # AWS CLI setup scripts (run in order)
│   ├── 01_vpc_setup.sh          # VPC, subnets, IGW, NAT, route tables, SGs
│   ├── 02_iam_setup.sh          # IAM role, inline policy, instance profile
│   ├── 03_s3_setup.sh           # S3 bucket creation and configuration
│   ├── 04_ec2_alb_setup.sh      # Launch Template, ALB, Target Group, ASG
│   └── 99_teardown.sh           # ⚠️ Deletes ALL resources 
│
└── README.md                    # This file — full setup guide
```

---

## 🚀 Step-by-Step Deployment Guide

### Prerequisites

Before starting, ensure you have:
- [ ] An **AWS account** with admin or power-user permissions
- [ ] **AWS CLI v2** installed and configured (`aws configure`)
- [ ] **Python 3.12+** installed locally
- [ ] A free **PredictHQ API key** (instructions below)

---

### Step 1 — Get a PredictHQ API Key (Free)

1. Go to [https://www.predicthq.com/](https://www.predicthq.com/)
2. Click **"Get Started Free"** and sign up (Google sign-in works)
3. Once logged in, go to [https://control.predicthq.com/](https://control.predicthq.com/)
4. Navigate to **API Credentials** and copy your **Access Token**
5. You'll use this as `PREDICTHQ_API_KEY` in your `.env` file

> **Why PredictHQ?** Their Events API provides structured JSON event data including `title`, `start` (date/time), `place_hierarchies` (venue/location), `labels` (description tags), and `category` — matching all assignment requirements. The free tier provides sufficient API calls for this project.

---

### Step 2 — Clone the Repository

```bash
git clone https://github.com/zerminewajid/Assignment1_AWS_CE.git
cd Assignment1_AWS_CE
```

---

### Step 3 — Test Locally First

```bash
cd app

# Copy and fill in environment variables
cp .env.example .env
# Edit .env — add your PredictHQ API key and an S3 bucket name

# Install dependencies
pip install -r requirements.txt

# Run locally
python app.py
```

Open `http://localhost:5000` — you should see the UniEvent homepage with live events fetched from PredictHQ (or demo events if no API key is set yet).

---

### Step 4 — Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     [your IAM user key]
# AWS Secret Access Key: [your IAM user secret]
# Default region:        us-east-1
# Default output format: json

# Verify it works
aws sts get-caller-identity
```

---

### Step 5 — Deploy AWS Infrastructure (Run scripts in order)

```bash
cd aws
chmod +x *.sh
```

#### 5a. VPC & Networking

```bash
./01_vpc_setup.sh
```

Creates: VPC, 2 public subnets (ALB), 2 private subnets (EC2), Internet Gateway, NAT Gateway, route tables, ALB Security Group, App Security Group.

#### 5b. IAM Role & Instance Profile

```bash
./02_iam_setup.sh
```

Creates: IAM role (`unievents-ec2-role`) with trust policy for EC2, inline S3 policy (least privilege), instance profile.

#### 5c. S3 Bucket

```bash
./03_s3_setup.sh
```

Creates: Private S3 bucket, blocks all public access, enables versioning, sets lifecycle policy.

#### 5d. EC2 + Load Balancer + Auto Scaling

```bash
./04_ec2_alb_setup.sh
```

**Before running**, edit inside the script:
- `KEY_NAME` — your EC2 key pair name
- In `USER_DATA`: replace `YOUR_GITHUB_USERNAME`, `YOUR_PREDICTHQ_KEY`, and `REPLACE_WITH_BUCKET_NAME`

Creates: EC2 Launch Template, Application Load Balancer (public subnets), Target Group with `/health` checks, ALB Listener, Auto Scaling Group (min=2, max=4), CPU scaling policy.

---

### Step 6 — Access the Application

The script prints:
```
🌐 Application URL: http://unievents-alb-XXXX.us-east-1.elb.amazonaws.com
```

⏳ Wait **3–5 minutes** for instances to boot, Flask to start, and ALB health checks to pass.

---

### Step 7 — Verify the Architecture

#### Check instances are healthy
```bash
source aws/vpc_ids.env
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

#### Test fault tolerance — terminate one instance
```bash
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
# ASG auto-replaces it. App stays up through the ALB.
```

#### Verify S3 upload
```bash
aws s3 ls s3://${S3_BUCKET_NAME}/posters/
```

#### Health check
```bash
curl http://${ALB_DNS}/health
# {"status": "healthy", "instance": "...", "events_cached": 6}
```

---

## 📡 API Integration — PredictHQ Events API

**API Used:** [PredictHQ Events API](https://docs.predicthq.com/api/events)

### Why PredictHQ?

| Criterion | PredictHQ API |
|-----------|--------------|
| Free tier | ✅ Available |
| Requires API key | ✅ Simple signup |
| JSON format | ✅ Well-structured |
| Event title | ✅ `title` field |
| Date & Time | ✅ `start` field (ISO 8601) |
| Venue/Location | ✅ `place_hierarchies` array |
| Description | ✅ `labels` + `description` fields |
| Category | ✅ `category` field |

### Sample API Call

```
GET https://api.predicthq.com/v1/events/
    ?limit=20
    &sort=start
    &active.gte=2024-11-01
    &category=conferences,festivals,community

Authorization: Bearer YOUR_PREDICTHQ_API_KEY
```

### Sample Response (abbreviated)

```json
{
  "results": [
    {
      "id": "abc123",
      "title": "University Technology Conference",
      "category": "conferences",
      "start": "2024-11-20T09:00:00Z",
      "labels": ["technology", "education", "networking"],
      "place_hierarchies": [["Pakistan", "Khyber Pakhtunkhwa", "Topi"]],
      "country": "PK"
    }
  ]
}
```

### How the App Uses It

1. On startup and every **30 minutes**, `fetch_events_from_api()` calls PredictHQ
2. Events are parsed and stored in `_event_cache` (in-memory)
3. The `/events` route serves cached events — no database needed
4. If the API call fails, **last good cache is preserved** (graceful degradation)
5. If no API key is set, **demo events** are shown automatically

---

## 🔐 Security Design

| Concern | Solution |
|---------|----------|
| No hardcoded credentials | IAM instance role — credentials auto-rotated by AWS |
| EC2 not internet-accessible | EC2 in **private subnets**, no public IP |
| Only ALB reaches EC2 | App SG ingress sources from `ALB_SG` only |
| S3 data not public | All public access blocked; accessed via IAM role |
| SSH restricted | Port 22 limited to VPC CIDR (10.0.0.0/16) only |
| Least privilege | IAM policy scoped to one specific S3 bucket only |

---

## 🌐 Application Routes

| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | Home page with 3 featured events |
| `/events` | GET | All events with category filter |
| `/upload` | GET/POST | Upload event poster to S3 |
| `/health` | GET | ALB health check → `{"status":"healthy"}` |
| `/api/events` | GET | All cached events as JSON |

---

## 🛠️ Local Development

```bash
cd app
pip install -r requirements.txt
cp .env.example .env
# Add your PREDICTHQ_API_KEY (optional — demo data shown without it)
python app.py
# Visit http://localhost:5000
```

---

## 🧹 Cleanup (After Viva)

```bash
cd aws
./99_teardown.sh
```

⚠️ Permanently deletes all AWS resources. Run only after your viva!

---

## 📊 Architecture Justification

**Why private subnets for EC2?** Prevents direct internet access to application servers. All traffic must pass through the ALB, which only forwards legitimate HTTP requests.

**Why Auto Scaling across 2 AZs?** If one Availability Zone fails, instances in the other AZ continue serving traffic. The ASG maintains minimum healthy instances and auto-replaces failures.

**Why NAT Gateway?** Private EC2 instances need outbound internet to call the PredictHQ API, but must not have inbound internet access. NAT Gateway provides exactly this one-way access.

**Why IAM roles instead of access keys?** Eliminates static credentials from code. Temporary credentials are automatically rotated by AWS, with no risk of key leakage.

---

## 👤 Author

**Zermine Wajid (2023786)**  
BS Artificial Intelligence — 3rd Year  
Ghulam Ishaq Khan Institute of Engineering Sciences and Technology  
CE 308/408 Cloud Computing — Assignment 1
