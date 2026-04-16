# JFrog Setup for Enterprise Inference Airgapped Deployment

This folder contains automation scripts to set up JFrog Artifactory as a local mirror for Enterprise Inference (EI) airgapped deployments.

## Overview

Airgapped deployment requires all Docker images, Helm charts, PyPI packages, and binaries to be pre-cached on a local repository server (VM1) before the airgapped deployment VM (VM2) pulls them. JFrog Artifactory serves as this local mirror.

```
┌─────────────────────┐           ┌─────────────────────┐
│  VM1 (internet)     │  LAN      │  VM2 (airgapped)    │
│  JFrog Artifactory  │◄─────────►│  EI Deployment      │
│  :8082              │           │  Kubernetes + vLLM  │
│                     │           │                     │
│  - Docker images    │           │  No internet access │
│  - Helm charts      │           │  All pulls → JFrog  │
│  - PyPI packages    │           └─────────────────────┘
│  - Binaries         │
│  - LLM models       │
└─────────────────────┘
```

---

## Step 1 — Install JFrog Artifactory on VM1

VM1 must have internet access and be reachable from VM2 over LAN.

### Get a Pro Trial License Key

1. Go to `https://jfrog.com/start-free/`
2. Click **14-day free trial** (not Platform Tour)
3. Select **Self-Hosted**
4. Fill in the registration form (company name, phone number with country code)
5. Click **Confirm and Start**
6. Check your email — license key arrives within a few minutes
7. Copy the license key — you will need it during post-install

### Pre-install: Install required tools

```bash
sudo apt update

sudo apt install -y \
  jq \
  curl \
  wget \
  skopeo \
  helm \
  net-tools \
  ca-certificates \
  gnupg \
  lsb-release \
  unzip \
  tar \
  vim \
  software-properties-common \
  python3-pip \
  git
```

Fix inotify limits (required to avoid "Too many open files" errors):

```bash
sudo sysctl fs.inotify.max_user_instances=512
echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### Install JFrog

```bash
# 1. Download the installer (auto-resolves [RELEASE] to latest version)
wget -O jfrog-deb-installer.tar.gz \
  "https://releases.jfrog.io/artifactory/jfrog-prox/org/artifactory/pro/deb/jfrog-platform-trial-prox/[RELEASE]/jfrog-platform-trial-prox-[RELEASE]-deb.tar.gz"

# 2. Extract
tar -xvzf jfrog-deb-installer.tar.gz

# 3. Navigate to directory and run installer
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

**If you cannot access the UI directly** (e.g. VM1 has no browser), set up an SSH tunnel from your local machine:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

Then open `http://localhost:8082` in your local browser.

**Activate the license:**
- Admin → Artifactory License → paste the trial license key → Save

---

## Step 2 — Create JFrog Repositories

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
./jfrog-create-repos.sh \
  --jfrog-url http://<VM1-IP>:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password
```

Verify JFrog is reachable:
```bash
curl -s -u admin:password http://<VM1-IP>:8082/artifactory/api/system/ping
```

**Repositories created:**
- **Docker**: ei-docker-local (local), ei-docker-dockerhub/ecr/ghcr/k8s/quay (remotes), ei-docker-virtual (aggregator)
- **Helm**: ei-helm-local (HelmOCI local), ei-helm-virtual (aggregator)
- **PyPI**: ei-pypi-local, ei-pypi-remote, ei-pypi-virtual (aggregator)
- **Debian**: ei-debian-ubuntu (remote → archive.ubuntu.com), ei-debian-virtual (aggregator)
- **Generic**: ei-generic-binaries, ei-generic-models

---

## Step 3 — Enable Anonymous Access

JFrog's UI toggle "Allow Anonymous Access" sets `buildGlobalBasicReadForAnonymous=true` but does NOT set `enabledForAnonymous`. You must patch the XML config directly:

```bash
# Get current config
curl -su "admin:password" \
  "http://<VM1-IP>:8082/artifactory/api/system/configuration" > /tmp/jfrog-config.xml

# Set enabledForAnonymous to true
sed -i 's/<enabledForAnonymous>false<\/enabledForAnonymous>/<enabledForAnonymous>true<\/enabledForAnonymous>/' \
  /tmp/jfrog-config.xml

# Apply the change
curl -su "admin:password" -X POST \
  "http://<VM1-IP>:8082/artifactory/api/system/configuration" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/jfrog-config.xml
```

Then set anonymous read permissions on all Docker repos (virtual repos cannot be in permission targets — add individual repos):

```bash
python3 -c "
import json
perm = {
  'name': 'anonymous-docker-read',
  'includesPattern': '**',
  'excludesPattern': '',
  'repositories': [
    'ei-docker-local',
    'ei-docker-dockerhub',
    'ei-docker-ecr',
    'ei-docker-ghcr',
    'ei-docker-k8s',
    'ei-docker-quay',
    'ANY REMOTE'
  ],
  'principals': {'users': {'anonymous': ['r']}}
}
open('/tmp/perm.json', 'w').write(json.dumps(perm))
"

