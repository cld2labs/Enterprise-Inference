# JFrog Setup for Enterprise Inference Airgapped Deployment

This folder contains scripts to set up JFrog Artifactory on VM1 as a local mirror for
Enterprise Inference airgapped deployments. VM2 (the airgapped machine) pulls all Docker
images, Helm charts, PyPI packages, and binaries from JFrog instead of the internet.

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

## Scripts in this folder

| Script | Purpose |
|---|---|
| `install-vm1.sh` | Installs prerequisites and JFrog Artifactory on VM1 |
| `jfrog-setup-all.sh` | Creates repos, enables anonymous access, uploads all assets |

---

## Step 1 - Get a JFrog Pro Trial License

JFrog will not serve content until a license is activated. Get a free 14-day trial key before running any scripts.

1. Go to https://jfrog.com/start-free/
2. Click **14-day free trial** (not Platform Tour)
3. Select **Self-Hosted**
4. Fill in the registration form and click **Confirm and Start**
5. Check your email -- the license key arrives within a few minutes
6. Copy the key and keep it handy -- you will paste it into the JFrog UI after install

---

## Step 2 - Install JFrog on VM1

Run `install-vm1.sh` on VM1. It installs all required tools, downloads JFrog, starts the service, and waits until it is ready. VM1 must have internet access.

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup
sudo ./install-vm1.sh
```

Available options:

```
--jfrog-port PORT   JFrog HTTP port (default: 8082)
--skip-jfrog        Install tools only, skip JFrog installation
```

The script installs these tools: curl, wget, git, jq, skopeo, helm, python3, pip3, ansible.

It also sets `fs.inotify.max_user_instances=512` in `/etc/sysctl.conf` -- this is required to
prevent "Too many open files" errors when JFrog handles many connections.

When the script finishes, JFrog is running at `http://localhost:8082`.

### Access the JFrog UI

Open a browser on VM1 and go to `http://localhost:8082`.

If VM1 has no browser, set up an SSH tunnel from your local machine:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

Then open `http://localhost:8082` in your local browser.

Default login: admin / password. You will be prompted to change the password on first login.

### Activate the license

1. Log in to the JFrog UI
2. Click the gear icon (Administration) in the left sidebar
3. Go to General -> Licenses
4. Paste the trial license key and click Save

The direct URL is: `http://localhost:8082/ui/admin/configuration/general/licenses`

JFrog will not cache or serve any content until this is done.

---

## Step 3 - Create Repos, Enable Access, Upload All Assets

Once the license is active, run `jfrog-setup-all.sh`. This script does everything in one go:
creates all repositories, enables anonymous access, and uploads all EI assets to JFrog.

Before running, get a HuggingFace token with access to the Meta Llama model at
https://huggingface.co/settings/tokens. The script needs this to download the LLM model
(~30 GB). Make sure you have enough disk space on VM1 before starting.

```bash
cd ~/Enterprise-Inference/third_party/Dell/air-gap/jfrog-setup

./jfrog-setup-all.sh \
  --jfrog-url http://localhost:8082/artifactory \
  --jfrog-user admin \
  --jfrog-pass <your-password> \
  --dockerhub-user <dockerhub-username> \
  --dockerhub-pass <dockerhub-pat> \
  --hf-token hf_xxxxx
```

Docker Hub credentials are required to pull `apache/apisix-ingress-controller`. If you skip
them, that image will be skipped and you can push it manually later.

### All available options

```
--jfrog-url URL        JFrog base URL (default: http://localhost:8082/artifactory)
--jfrog-user USER      JFrog username (default: admin)
--jfrog-pass PASS      JFrog password (default: password)
--hf-token TOKEN       HuggingFace token (only needed for step 3h)
--dockerhub-user USER  Docker Hub username (needed for apisix-ingress-controller)
--dockerhub-pass PASS  Docker Hub password or PAT
--step STEP            Run only one specific step, e.g. --step 3a
--skip STEP            Skip a specific step (can be repeated)
--workdir DIR          Where to download files (default: /tmp/ei-airgap-upload)
--dry-run              Print commands without running them
```

### Run one step at a time>

> Note: If you have already run the above script you can skip this
If you want to run or re-run a specific step:

```bash
./jfrog-setup-all.sh --step 1       # Create repositories only
./jfrog-setup-all.sh --step 2       # Enable anonymous access only
./jfrog-setup-all.sh --step 3a      # Docker images only
./jfrog-setup-all.sh --step 3b      # Helm charts only
./jfrog-setup-all.sh --step 3c      # PyPI packages only
./jfrog-setup-all.sh --step 3d      # pip bootstrap wheel only
./jfrog-setup-all.sh --step 3e      # Ansible collections only
./jfrog-setup-all.sh --step 3f      # apt .deb files only
./jfrog-setup-all.sh --step 3g      # Kubernetes binaries only
./jfrog-setup-all.sh --step 3h --hf-token hf_xxxxx   # LLM model only
./jfrog-setup-all.sh --step 3i      # Kubespray tarball only
```

