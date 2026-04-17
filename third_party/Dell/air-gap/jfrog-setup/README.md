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

### System Requirements

This airgap solution requires two machines. Both machines must be on the same network and
must be able to reach each other over LAN. VM2 pulls all content from VM1 during deployment,
so connectivity between them is required throughout the entire process.

| Requirement | VM1 (JFrog machine) | VM2 (airgapped machine) |
|---|---|---|
| Purpose | Hosts JFrog Artifactory, downloads and stores all assets | Runs the Enterprise Inference stack (Kubernetes + vLLM) |
| Internet access | Required (to download Docker images, models, binaries) | Not required (blocked after initial setup) |
| Disk space | At least 80 GB free. This has been validated for downloading Llama 3.1 8B and Llama 3.2 3B models. If you plan to download additional models, you will need more disk space. | At least 80 GB free (for Kubernetes, container images, and model storage) |
| RAM | At least 8 GB | At least 64 GB (vLLM requires significant memory for CPU inference) |
| CPU | No special requirement (JFrog is a file server) | At least 16 cores recommended |
| Network | Must be reachable from VM2 on port 8082 | Must be reachable from VM1, no internet access after setup |
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| Access | Root or sudo privileges | Root or sudo privileges |

### Credentials required

Before you start, collect the following. Have all of them ready before running any scripts.

**JFrog Pro Trial License**

A license key is required to activate JFrog. Without it, JFrog will not serve any content.
Get a free 14-day trial key at https://jfrog.com/start-free/

1. Click 14-day free trial (not Platform Tour)
2. Select Self-Hosted
3. Fill in the registration form and click Confirm and Start
4. Check your email. JFrog will send you your username, password, and license key within a few minutes.
5. Copy the license key and keep it somewhere handy. You will need all three when completing the setup wizard in Step 2.

**HuggingFace Token**

Required to download the Meta Llama LLM models (Llama 3.1 8B is about 30 GB, Llama 3.2 3B
is about 7 GB). The models are gated, so you need to accept the license agreement on
HuggingFace before a token will work.

1. Accept the Llama 3.1 8B license at https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct
2. Accept the Llama 3.2 3B license at https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct
3. Generate a token at https://huggingface.co/settings/tokens and select Read access.

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
git clone https://github.com/cld2labs/Enterprise-Inference.git Enterprise-Inference
cd Enterprise-Inference
git checkout ei/airgapped
```

Then run the install script:

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
chmod +x jfrog-installation.sh
sudo ./jfrog-installation.sh
```

> During the install, the package manager may show a package configuration prompt. Press
> Enter or click OK to accept the defaults and continue.

The script installs these tools: curl, wget, git, jq, skopeo, helm, python3, pip3, ansible.

When the script finishes, JFrog is running at `http://localhost:8082`.

Available options if needed:

```
--jfrog-port PORT   JFrog HTTP port (default: 8082)
```

---

## Step 2 - Open the JFrog UI and Complete Setup

Open a browser on VM1 and go to `http://localhost:8082`.

