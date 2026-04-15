# JFrog Setup for Enterprise Inference Airgapped Deployment

This folder contains automation scripts to set up JFrog Artifactory as a local mirror for Enterprise Inference (EI) airgapped deployments.

## Overview

Airgapped deployment requires all Docker images, Helm charts, PyPI packages, and binaries to be pre-cached on a local repository server (VM1) before the airgapped deployment VM (VM2) pulls them. JFrog Artifactory serves as this local mirror.

```
┌─────────────────────┐           ┌─────────────────────┐
│  VM1 (internet)     │  LAN  │  VM2 (airgapped)    │
│  JFrog Artifactory  │◄─────►│  EI Deployment      │
│  :8082              │           │  Kubernetes + vLLM │
│                     │           │                     │
│  - Docker images    │           │  No internet access │
│  - Helm charts      │           │  All pulls → JFrog  │
│  - PyPI packages    │           └─────────────────────┘
│  - Binaries         │
│  - LLM models       │
└─────────────────────┘
```

## Scripts

### 1. `jfrog-create-repos.sh`
**Purpose**: Creates all required repositories in JFrog Artifactory.

**Repositories Created**:
- **Docker**: ei-docker-local, ei-docker-dockerhub, ei-docker-ecr, ei-docker-ghcr, ei-docker-k8s, ei-docker-quay, ei-docker-virtual (aggregator)
- **Helm**: ei-helm-local (HelmOCI), ei-helm-virtual (aggregator)
- **PyPI**: ei-pypi-local, ei-pypi-remote, ei-pypi-virtual (aggregator)
- **Debian**: ei-debian-ubuntu, ei-debian-virtual (aggregator)
- **Generic**: ei-generic-binaries, ei-generic-models

**Usage**:
```bash
./jfrog-create-repos.sh \
  --jfrog-url http://100.67.152.212:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password
```

**Options**:
```
--jfrog-url URL    JFrog base URL (default: http://100.67.152.212:8082/artifactory)
--jfrog-user USER  JFrog username (default: admin)
--jfrog-pass PASS  JFrog password (default: password)
-h, --help         Show help message
```

**Output**: Lists all created repositories and confirms success.

---



**Usage**:
```bash
# Run all steps (requires ~60GB disk space)
./upload-to-jfrog.sh \
  --jfrog-url http://100.67.152.212:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password \
  --hf-token hf_xxxxx \
  --dockerhub-user myuser \
  --dockerhub-pass mypat


### Prerequisites
- **VM1** (internet-connected): Must have internet access and be reachable from VM2 over LAN
- **Required tools on VM1**: docker, helm, pip3, ansible-galaxy, git, curl, jq (optional)
- **Disk space**: ~60-80GB (for all steps including models)
- **Time**: ~30-60 minutes depending on internet speed and disk I/O

### Step-by-Step Deployment
## Step 1  -  Install JFrog Artifactory on VM1 (internet-connected)

VM1 must have internet access and be reachable from VM2 over LAN.

### Get a Pro Trial License Key

1. Go to `https://jfrog.com/start-free/`
2. Click **14-day free trial** (not Platform Tour)
3. Select **Self-Hosted**
4. Fill in the registration form:
   - Company name
   - Phone number with country code (e.g. `+1 555 123 4567`)
5. Click **Confirm and Start**
6. Check your email - license key arrives within a few minutes
7. Copy the license key from the email - you will need it during post-install

### Pre-install - Fix inotify limits

Required before installation to avoid "Too many open files" errors:

Update package list and install required tools:

```bash
sudo apt update

sudo apt install -y \
  jq \
  curl \
  wget \
  net-tools \
  ca-certificates \
  gnupg \
  lsb-release \
  unzip \
  tar \
  vim \
  software-properties-common
```

Verify jq installation:

```bash
jq --version
```

```bash
sudo sysctl fs.inotify.max_user_instances=512

echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### Install

```bash
# 1. Download the installer (auto-resolves [RELEASE] to latest version)
wget -O jfrog-deb-installer.tar.gz \
  "https://releases.jfrog.io/artifactory/jfrog-prox/org/artifactory/pro/deb/jfrog-platform-trial-prox/[RELEASE]/jfrog-platform-trial-prox-[RELEASE]-deb.tar.gz"

# 2. Extract
tar -xvzf jfrog-deb-installer.tar.gz

# 3. Navigate to Directory and run installer
cd jfrog-platform-trial-pro*
sudo ./install.sh

# 4. Start services
sudo systemctl start artifactory.service
sudo systemctl start xray.service

# 5. Verify both are running
sudo systemctl status artifactory.service
sudo systemctl status xray.service
```

### Post-install

Access the UI at `http://<VM1-IP>:8082`. Default credentials: `admin` / `password` (you will be prompted to change on first login).

**Activate the license:**
- Admin → Artifactory License → paste the trial license key → Save

**Enable anonymous read access** (required so VM2 can pull without credentials for Docker mirrors):
- Admin → Security → Settings → Enable "Allow Anonymous Access"
- Set Read permission on `ei-docker-local` and `ei-docker-virtual` for anonymous users

---

#### 2. **Create JFrog Repositories**
```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
./jfrog-create-repos.sh \
  --jfrog-url http://<VM1-IP>:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password
```

Verify: `curl -s -u admin:password http://<VM1-IP>:8082/artifactory/api/system/ping`

#### 4. **Pre-load Assets into JFrog**
```bash
./upload-to-jfrog.sh \
  --jfrog-url http://<VM1-IP>:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password \
  --hf-token hf_xxxxx \
  --dockerhub-user myuser \
  --dockerhub-pass mypat \
  --workdir ~/ei-assets
```

**Monitor progress**:
- Watch real-time: `tail -f /var/opt/jfrog/artifactory/log/request.log | grep ei-docker`
- Total uploaded: `curl -s -u admin:password http://<VM1-IP>:8082/artifactory/api/docker/ei-docker-virtual/v2/_catalog | jq '.repositories | length'`

#### 5. **Set JFrog Remote Repos to Offline**
In JFrog UI: Admin → Repositories → Edit each remote → Advanced → Set `Online` → `Offline`

This enforces true airgap (serves cached content only, refuses new fetches):
- ei-docker-dockerhub
- ei-docker-ecr  
- ei-docker-ghcr
- ei-docker-k8s
- ei-docker-quay
- ei-debian-ubuntu
- ei-pypi-remote


Set airgap variables:
```
airgap_enabled=on
jfrog_url=http://100.67.152.212:8082/artifactory
jfrog_username=admin
jfrog_password=password
```