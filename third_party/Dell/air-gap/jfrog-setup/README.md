# JFrog Setup for Enterprise Inference Airgapped Deployment

This guide walks you through setting up JFrog Artifactory on VM1 as a local mirror for
Enterprise Inference airgapped deployments. Once JFrog is set up, VM2 (the airgapped machine)
pulls all Docker images, Helm charts, Python packages, and binaries from JFrog instead of
the internet.

```
┌─────────────────────┐           ┌─────────────────────┐
│  VM1 (internet)     │  LAN      │  VM2 (airgapped)    │
│  JFrog Artifactory  │◄─────────►│  EI Deployment      │
│  :8082              │           │  Kubernetes + vLLM  │
│                     │           │                     │
│  - Docker images    │           │  No internet access │
│  - Helm charts      │           │  All pulls -> JFrog │
│  - Python packages  │           └─────────────────────┘
│  - Binaries         │
│  - LLM models       │
└─────────────────────┘
```

## Scripts in this folder

| Script | Purpose |
|---|---|
| `jfrog-installation.sh` | Installs all required tools and JFrog Artifactory on VM1 |
| `jfrog-setup.sh` | Creates repositories, enables access, and uploads all assets to JFrog |

---

## Prerequisites

Before you start, collect the following. Have all of them ready before running any scripts.

**JFrog Pro Trial License**

A license key is required to activate JFrog. Without it, JFrog will not serve any content.
Get a free 14-day trial key at https://jfrog.com/start-free/

1. Click 14-day free trial (not Platform Tour)
2. Select Self-Hosted
3. Fill in the registration form and click Confirm and Start
4. Check your email. The license key arrives within a few minutes.
5. Copy the key and keep it somewhere handy.

**HuggingFace Token**

Required to download the Meta Llama LLM model (about 30 GB). The model is gated, so you
need to accept the license agreement on HuggingFace before a token will work.

1. Accept the model license at https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct
2. Generate a token at https://huggingface.co/settings/tokens and select Read access.

**Docker Hub Credentials**

Required to pull one image (apache/apisix-ingress-controller) that cannot be fetched
through JFrog remote repos and must be pulled directly from Docker Hub.

Create a free account at https://hub.docker.com and generate a Personal Access Token at
https://hub.docker.com/settings/security. Use the token as your password when prompted.

---

## Step 1 - Install JFrog on VM1

VM1 must have internet access. Run the following on VM1.

First, install git:

```bash
sudo apt install -y git
```

Clone the repo and check out the airgap branch:

```bash
git clone <repo-url> Enterprise-Inference
cd Enterprise-Inference
git checkout ei/airgapped
```

Then run the install script:

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
chmod +x jfrog-installation.sh
sudo ./jfrog-installation.sh
```

During the install, the package manager may show a package configuration prompt. Press Enter
or click OK to accept the defaults and continue.

The script installs these tools: curl, wget, git, jq, skopeo, helm, python3, pip3, ansible.

When the script finishes, JFrog is running at `http://localhost:8082`.

Available options if needed:

```
--jfrog-port PORT   JFrog HTTP port (default: 8082)
--skip-jfrog        Install tools only, skip JFrog installation
```

---

## Step 2 - Open the JFrog UI and Complete Setup

Open a browser on VM1 and go to `http://localhost:8082`.