If VM1 does not have a browser, set up an SSH tunnel from your local machine. Open a new
terminal window (not the one where you are already SSH'd into VM1) and run:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

> Leave that terminal open. Closing it will drop the tunnel and you will lose access to the
> JFrog UI.

Open `http://localhost:8082` in your local browser.

### First login and setup

When you open JFrog for the first time, it will walk you through a short setup wizard.

**1. Reset the default password**

Log in with the default credentials: admin / password

JFrog will immediately ask you to set a new password. Choose a password and save it. You
will need it when running `jfrog-setup.sh` in the next step.

**2. Activate the license**

JFrog will ask for a license key. Paste the trial license key from your email and click
Activate.

> JFrog will not serve any content until the license is activated. Do not skip this step.

**3. Set the base URL**

JFrog will ask for a base URL. Leave this blank and click Skip unless you have a specific
base URL. This is optional and does not affect the setup.

**4. Configure proxy**

Click Skip. A proxy is only needed if VM1 reaches the internet through a corporate proxy
server.

**5. Create repositories**

Click Skip. The `jfrog-setup.sh` script will create all required repositories automatically.

Click Finish to complete the wizard.

---

## Step 3 - Create Repos, Enable Access, and Upload All Assets

Once the license is active, run `jfrog-setup.sh` to finish the JFrog setup. This is the
main setup script — run it now using the command in the [Run the full setup](#run-the-full-setup)
section below. It handles everything in one go: creates all repositories, enables anonymous
access, uploads all EI assets (Docker images, Helm charts, Python packages, binaries, and
LLM models) to JFrog, and sets all remote repos to Offline at the end to enforce the airgap.

### Run the full setup

Run the command below to start. This will take a while as it downloads and uploads all
assets listed above.

> **Do not use sudo**: Running as root breaks the SSH tunnel and the script will not be able to reach JFrog.
> **sudo password prompt**: During step 3f, the script installs apt packages using dpkg. and will prompt for your sudo password. Enter your system password to continue.
> **Skip LLM models**: The `--hf-token` flag is only needed for the model download steps (3i and 3j). If you do not need the models uploaded to JFrog, add `--skip 3i --skip 3j`to the command and omit `--hf-token`.

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
chmod +x jfrog-setup.sh

./jfrog-setup.sh \
  --jfrog-url http://localhost:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass <your-password> \
  --dockerhub-user <dockerhub-username> \
  --dockerhub-pass <dockerhub-pat> \
  --hf-token <hf-token>
```

### All available options

| Flag | Description |
|---|---|
| `--jfrog-url URL` | JFrog base URL |
| `--jfrog-user USER` | JFrog username |
| `--jfrog-pass PASS` | JFrog password |
| `--hf-token TOKEN` | HuggingFace token (required for LLM model download) |
| `--dockerhub-user USER` | Docker Hub username (required for apisix-ingress-controller) |
| `--dockerhub-pass PASS` | Docker Hub password or PAT |
| `--step STEP` | Run only one specific step, e.g. `--step 3a` |
| `--skip STEP` | Skip a specific step (can be repeated) |
| `--workdir DIR` | Where to download files |
| `--dry-run` | Print commands without running them |

### Run one step at a time

If you want to run or re-run a specific step instead of the full script, use any of
these commands:

| Command | What it does |
|---|---|
| `./jfrog-setup.sh --step 1` | Create all repositories |
| `./jfrog-setup.sh --step 2` | Enable anonymous access |
| `./jfrog-setup.sh --step 3a` | Upload Docker images |
| `./jfrog-setup.sh --step 3b` | Upload Helm charts |
| `./jfrog-setup.sh --step 3c` | Upload PyPI packages |
| `./jfrog-setup.sh --step 3d` | Upload pip bootstrap wheel |
| `./jfrog-setup.sh --step 3e` | Upload Ansible collections |
| `./jfrog-setup.sh --step 3f` | Upload apt .deb packages |
| `./jfrog-setup.sh --step 3g` | Upload Kubernetes binaries |
| `./jfrog-setup.sh --step 3h` | Upload Kubespray tarball |
| `./jfrog-setup.sh --step 3i --hf-token <hf-token>` | Download and upload **Meta-Llama-3.1-8B-Instruct** (~30 GB) |
| `./jfrog-setup.sh --step 3j --hf-token <hf-token>` | Download and upload **Meta-Llama-3.2-3B-Instruct** (~7 GB) |
| `./jfrog-setup.sh --step 4` | Set all remote repos to Offline |

---

### What the script uploads

| Asset type | What gets uploaded |
|---|---|
| Docker images | ~40 images from Docker Hub, ECR, GHCR, registry.k8s.io, Quay |
| Helm charts | 10 charts: ingress-nginx, langfuse, apisix, keycloak, postgresql, redis, clickhouse, minio, valkey, nri-resource-policy-balloons |
| Python packages | ~30 PyPI packages used by the EI deployment playbooks |
| pip bootstrap | pip wheel (needed because Ubuntu disables pip by default) |
| Ansible collections | 4 collections used by the EI playbooks |
| apt packages | jq and its dependencies as .deb files |
| Kubernetes binaries | kubeadm, kubectl, kubelet, containerd, runc, etcd, calico, cni-plugins, crictl, helm, nerdctl, yq, kubectx, kubens |
| Kubespray | Full Kubespray repo as a tarball (replaces git clone on VM2) |
| LLM models | Meta-Llama-3.1-8B-Instruct (~30 GB) and Meta-Llama-3.2-3B-Instruct (~7 GB) |


VM1 is now ready to act as the sole package mirror for VM2. No further changes are needed
on VM1.

> **Next step**: Follow the Enterprise Inference airgap deployment guide to configure VM2
> and run the EI deployment stack against JFrog.

---

<details>
<summary>What each step does (click to expand)</summary>

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

**Step 3h - Kubespray tarball**

Downloads the Kubespray repository and packages it as a tarball in JFrog. VM2 uses this
instead of cloning from GitHub since it has no internet access.

**Step 3i - Meta-Llama-3.1-8B-Instruct model**

Downloads the Meta-Llama-3.1-8B-Instruct model (about 30 GB) from HuggingFace and uploads
all files to JFrog. Requires a HuggingFace token. Skip this step if you plan to download
the model separately.

**Step 3j - Meta-Llama-3.2-3B-Instruct model**

Downloads the Meta-Llama-3.2-3B-Instruct model (about 7 GB) from HuggingFace and uploads
all files to JFrog. Requires the same HuggingFace token as step 3i. Skip this step if you
do not need this model.

**Step 4 - Set remote repos to Offline**

Sets all remote repos to Offline so JFrog only serves cached content and does not try to
fetch anything new from the internet. This is the final step that enforces the true airgap.

</details>

---

## Troubleshooting

<details>
<summary>Click to expand</summary>

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

> Always push to `ei-docker-local`, not `ei-docker-virtual`. Virtual repos reject pushes.
> Images pushed to `ei-docker-local` are automatically served through `ei-docker-virtual`
> since local is a member of virtual.

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

> This is handled automatically by step 2 of `jfrog-setup.sh`. Only run this manually if
> VM2 is unable to pull images without credentials after the full setup.

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

> Step 3b of `jfrog-setup.sh` does this automatically. Only run this manually if you are
> uploading charts outside of the script.

</details>
