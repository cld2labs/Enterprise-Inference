# Airgapped Deployment Guide

This document is a continuation of the [JFrog Setup README](../../jfrog-setup/README.md).

It assumes JFrog Artifactory is already installed on VM1, all repositories are created, and all assets (Docker images, Helm charts, PyPI packages, binaries, and the LLM model) have been uploaded. If you have not done that yet, complete the JFrog setup first.

## Architecture

```
VM1 (internet-connected)          VM2 (airgapped)
┌─────────────────────┐           ┌─────────────────────┐
│  JFrog Artifactory  │◄──LAN────►│  EI Deployment      │
│  :8082              │           │  Kubernetes + vLLM  │
│  - Docker images    │           │                     │
│  - Helm charts      │           │  No internet access │
│  - PyPI packages    │           │  All pulls → JFrog  │
│  - Binaries         │           └─────────────────────┘
│  - LLM models       │
└─────────────────────┘
```

---

## Step 1 - Set JFrog Remote Repos to Offline

Once all assets are uploaded, set every remote repo to Offline in the JFrog UI. When a repo is Offline, JFrog serves only what is already cached and refuses to fetch anything new from the internet. This is what enforces the true airgap.

In the JFrog UI: **Administration (gear icon) -> Repositories -> Edit each remote repo -> Advanced tab -> uncheck Online -> Save**

Set these repos to Offline:

- `ei-docker-dockerhub`
- `ei-docker-ecr`
- `ei-docker-ghcr`
- `ei-docker-k8s`
- `ei-docker-quay`
- `ei-pypi-remote`
- `ei-debian-ubuntu`

Leave `ei-hf-remote` Online unless you have also uploaded the model to `ei-generic-models` and plan to serve it from there.

---

## Step 2 - Block Internet on VM2

Before deploying, verify and then block internet access on VM2. All traffic must go through JFrog on VM1.

### Check current internet access

```bash
curl -s --max-time 5 https://google.com && echo "HAS INTERNET" || echo "NO INTERNET"
curl -s --max-time 5 https://huggingface.co && echo "HAS INTERNET" || echo "NO INTERNET"
```

### Block internet (allow only LAN and loopback)

```bash
# Check your SSH client IP first - it must be in one of the allowed ranges below
echo $SSH_CLIENT

# Allow loopback, LAN, and JFrog VM1
sudo iptables -F OUTPUT
sudo iptables -I OUTPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -I OUTPUT 2 -o lo -j ACCEPT
sudo iptables -I OUTPUT 3 -d 127.0.0.0/8 -j ACCEPT
sudo iptables -I OUTPUT 4 -d 10.0.0.0/8 -j ACCEPT
sudo iptables -I OUTPUT 5 -d 100.67.0.0/16 -j ACCEPT   # LAN subnet containing VM1 and VM2
sudo iptables -I OUTPUT 6 -d 100.64.0.0/10 -j ACCEPT   # SSH client subnet - adjust if your client IP differs
sudo iptables -I OUTPUT 7 -d 192.168.0.0/16 -j ACCEPT
sudo iptables -A OUTPUT -j DROP

# Install iptables-persistent so rules survive reboots
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

Adjust the subnet ranges to match your network. The key requirements are:
- VM1 IP must be in an allowed range
- Your SSH client IP must be in an allowed range (or you will be locked out)
- Kubernetes pod and service CIDRs (10.0.0.0/8) must be allowed

### Verify airgap

```bash
curl -s --max-time 5 https://google.com && echo "FAIL - internet still open" || echo "OK - internet blocked"
curl -s --max-time 5 http://<VM1-IP>:8082/artifactory/api/system/ping && echo "OK - JFrog reachable" || echo "FAIL - JFrog unreachable"
```

---

## Step 3 - Copy the Enterprise Inference Repo to VM2

From a machine with access to both the repo and VM2:

```bash
scp -r Enterprise-Inference user@<VM2-IP>:~/
```

Or copy via USB or shared storage if the environment is fully disconnected.

**After copying, strip Windows CRLF line endings** (required if the files were edited on a Windows machine):

```bash
find ~/Enterprise-Inference -name "*.sh" -o -name "*.yml" -o -name "*.yaml" -o -name "*.cfg" | \
  xargs sed -i 's/\r//'