### What each step does

**Step 1 - Create repositories**

Creates all 19 JFrog repositories needed for EI:

Docker repos:
- `ei-docker-local` -- local repo where images are pushed directly
- `ei-docker-dockerhub` -- remote proxy for registry-1.docker.io
- `ei-docker-ecr` -- remote proxy for public.ecr.aws
- `ei-docker-ghcr` -- remote proxy for ghcr.io
- `ei-docker-k8s` -- remote proxy for registry.k8s.io
- `ei-docker-quay` -- remote proxy for quay.io
- `ei-docker-virtual` -- virtual repo that aggregates all of the above

Helm repos:
- `ei-helm-local` -- local repo where chart tarballs are uploaded
- `ei-helm-ingress-nginx` -- remote proxy for kubernetes.github.io/ingress-nginx
- `ei-helm-langfuse` -- remote proxy for langfuse.github.io/langfuse-k8s
- `ei-helm-virtual` -- virtual repo that aggregates all of the above

PyPI repos:
- `ei-pypi-local` -- local repo where wheels are uploaded
- `ei-pypi-remote` -- remote proxy for pypi.org
- `ei-pypi-virtual` -- virtual repo that aggregates both

Debian repos:
- `ei-debian-ubuntu` -- remote proxy for archive.ubuntu.com/ubuntu
- `ei-debian-virtual` -- virtual repo that aggregates above

Other repos:
- `ei-hf-remote` -- remote proxy for huggingface.co
- `ei-generic-binaries` -- local repo for kubectl, helm, kubespray, binaries
- `ei-generic-models` -- local repo for LLM model files

**Step 2 - Enable anonymous access**

The JFrog UI toggle "Allow Anonymous Access" does not fully enable anonymous access -- it
only sets one of two required flags. This step patches the JFrog XML config directly to set
`enabledForAnonymous=true`, then grants anonymous read permissions on all Docker repos via
the REST API. This is required so VM2 can pull images without credentials.

**Step 3a - Docker images**

Copies about 40 Docker images from upstream registries into `ei-docker-local` using skopeo.
Uses skopeo instead of docker pull/push because Docker 29.x forces HTTPS even when
insecure-registries is configured, which breaks HTTP JFrog. Skopeo handles HTTP correctly.

Images pulled from:
- public.ecr.aws -- vLLM CPU, bitnami/minio
- ghcr.io -- TGI, TEI, LiteLLM, NRI plugins
- docker.io -- langfuse, bitnami, apisix, nginx, ubuntu, openvino, kubernetes-ui
- registry.k8s.io -- ingress-nginx, kube components, pause, etcd, coredns, calico
- quay.io -- calico node, CNI, kube-controllers, pod2daemon

**Step 3b - Helm charts**

Pulls 10 Helm charts and uploads them as tarballs to `ei-helm-local`:
ingress-nginx 4.12.2, langfuse 1.5.1, apisix 2.8.1, keycloak 22.1.0, postgresql 16.7.4,
redis 21.1.3, clickhouse 8.0.5, minio 14.10.5, valkey 2.2.4, nri-resource-policy-balloons v0.12.2.

Also generates and uploads `index.yaml`. JFrog HelmOCI repos do not auto-generate this file
so it must be created with `helm repo index` and uploaded manually.

**Step 3c - PyPI packages**

Downloads about 30 Python wheels and uploads them to `ei-pypi-local`:
ansible, kubernetes SDK, jinja2, cryptography, requests, pyyaml, netaddr, and all their
dependencies. These are used by the EI deployment playbooks on VM2.

**Step 3d - pip bootstrap wheel**

Downloads the pip wheel itself and uploads it as `ei-generic-binaries/pip.whl`. This is
needed because Ubuntu disables ensurepip, so pip cannot be bootstrapped the normal way
in an airgapped environment.

**Step 3e - Ansible collections**

Downloads and uploads 4 Ansible collections to `ei-generic-binaries/ansible-collections/`:
kubernetes.core 6.3.0, community.general 12.5.0, ansible.posix, community.kubernetes 2.0.1.

**Step 3f - apt .deb files**

Downloads the deb packages for jq (jq, libjq1, libonig5) and uploads them to
`ei-generic-binaries/apt-debs/`. These are installed on VM2 via dpkg since apt cannot
reach the internet.