If VM1 does not have a browser, set up an SSH tunnel from your local machine. Open a new
terminal window (not the one where you are already SSH'd into VM1) and run:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

Leave that terminal open and open `http://localhost:8082` in your local browser.

### First login and setup

When you open JFrog for the first time, it will walk you through a short setup wizard.

**1. Reset the default password**

Log in with the default credentials: admin / password

JFrog will immediately ask you to set a new password. Choose a password and save it. You
will need it when running `jfrog-setup.sh` in the next step.

**2. Activate the license**

JFrog will ask for a license key. Paste the trial license key from your email and click
Activate. JFrog will not work until this is done.

**3. Set the base URL**

JFrog will ask for a base URL. Leave this blank and click Skip unless you have a specific
base URL. This is optional and does not affect the setup.

**4. Configure proxy**

Click Skip. A proxy is only needed if VM1 reaches the internet through a corporate proxy server.

**5. Create repositories**

Click Skip. The `jfrog-setup.sh` script will create all required repositories automatically.

Click Finish to complete the wizard.

---

## Step 3 - Create Repos, Enable Access, and Upload All Assets

Once the license is active, run `jfrog-setup.sh`. This script does everything in one go:
creates all repositories, enables anonymous access, and uploads all EI assets to JFrog.

Make sure you have at least 70 GB of free disk space on VM1 before starting. The LLM model
alone is about 30 GB.

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup

./jfrog-setup.sh \
  --jfrog-url http://localhost:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass <your-password> \
  --dockerhub-user <dockerhub-username> \
  --dockerhub-pass <dockerhub-pat> \
  --hf-token hf_xxxxx
```

This will take a while as it downloads and uploads Docker images, Helm charts, Python
packages, binaries, and the LLM model.

### All available options

```
--jfrog-url URL        JFrog base URL (default: http://localhost:8082/artifactory)
--jfrog-user USER      JFrog username (default: admin)
--jfrog-pass PASS      JFrog password (default: password)
--hf-token TOKEN       HuggingFace token (required for LLM model download)
--dockerhub-user USER  Docker Hub username (required for apisix-ingress-controller)
--dockerhub-pass PASS  Docker Hub password or PAT
--step STEP            Run only one specific step, e.g. --step 3a
--skip STEP            Skip a specific step (can be repeated)
--workdir DIR          Where to download files (default: /tmp/ei-airgap-upload)
--dry-run              Print commands without running them
```

### Run one step at a time

If you want to run or re-run a specific step instead of the full script:

```bash
./jfrog-setup.sh --step 1       # Create repositories only
./jfrog-setup.sh --step 2       # Enable anonymous access only
./jfrog-setup.sh --step 3a      # Docker images only
./jfrog-setup.sh --step 3b      # Helm charts only
./jfrog-setup.sh --step 3c      # PyPI packages only
./jfrog-setup.sh --step 3d      # pip bootstrap wheel only
./jfrog-setup.sh --step 3e      # Ansible collections only
./jfrog-setup.sh --step 3f      # apt .deb files only
./jfrog-setup.sh --step 3g      # Kubernetes binaries only
./jfrog-setup.sh --step 3h --hf-token hf_xxxxx   # LLM model only
./jfrog-setup.sh --step 3i      # Kubespray tarball only
./jfrog-setup.sh --step 4       # Set remote repos to Offline only
```

### What each step does

**Step 1 - Create repositories**

Creates all the JFrog repositories needed for EI. This includes Docker repositories for
each upstream registry (Docker Hub, ECR, GitHub, Kubernetes, Quay), Helm chart repositories,
a PyPI repository, a Debian package repository, and generic repositories for binaries and
the LLM model.

**Step 2 - Enable anonymous access**

Configures JFrog so that VM2 can pull Docker images without providing credentials. The
standard UI toggle for this does not fully work, so this step patches the config directly
via the JFrog API.

**Step 3a - Docker images**

Copies about 40 Docker images from their upstream registries into JFrog. Uses skopeo for
the copy because Docker 29.x has a bug that breaks HTTP registries.

**Step 3b - Helm charts**

Downloads 10 Helm charts (ingress-nginx, langfuse, apisix, keycloak, postgresql, redis,
clickhouse, minio, valkey, nri-resource-policy-balloons) and uploads them to JFrog along
with an index file that JFrog does not generate automatically.

**Step 3c - PyPI packages**

Downloads about 30 Python packages used by the EI deployment playbooks and uploads them
to JFrog so VM2 can install them without internet access.

**Step 3d - pip bootstrap wheel**

Ubuntu disables pip by default, so this step uploads the pip installer itself to JFrog.
The deployment uses it to bootstrap pip on VM2 without needing internet access.

**Step 3e - Ansible collections**

Downloads 4 Ansible collections used by the EI playbooks and uploads them to JFrog.

**Step 3f - apt packages**

Downloads the deb packages for jq and its dependencies and uploads them to JFrog. These
are installed on VM2 directly since apt cannot reach the internet in airgap mode.

**Step 3g - Kubernetes binaries**

Downloads all the binaries that Kubespray needs to set up the Kubernetes cluster
(kubeadm, kubectl, kubelet, containerd, runc, etcd, calico, cni-plugins, crictl, helm,
nerdctl, yq, kubectx, kubens) and uploads them to JFrog.

**Step 3h - LLM model**

Downloads the Meta-Llama-3.1-8B-Instruct model from HuggingFace and uploads all files
to JFrog. Requires a HuggingFace token. Skip this step if you plan to download the model
separately.

**Step 3i - Kubespray tarball**

Downloads the Kubespray repository and packages it as a tarball in JFrog. VM2 uses this
instead of cloning from GitHub since it has no internet access.

**Step 4 - Set remote repos to Offline**

Sets all remote repos to Offline so JFrog only serves cached content and does not try to
fetch anything new from the internet. This is the final step that enforces the true airgap.

---

## Step 4 - Set Remote Repos to Offline

This step runs automatically at the end of `jfrog-setup.sh`. When a repo is set to
Offline, JFrog serves only what is already cached and refuses any new internet fetches.

If you need to run this step on its own:

```bash
./jfrog-setup.sh \
  --jfrog-url http://localhost:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass <your-password> \
  --step 4
```

Repos set to Offline:

- ei-docker-dockerhub
- ei-docker-ecr
- ei-docker-ghcr
- ei-docker-k8s
- ei-docker-quay
- ei-pypi-remote
- ei-debian-ubuntu

---

## Verify What Is in JFrog

To see everything currently stored in JFrog across all repos:

```bash
python3 list-jfrog-assets.py

# With custom URL or credentials
python3 list-jfrog-assets.py \
  --jfrog-url http://localhost:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass <password>
```

---

## Troubleshooting

### JFrog UI not accessible from local machine

JFrog listens on localhost by default. Open a new terminal window (not the one where you
are already SSH'd into VM1) and run:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

Leave that terminal open and open `http://localhost:8082` in your browser.

### Use skopeo to copy Docker images, not docker

Docker 29.x forces HTTPS even when insecure-registries is configured in
`/etc/docker/daemon.json`. Use skopeo instead as it handles HTTP correctly:

```bash
skopeo copy \
  --src-tls-verify=false \
  --dest-tls-verify=false \
  --dest-creds admin:<password> \
  docker://<upstream-registry>/<image>:<tag> \
  docker://<VM1-IP>:8082/ei-docker-local/<image>:<tag>
```

Always push to `ei-docker-local`, not `ei-docker-virtual`. Virtual repos reject pushes.
Images pushed to `ei-docker-local` are automatically served through `ei-docker-virtual`
since local is a member of virtual.

### Verifying an image is cached

A plain curl request returns 404 even when an image is cached in JFrog. You need to
include Docker manifest Accept headers:

```bash
curl -s -u admin:<password> \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -o /dev/null -w "%{http_code}" \
  "http://<VM1-IP>:8082/v2/ei-docker-virtual/library/nginx/manifests/1.25.2-alpine"
```

A response of 200 means the image is properly cached. Anything else means it is not.

### Very old image tags not available via Docker Hub

Docker Hub no longer serves very old tags (like busybox:1.28) through the v2 API, so
JFrog cannot proxy them. The workaround is to pull a newer working tag and push it under
the old tag name:

```bash
skopeo copy \
  --dest-tls-verify=false \
  --dest-creds admin:<password> \
  docker://<VM1-IP>:8082/ei-docker-virtual/library/busybox:latest \
  docker://<VM1-IP>:8082/ei-docker-local/library/busybox:1.28
```

### Anonymous access toggle in the UI does not fully work

The "Allow Anonymous Access" toggle in the JFrog UI only sets one of two required flags.
If VM2 cannot pull images without credentials, patch the config manually:

```bash
curl -su "admin:<password>" \
  "http://localhost:8082/artifactory/api/system/configuration" > /tmp/jfrog-config.xml

sed -i 's/<enabledForAnonymous>false<\/enabledForAnonymous>/<enabledForAnonymous>true<\/enabledForAnonymous>/' \
  /tmp/jfrog-config.xml

curl -su "admin:<password>" -X POST \
  "http://localhost:8082/artifactory/api/system/configuration" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/jfrog-config.xml
```

This is handled automatically by step 2 of `jfrog-setup.sh`.

### Virtual repos cannot be added to permission targets

If you try to add `ei-docker-virtual` to a JFrog permission target you will get an HTTP
400 error. Add the individual local and remote repos instead. Step 2 of `jfrog-setup.sh`
does this correctly.

### Helm index.yaml is not generated automatically

JFrog HelmOCI repos do not auto-generate `index.yaml`. After uploading chart tarballs,
generate and upload the index file manually:

```bash
mkdir ~/helm-index
cp *.tgz ~/helm-index
cd ~/helm-index
helm repo index . --url http://localhost:8082/artifactory/ei-helm-local
curl -u admin:<password> -T index.yaml \
  "http://localhost:8082/artifactory/ei-helm-local/index.yaml"
```

Step 3b of `jfrog-setup.sh` does this automatically.