```

---

## Step 4 - Configure `inference-config.cfg`

```bash
vi ~/Enterprise-Inference/core/inventory/inference-config.cfg
```

Set the following values:

```
cluster_url=api.example.com
cert_file=~/certs/cert.pem
key_file=~/certs/key.pem
keycloak_client_id=my-client-id
keycloak_admin_user=your-keycloak-admin-user
keycloak_admin_password=changeme
hugging_face_token=hf_your_token_here
hugging_face_token_falcon3=your_hugging_face_token
models=
cpu_or_gpu=cpu
vault_pass_code=place-holder-123
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_keycloak_apisix=on
deploy_genai_gateway=off
deploy_observability=off
deploy_llm_models=on
deploy_ceph=off
deploy_istio=off
uninstall_ceph=off
deploy_nri_balloon_policy=no

# ---------------------------------------------------------------------------
# Airgap Configuration
# Set airgap_enabled=on to route all pulls through JFrog on VM1.
# ---------------------------------------------------------------------------
airgap_enabled=on
jfrog_url=http://<VM1-IP>:8082/artifactory
jfrog_username=admin
jfrog_password=<your-jfrog-password>
```

Replace `<VM1-IP>` with the actual IP of VM1.

### Apply single-node inventory

```bash
cp ~/Enterprise-Inference/docs/examples/single-node/hosts.yaml \
   ~/Enterprise-Inference/core/inventory/hosts.yaml
```

Then update `ansible_user` to match the deployment user:

```bash
sed -i -E "/^[[:space:]]*master1:/,/^[[:space:]]{2}children:/ \
  s/^([[:space:]]*ansible_user:[[:space:]]*).*/\1$(whoami)/" \
  ~/Enterprise-Inference/core/inventory/hosts.yaml
```

### Generate SSL certificates

```bash
mkdir -p ~/certs
openssl req -x509 -newkey rsa:4096 \
  -keyout ~/certs/key.pem \
  -out ~/certs/cert.pem \
  -days 365 -nodes \
  -subj '/CN=api.example.com'
```

These paths are referenced in `inference-config.cfg` as `cert_file` and `key_file`.

### Add VM2 hosts entry for `api.example.com`

```bash
echo "$(hostname -I | awk '{print $1}') api.example.com" | sudo tee -a /etc/hosts
```

---

## Step 5 - Run the Deployment

```bash
cd ~/Enterprise-Inference
bash inference-stack-deploy.sh
```

The deployment will:
1. Install prerequisites (pip from JFrog PyPI, Ansible collections from JFrog)
2. Download Kubespray from JFrog
3. Deploy Kubernetes via Kubespray (all binaries and images from JFrog)
4. Deploy ingress-nginx, Keycloak, APISIX
5. Deploy vLLM model pods

### Monitor deployment

```bash
# Watch pods come up
kubectl get pods -w

# Check vLLM pod logs (model loading)
kubectl logs <vllm-pod-name> --tail=20 | grep -v "OMP tid"
```

Expected pod states when complete:

```
keycloak-0                    1/1 Running
keycloak-postgresql-0         1/1 Running
vllm-llama-8b-cpu-*           1/1 Running
```

---

## Step 6 - Test Inference

### Generate Keycloak token

```bash
cd ~/Enterprise-Inference/core
. scripts/generate-token.sh
```

### Verify models are available

```bash
curl -s http://api.example.com:32353/Llama-3.1-8B-Instruct-vllmcpu/v1/models \
  -H "Authorization: Bearer $TOKEN" | jq .
```

### Test inference

```bash
curl -k https://${BASE_URL}/Llama-3.1-8B-Instruct-vllmcpu/v1/completions \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "prompt": "What is Deep Learning?",
    "max_tokens": 25,
    "temperature": 0
  }'
```

---

For troubleshooting common failures, see [air-gap-troubleshooting.md](air-gap-troubleshooting.md).