curl -su "admin:password" -X PUT \
  "http://<VM1-IP>:8082/artifactory/api/security/permissions/anonymous-docker-read" \
  -H "Content-Type: application/json" \
  -d @/tmp/perm.json
```

---

## Step 4 — Pre-load Assets into JFrog

Run the upload script on VM1. It uses **skopeo** (not docker) to copy images — Docker 29.x forces HTTPS even with `insecure-registries` configured, which breaks HTTP JFrog. Skopeo respects HTTP properly.

```bash
./upload-to-jfrog.sh \
  --jfrog-url http://<VM1-IP>:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password \
  --dockerhub-user <dockerhub-username> \
  --dockerhub-pass <dockerhub-pat> \
  --workdir ~/ei-assets
```

To also upload the LLM model files (requires ~30 GB extra disk):

```bash
./upload-to-jfrog.sh \
  --jfrog-url http://<VM1-IP>:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass password \
  --hf-token hf_xxxxx \
  --dockerhub-user <dockerhub-username> \
  --dockerhub-pass <dockerhub-pat> \
  --workdir ~/ei-assets
```

To run a single step:
```bash
./upload-to-jfrog.sh --step 3a   # Docker images only
./upload-to-jfrog.sh --step 3b   # Helm charts only
./upload-to-jfrog.sh --step 3h --hf-token hf_xxxxx   # LLM model only
```

### How Docker images are uploaded to JFrog

Docker 29.x breaks `docker pull/push` through HTTP registries (forces HTTPS). The upload script uses `skopeo copy` instead:

```bash
# Install skopeo
sudo apt install -y skopeo

# Copy an image from upstream directly into JFrog ei-docker-local
skopeo copy \
  --src-tls-verify=false \
  --dest-tls-verify=false \
  --dest-creds admin:password \
  docker://<upstream-registry>/<image>:<tag> \
  docker://<VM1-IP>:8082/ei-docker-local/<image>:<tag>
```

**Key rules:**
- Always push to `ei-docker-local` (local repo) — **not** `ei-docker-virtual` (virtual repos reject pushes with "Unable to upload into a virtual repository")
- `ei-docker-local` is a member of `ei-docker-virtual`, so images pushed there are served via the virtual repo
- Use `--dest-tls-verify=false` because JFrog runs on HTTP

**Example — copy vLLM CPU image from ECR into JFrog:**
```bash
skopeo copy \
  --src-tls-verify=false \
  --dest-tls-verify=false \
  --dest-creds admin:password \
  docker://public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.10.2 \
  docker://<VM1-IP>:8082/ei-docker-local/q9t5s3a7/vllm-cpu-release-repo:v0.10.2
```

**For very old image tags** (e.g. `busybox:1.28`) that Docker Hub no longer serves via v2 API:
```bash
# Pull a working equivalent via JFrog, retag, push to ei-docker-local
skopeo copy --dest-tls-verify=false --dest-creds admin:password \
  docker://<VM1-IP>:8082/ei-docker-virtual/library/busybox:latest \
  docker://<VM1-IP>:8082/ei-docker-local/library/busybox:1.28
```

**Verify an image is cached in JFrog** (must use Docker Accept headers — plain curl returns 404 even if cached):
```bash
curl -s -u admin:password \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -o /dev/null -w "%{http_code}" \
  "http://<VM1-IP>:8082/v2/ei-docker-virtual/library/nginx/manifests/1.25.2-alpine"
# Must return 200
```

---

## Step 5 — Set JFrog Remote Repos to Offline

After all assets are uploaded, set each remote repo to Offline in the JFrog UI to enforce true airgap (serves cached content only, refuses new internet fetches):

**JFrog UI**: Admin → Repositories → Edit each remote → Advanced → uncheck `Online` → Save

Repos to set Offline:
- ei-docker-dockerhub
- ei-docker-ecr
- ei-docker-ghcr
- ei-docker-k8s
- ei-docker-quay
- ei-debian-ubuntu
- ei-pypi-remote

---

## Step 6 — Configure VM2 for Airgap

Set airgap variables in `core/inventory/inference-config.cfg` on VM2:

```
airgap_enabled=on
jfrog_url=http://<VM1-IP>:8082/artifactory
jfrog_username=admin
jfrog_password=password
```

Then run the deployment:
```bash
./inference-stack-deploy.sh
```

---

## Troubleshooting

### JFrog unreachable from VM1 itself
JFrog only listens on `localhost` — use `http://localhost:8082/artifactory` when running scripts on VM1 directly.

### Image pull returns 404 on JFrog
Image may only have the manifest list cached, not the amd64-specific manifest. Pull by digest explicitly on VM1 to force JFrog to cache the platform-specific layers:
```bash
skopeo copy --dest-tls-verify=false --dest-creds admin:password \
  docker://<upstream>/<image>:<tag> \
  docker://<VM1-IP>:8082/ei-docker-local/<image>:<tag>
```

### `((var++))` exits with code 1 in bash scripts with `set -e`
Arithmetic `((var++))` returns exit code 1 when the result is 0 (first iteration), causing the script to exit under `set -euo pipefail`. Use `var=$((var+1))` instead.