**Step 3g - Kubernetes binaries**

Downloads all binaries that Kubespray needs during cluster setup and uploads them to
`ei-generic-binaries/` with the same path structure as their original download URLs.
Includes: kubeadm, kubectl, kubelet, containerd, runc, etcd, calico, cni-plugins, crictl,
helm, nerdctl, yq, kubectx, kubens.

**Step 3h - LLM model (optional)**

Downloads Meta-Llama-3.1-8B-Instruct from HuggingFace and uploads all files to
`ei-generic-models/Meta-Llama-3.1-8B-Instruct/`. Requires a HuggingFace token with
access to the Meta Llama model. Skip this step if you will download the model separately.

**Step 3i - Kubespray tarball**

Clones the kubespray repository at tag v2.27.0, tars it, and uploads to
`ei-generic-binaries/kubespray.tar.gz`. This is used instead of a git clone on VM2
since VM2 has no internet access.

---

## Step 4 - Set Remote Repos to Offline

After all assets are uploaded, set the remote repos to Offline in the JFrog UI. When a
repo is Offline, JFrog serves only what is already cached and refuses to fetch anything
new from the internet. This is what enforces the true airgap.

In the JFrog UI: Admin -> Repositories -> Edit each remote repo -> Advanced tab ->
uncheck **Online** -> Save

Repos to set Offline:
- ei-docker-dockerhub
- ei-docker-ecr
- ei-docker-ghcr
- ei-docker-k8s
- ei-docker-quay
- ei-pypi-remote
- ei-debian-ubuntu

---

## Verify What Is in JFrog

To see everything currently stored across all repos:

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

JFrog listens on localhost by default. Set up an SSH tunnel:

```bash
ssh -L 8082:localhost:8082 user@<VM1-IP> -N
```

Then open `http://localhost:8082` in your browser.

### Always use skopeo to copy Docker images, not docker

Docker 29.x forces HTTPS even when `insecure-registries` is set in `/etc/docker/daemon.json`.
Use skopeo instead -- it handles HTTP correctly:

```bash
skopeo copy \
  --src-tls-verify=false \
  --dest-tls-verify=false \
  --dest-creds admin:<password> \
  docker://<upstream-registry>/<image>:<tag> \
  docker://<VM1-IP>:8082/ei-docker-local/<image>:<tag>
```

Always push to `ei-docker-local`, not `ei-docker-virtual`. Virtual repos reject pushes.
Since `ei-docker-local` is a member of `ei-docker-virtual`, images pushed to local are
automatically served through the virtual repo.

### Verifying an image is cached

Plain curl returns 404 even when an image is cached in JFrog. You must include Docker
manifest Accept headers:

```bash
curl -s -u admin:<password> \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -o /dev/null -w "%{http_code}" \
  "http://<VM1-IP>:8082/v2/ei-docker-virtual/library/nginx/manifests/1.25.2-alpine"
```

A response of 200 means the image is properly cached. Anything else means it is not.

### Very old image tags not available via Docker Hub

Docker Hub no longer serves very old tags (like busybox:1.28) via the v2 API so JFrog
remote repos cannot proxy them. The workaround is to pull a working tag and push it under
the old tag name:

```bash
skopeo copy \
  --dest-tls-verify=false \
  --dest-creds admin:<password> \
  docker://<VM1-IP>:8082/ei-docker-virtual/library/busybox:latest \
  docker://<VM1-IP>:8082/ei-docker-local/library/busybox:1.28
```

### Anonymous access UI toggle does not fully work

The "Allow Anonymous Access" toggle in the JFrog UI sets `buildGlobalBasicReadForAnonymous`
but does not set `enabledForAnonymous`. If VM2 cannot pull images without credentials, patch
the config manually:

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

This is handled automatically by step 2 of `jfrog-setup-all.sh`.

### Virtual repos cannot be in permission targets

If you try to add `ei-docker-virtual` to a JFrog permission target you will get HTTP 400.
Add the individual local and remote repos instead. Step 2 of `jfrog-setup-all.sh` does
this correctly.

### Helm index.yaml is not generated automatically

JFrog HelmOCI repos do not auto-generate `index.yaml`. After uploading chart tarballs,
generate and upload the index file:

```bash
mkdir ~/helm-index
cp *.tgz ~/helm-index
cd ~/helm-index
helm repo index . --url http://localhost:8082/artifactory/ei-helm-local
curl -u admin:<password> -T index.yaml \
  "http://localhost:8082/artifactory/ei-helm-local/index.yaml"
```

Step 3b of `jfrog-setup-all.sh` does this automatically.
