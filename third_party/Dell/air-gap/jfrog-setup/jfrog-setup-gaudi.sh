#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# jfrog-setup-gaudi.sh
#
# One-shot script that sets up JFrog Artifactory for EI airgapped Gaudi deployment.
# Covers all base infrastructure (Kubernetes, ingress, keycloak, GenAI Gateway) plus
# all Gaudi-specific artifacts (vLLM-Gaudi, TGI-Gaudi, TEI-Gaudi, Habana AI Operator,
# metric-exporter, kube-prometheus-stack, Habana runtime packages).
#
#   Step 1  - Create all required repositories (base + Gaudi-specific)
#   Step 2  - Enable anonymous access + set permission targets
#   Step 3a - Docker images (base infrastructure + Gaudi inference images)
#   Step 3b - Helm charts (base + habana-ai-operator + kube-prometheus-stack)
#   Step 3c - PyPI packages
#   Step 3d - pip bootstrap wheel
#   Step 3e - Ansible collections
#   Step 3f - apt .deb files (base Kubespray packages + Habana runtime packages)
#   Step 3g - Kubernetes / Kubespray binaries
#   Step 3h - Kubespray tarball
#   Step 3k - Habana binaries (installer script + device-plugin manifest)
#   Step 3i - Meta-Llama-3.1-8B-Instruct model (optional, requires HuggingFace token)
#   Step 3j - Meta-Llama-3.2-3B-Instruct model (optional, requires HuggingFace token)
#   Step 4  - Set all remote repos to Offline
#
# Run this script on VM1 (internet-connected machine with JFrog installed).
# vault.habana.ai requires Habana account credentials (--habana-user / --habana-pass).
#
# Usage:
#   ./jfrog-setup-gaudi.sh [OPTIONS]
#
# Options:
#   --jfrog-url URL        JFrog base URL (default: http://localhost:8082/artifactory)
#   --jfrog-user USER      JFrog username (default: admin)
#   --jfrog-pass PASS      JFrog password (default: password)
#   --habana-user USER     vault.habana.ai username (required for operator chart + metric-exporter image)
#   --habana-pass PASS     vault.habana.ai password
#   --hf-token TOKEN       HuggingFace token (required for steps 3i and 3j)
#   --dockerhub-user USER  Docker Hub username (required for apisix-ingress-controller)
#   --dockerhub-pass PASS  Docker Hub password / PAT
#   --gaudi-operator VER   Habana AI Operator chart version (default: 1.22.0-740)
#   --step STEP            Run only a specific step (e.g. --step 1, --step 3a)
#   --skip STEP            Skip a specific step (repeatable)
#   --workdir DIR          Working directory for downloads (default: /tmp/ei-airgap-gaudi-upload)
#   --dry-run              Print commands without executing them
#   -h, --help             Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
JFROG_URL="${JFROG_URL:-http://localhost:8082/artifactory}"
JFROG_USER="${JFROG_USER:-admin}"
JFROG_PASS="${JFROG_PASS:-password}"
HABANA_USER="${HABANA_USER:-}"
HABANA_PASS="${HABANA_PASS:-}"
HF_TOKEN="${HF_TOKEN:-}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_PASS="${DOCKERHUB_PASS:-}"
GAUDI_OPERATOR_VERSION="1.22.0-740"
ONLY_STEP=""
SKIP_STEPS=()
WORKDIR="/tmp/ei-airgap-gaudi-upload"
DRY_RUN=false

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step_hdr(){ echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --jfrog-url)         JFROG_URL="$2";            shift 2 ;;
    --jfrog-user)        JFROG_USER="$2";           shift 2 ;;
    --jfrog-pass)        JFROG_PASS="$2";           shift 2 ;;
    --habana-user)       HABANA_USER="$2";          shift 2 ;;
    --habana-pass)       HABANA_PASS="$2";          shift 2 ;;
    --hf-token)          HF_TOKEN="$2";             shift 2 ;;
    --dockerhub-user)    DOCKERHUB_USER="$2";       shift 2 ;;
    --dockerhub-pass)    DOCKERHUB_PASS="$2";       shift 2 ;;
    --gaudi-operator)    GAUDI_OPERATOR_VERSION="$2"; shift 2 ;;
    --step)              ONLY_STEP="$2";            shift 2 ;;
    --skip)              SKIP_STEPS+=("$2");        shift 2 ;;
    --workdir)           WORKDIR="$2";              shift 2 ;;
    --dry-run)           DRY_RUN=true;              shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# Derived
JFROG_CREDS="${JFROG_USER}:${JFROG_PASS}"
JFROG_HOST="${JFROG_URL#http://}"; JFROG_HOST="${JFROG_HOST#https://}"; JFROG_HOST="${JFROG_HOST%%/*}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run() {
  if $DRY_RUN; then echo "[DRY-RUN] $*"; else "$@"; fi
}

should_run() {
  local s="$1"
  [[ -z "$ONLY_STEP" || "$ONLY_STEP" == "$s" ]] || return 1
  for skip in "${SKIP_STEPS[@]:-}"; do [[ "$skip" == "$s" ]] && return 1; done
  return 0
}

create_repo() {
  local name="$1" payload="$2"
  info "Creating repo: $name"
  local http_code resp
  http_code=$(curl -su "$JFROG_CREDS" -X PUT "$JFROG_URL/api/repositories/$name" \
    -H "Content-Type: application/json" -d "$payload" \
    -o /tmp/jfrog_repo_resp.txt -w "%{http_code}")
  resp=$(cat /tmp/jfrog_repo_resp.txt)
  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    success "$name created (HTTP $http_code)"
  elif echo "$resp" | grep -qi "already exists"; then
    success "$name already exists — skipping"
  else
    error "$name failed (HTTP $http_code): $resp"
  fi
}

jfrog_upload() {
  local file="$1" dest="$2"
  info "Uploading $(basename "$file") -> $dest"
  run curl -fsSL -u "$JFROG_CREDS" -T "$file" "$JFROG_URL/$dest"
}

# Pull an image through a JFrog remote repo (temporarily set Online).
# Caches manifest list (original digest) + all amd64 blobs via skopeo.
#   $1 = JFrog remote repo name (e.g. ei-docker-k8s)
#   $2 = image path without registry prefix (e.g. ingress-nginx/kube-webhook-certgen)
#   $3 = tag (e.g. v1.5.3)
precache_via_remote() {
  local remote_repo="$1" image_path="$2" tag="$3"
  info "Pre-caching $image_path:$tag via $remote_repo remote..."

  curl -su "$JFROG_CREDS" -X POST "$JFROG_URL/api/repositories/$remote_repo" \
    -H "Content-Type: application/json" -d '{"offline":false}' > /dev/null 2>&1

  local http_code
  http_code=$(curl -s -u "$JFROG_CREDS" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    -o /dev/null -w "%{http_code}" \
    "${JFROG_URL%/artifactory}/v2/$remote_repo/$image_path/manifests/$tag")

  local tmpdir
  tmpdir=$(mktemp -d)
  skopeo copy \
    --src-tls-verify=false \
    --src-creds "$JFROG_CREDS" \
    --override-arch amd64 --override-os linux \
    "docker://${JFROG_HOST}/${remote_repo}/${image_path}:${tag}" \
    "dir:${tmpdir}" 2>&1 | sed 's/^/    /' || warn "skopeo blob pull returned non-zero for $image_path:$tag"
  rm -rf "$tmpdir"

  curl -su "$JFROG_CREDS" -X POST "$JFROG_URL/api/repositories/$remote_repo" \
    -H "Content-Type: application/json" -d '{"offline":true}' > /dev/null 2>&1

  if [[ "$http_code" == "200" ]]; then
    success "$image_path:$tag cached (manifest list + amd64 blobs)"
  else
    warn "$image_path:$tag — manifest list HTTP $http_code from $remote_repo"
  fi
}

check_prereqs() {
  local missing=()
  for cmd in curl skopeo helm pip3 ansible-galaxy git python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    success "All prerequisites installed"
    return 0
  fi
  error "Missing required tools: ${missing[*]}"
  error "Run install-vm1.sh first to install all prerequisites:"
  error "  sudo ./install-vm1.sh"
  exit 1
}

# ---------------------------------------------------------------------------
# Step 1 — Create Repositories
# ---------------------------------------------------------------------------
step_1() {
  step_hdr "Step 1 - Create JFrog Repositories"

  info "Checking JFrog connectivity..."
  if ! curl -su "$JFROG_CREDS" "$JFROG_URL/api/system/ping" | grep -q "OK"; then
    error "Cannot reach JFrog at $JFROG_URL — check URL, credentials and that Artifactory is running"
    exit 1
  fi
  success "JFrog reachable"

  echo "── Docker Repositories ──────────────────────────────────────"
  create_repo "ei-docker-local" \
    '{"rclass":"local","packageType":"docker"}'
  create_repo "ei-docker-dockerhub" \
    '{"rclass":"remote","packageType":"docker","url":"https://registry-1.docker.io"}'
  create_repo "ei-docker-ecr" \
    '{"rclass":"remote","packageType":"docker","url":"https://public.ecr.aws"}'
  create_repo "ei-docker-ghcr" \
    '{"rclass":"remote","packageType":"docker","url":"https://ghcr.io"}'
  create_repo "ei-docker-k8s" \
    '{"rclass":"remote","packageType":"docker","url":"https://registry.k8s.io"}'
  create_repo "ei-docker-quay" \
    '{"rclass":"remote","packageType":"docker","url":"https://quay.io"}'

  # Habana vault registry — requires Habana account credentials
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    create_repo "ei-docker-vault-habana" \
      "{\"rclass\":\"remote\",\"packageType\":\"docker\",\"url\":\"https://vault.habana.ai\",\"username\":\"${HABANA_USER}\",\"password\":\"${HABANA_PASS}\"}"
  else
    create_repo "ei-docker-vault-habana" \
      '{"rclass":"remote","packageType":"docker","url":"https://vault.habana.ai"}'
    warn "ei-docker-vault-habana created without credentials — set Habana credentials in JFrog UI:"
    warn "  JFrog UI → Repositories → ei-docker-vault-habana → Edit → enter Habana username/password"
  fi

  create_repo "ei-docker-virtual" \
    '{"rclass":"virtual","packageType":"docker","repositories":["ei-docker-local","ei-docker-dockerhub","ei-docker-ecr","ei-docker-ghcr","ei-docker-k8s","ei-docker-quay","ei-docker-vault-habana"]}'

  echo "── Helm Repositories ────────────────────────────────────────"
  create_repo "ei-helm-local" \
    '{"rclass":"local","packageType":"helmoci"}'
  create_repo "ei-helm-ingress-nginx" \
    '{"rclass":"remote","packageType":"helmoci","url":"https://kubernetes.github.io/ingress-nginx"}'
  create_repo "ei-helm-langfuse" \
    '{"rclass":"remote","packageType":"helmoci","url":"https://langfuse.github.io/langfuse-k8s"}'
  create_repo "ei-helm-prometheus" \
    '{"rclass":"remote","packageType":"helmoci","url":"https://prometheus-community.github.io/helm-charts"}'

  # Gaudi helm repo (vault.habana.ai) — requires Habana credentials
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    create_repo "ei-helm-gaudi" \
      "{\"rclass\":\"remote\",\"packageType\":\"helmoci\",\"url\":\"https://vault.habana.ai/artifactory/api/helm/gaudi-helm\",\"username\":\"${HABANA_USER}\",\"password\":\"${HABANA_PASS}\"}"
  else
    create_repo "ei-helm-gaudi" \
      '{"rclass":"remote","packageType":"helmoci","url":"https://vault.habana.ai/artifactory/api/helm/gaudi-helm"}'
    warn "ei-helm-gaudi created without credentials — set Habana credentials in JFrog UI"
  fi

  create_repo "ei-helm-virtual" \
    '{"rclass":"virtual","packageType":"helmoci","repositories":["ei-helm-local","ei-helm-ingress-nginx","ei-helm-langfuse","ei-helm-prometheus","ei-helm-gaudi"]}'

  echo "── PyPI Repositories ────────────────────────────────────────"
  create_repo "ei-pypi-local" \
    '{"rclass":"local","packageType":"pypi"}'
  create_repo "ei-pypi-remote" \
    '{"rclass":"remote","packageType":"pypi","url":"https://pypi.org"}'
  create_repo "ei-pypi-virtual" \
    '{"rclass":"virtual","packageType":"pypi","repositories":["ei-pypi-local","ei-pypi-remote"]}'

  echo "── Debian Repositories ──────────────────────────────────────"
  create_repo "ei-debian-ubuntu" \
    '{"rclass":"remote","packageType":"debian","url":"http://archive.ubuntu.com/ubuntu"}'
  create_repo "ei-debian-virtual" \
    '{"rclass":"virtual","packageType":"debian","repositories":["ei-debian-ubuntu"]}'

  echo "── HuggingFace Repositories ─────────────────────────────────"
  create_repo "ei-hf-remote" \
    '{"rclass":"remote","packageType":"huggingfaceml","url":"https://huggingface.co"}'

  echo "── Generic Repositories ─────────────────────────────────────"
  create_repo "ei-generic-binaries" \
    '{"rclass":"local","packageType":"generic"}'
  create_repo "ei-generic-models" \
    '{"rclass":"local","packageType":"generic"}'

  success "Step 1 complete — all repositories created"
}

# ---------------------------------------------------------------------------
# Step 2 — Enable Anonymous Access + Permissions
# ---------------------------------------------------------------------------
step_2() {
  step_hdr "Step 2 - Enable Anonymous Access"

  info "Getting admin Bearer token (scope=member-of-groups:*) ..."
  local bearer_token access_http
  bearer_token=$(curl -su "$JFROG_CREDS" -X POST \
    "$JFROG_URL/api/security/token" \
    -d "username=${JFROG_USER}&scope=member-of-groups:*&expires_in=3600" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

  if [[ -n "$bearer_token" ]]; then
    info "Enabling anonymous access via Access API (/access/api/v1/config) ..."
    access_http=$(curl -s -X PATCH \
      "http://${JFROG_HOST}/access/api/v1/config" \
      -H "Authorization: Bearer $bearer_token" \
      -H "Content-Type: application/json" \
      -d '{"security":{"allow-anonymous-access":true}}' \
      -o /tmp/jfrog-access-resp.txt -w "%{http_code}")
    if [[ "$access_http" == "200" || "$access_http" == "201" || "$access_http" == "204" ]]; then
      success "Anonymous access enabled via Access API (HTTP $access_http)"
    else
      warn "Access API returned HTTP $access_http (token audience mismatch — expected jfac@...)"
      warn "Enable anonymous access manually:"
      warn "  Browser: http://${JFROG_HOST}/ui → Admin → Security → Settings → Allow Anonymous Access → ON"
    fi
  else
    warn "Could not obtain Bearer token — enable anonymous access manually via JFrog UI"
  fi

  local docker_repos='["ei-docker-local","ei-docker-dockerhub","ei-docker-ecr","ei-docker-ghcr","ei-docker-k8s","ei-docker-quay","ei-docker-vault-habana","ANY REMOTE"]'
  local perm_name perm_http perm_resp
  for perm_name in anonymous-docker anonymous-user; do
    info "Setting permission target: $perm_name ..."
    python3 -c "
import json
perm = {
  'name': '${perm_name}',
  'includesPattern': '**',
  'excludesPattern': '',
  'repositories': ['ei-docker-local','ei-docker-dockerhub','ei-docker-ecr','ei-docker-ghcr','ei-docker-k8s','ei-docker-quay','ei-docker-vault-habana','ANY REMOTE'],
  'principals': {'users': {'anonymous': ['r']}}
}
print(json.dumps(perm))
" > /tmp/jfrog-perm.json
    perm_http=$(curl -su "$JFROG_CREDS" -X PUT \
      "$JFROG_URL/api/security/permissions/$perm_name" \
      -H "Content-Type: application/json" \
      -d @/tmp/jfrog-perm.json \
      -o /tmp/jfrog-perm-resp.txt -w "%{http_code}")
    perm_resp=$(cat /tmp/jfrog-perm-resp.txt)
    if [[ "$perm_http" == "200" || "$perm_http" == "201" ]]; then
      success "$perm_name permissions set (HTTP $perm_http)"
    else
      error "$perm_name permission PUT returned HTTP $perm_http: $perm_resp"
    fi
  done

  success "Step 2 complete — anonymous access enabled"
}

# ---------------------------------------------------------------------------
# Step 3a — Docker Images (via skopeo)
# ---------------------------------------------------------------------------
step_3a() {
  step_hdr "3a - Docker Images"
  local dest_repo="ei-docker-local"
  local -a skopeo_dest_flags=(--dest-tls-verify=false --dest-creds "$JFROG_CREDS")
  local -a skopeo_base=(--src-tls-verify=false --override-arch amd64 --override-os linux)

  # Format: "source_image|dest_path_in_ei-docker-local"
  local images=(
    # ── ECR ──────────────────────────────────────────────────────────────────
    "public.ecr.aws/bitnami/minio:2024.11.7-debian-12-r0|bitnami/minio:2024.11.7-debian-12-r0"

    # ── GHCR ─────────────────────────────────────────────────────────────────
    "ghcr.io/huggingface/text-generation-inference:2.4.0-intel-cpu|huggingface/text-generation-inference:2.4.0-intel-cpu"
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.7|huggingface/text-embeddings-inference:cpu-1.7"
    "ghcr.io/berriai/litellm-non_root:main-v1.75.8-stable|berriai/litellm-non_root:main-v1.75.8-stable"
    "ghcr.io/containers/nri-plugins/nri-resource-policy-balloons:v0.12.2|containers/nri-plugins/nri-resource-policy-balloons:v0.12.2"
    "ghcr.io/containers/nri-plugins/nri-config-manager:v0.12.2|containers/nri-plugins/nri-config-manager:v0.12.2"

    # ── GHCR: Gaudi inference images ─────────────────────────────────────────
    # tgi-gaudi uses tag "latest" in gaudi-values.yaml — pin to a specific tag
    # before airgap deployment to avoid drift. Update tag here if upgrading TGI.
    "ghcr.io/huggingface/tgi-gaudi:latest|huggingface/tgi-gaudi:latest"
    # TEI and TEI-Rerank both use hpu-1.7 (core/helm-charts/tei/gaudi-values.yaml
    # and core/helm-charts/teirerank/gaudi-values.yaml)
    "ghcr.io/huggingface/text-embeddings-inference:hpu-1.7|huggingface/text-embeddings-inference:hpu-1.7"

    # ── Docker Hub ────────────────────────────────────────────────────────────
    # Gaudi LLM serving image (core/helm-charts/vllm/gaudi-values.yaml and gaudi3-values.yaml)
    "docker.io/opea/vllm-gaudi:1.22.0|opea/vllm-gaudi:1.22.0"

    "docker.io/bitnami/minio:2024.12.18|bitnami/minio:2024.12.18"           # Langfuse minio chart (14.10.5)
    "docker.io/langfuse/langfuse:3.106.1|langfuse/langfuse:3.106.1"
    "docker.io/langfuse/langfuse-worker:3.106.1|langfuse/langfuse-worker:3.106.1"
    "docker.io/bitnamilegacy/keycloak:25.0.2-debian-12-r2|bitnamilegacy/keycloak:25.0.2-debian-12-r2"
    "docker.io/bitnamilegacy/postgresql:16.3.0-debian-12-r23|bitnamilegacy/postgresql:16.3.0-debian-12-r23"
    "docker.io/bitnamilegacy/postgresql:17.5.0-debian-12-r0|bitnamilegacy/postgresql:17.5.0-debian-12-r0"
    "docker.io/bitnamilegacy/redis:8.0.1-debian-12-r0|bitnamilegacy/redis:8.0.1-debian-12-r0"
    "docker.io/bitnamilegacy/clickhouse:25.2.1-debian-12-r0|bitnamilegacy/clickhouse:25.2.1-debian-12-r0"
    "docker.io/bitnamilegacy/valkey:8.0.2-debian-12-r2|bitnamilegacy/valkey:8.0.2-debian-12-r2"
    "docker.io/bitnamilegacy/zookeeper:3.9.3-debian-12-r8|bitnamilegacy/zookeeper:3.9.3-debian-12-r8"
    "docker.io/bitnamilegacy/os-shell:12-debian-12-r48|bitnamilegacy/os-shell:12-debian-12-r48"
    "docker.io/bitnamilegacy/etcd:3.5.10-debian-11-r2|bitnamilegacy/etcd:3.5.10-debian-11-r2"
    "docker.io/apache/apisix:3.9.1-debian|apache/apisix:3.9.1-debian"
    "docker.io/library/nginx:1.25.2-alpine|library/nginx:1.25.2-alpine"
    "docker.io/library/ubuntu:22.04|library/ubuntu:22.04"
    "docker.io/rancher/local-path-provisioner:v0.0.24|rancher/local-path-provisioner:v0.0.24"
    "docker.io/library/busybox:latest|library/busybox:1.28"   # genai-gateway init container — 1.28 manifest not in Hub v2 API, copy latest as 1.28
    "docker.io/library/busybox:latest|library/busybox:latest" # local-path-provisioner helper
    "docker.io/curlimages/curl:latest|curlimages/curl:latest" # model registration job
    "docker.io/openvino/model_server:2025.4|openvino/model_server:2025.4"

    # ── registry.k8s.io ───────────────────────────────────────────────────────
    # Dest path must NOT include registry.k8s.io/ prefix — override_path=true in
    # containerd mirror config appends the image path as-is after /v2/ei-docker-virtual
    "registry.k8s.io/ingress-nginx/controller:v1.12.2|ingress-nginx/controller:v1.12.2"
    # kube-webhook-certgen handled via precache_via_remote (skopeo fails on in-toto attestation layers)
    "registry.k8s.io/pause:3.9|pause:3.9"
    "registry.k8s.io/pause:3.10|pause:3.10"
    "registry.k8s.io/etcd:3.5.12-0|etcd:3.5.12-0"
    "registry.k8s.io/kube-apiserver:v1.30.4|kube-apiserver:v1.30.4"
    "registry.k8s.io/kube-controller-manager:v1.30.4|kube-controller-manager:v1.30.4"
    "registry.k8s.io/kube-scheduler:v1.30.4|kube-scheduler:v1.30.4"
    "registry.k8s.io/kube-proxy:v1.30.4|kube-proxy:v1.30.4"
    "registry.k8s.io/coredns/coredns:v1.11.1|coredns/coredns:v1.11.1"
    "registry.k8s.io/coredns/coredns:v1.11.3|coredns/coredns:v1.11.3"
    "registry.k8s.io/dns/k8s-dns-node-cache:1.22.28|dns/k8s-dns-node-cache:1.22.28"
    "registry.k8s.io/cpa/cluster-proportional-autoscaler:v1.8.8|cpa/cluster-proportional-autoscaler:v1.8.8"

    # ── quay.io ───────────────────────────────────────────────────────────────
    "quay.io/calico/node:v3.28.1|calico/node:v3.28.1"
    "quay.io/calico/cni:v3.28.1|calico/cni:v3.28.1"
    "quay.io/calico/kube-controllers:v3.28.1|calico/kube-controllers:v3.28.1"
    "quay.io/calico/pod2daemon-flexvol:v3.28.1|calico/pod2daemon-flexvol:v3.28.1"
    "quay.io/calico/node:v3.29.1|calico/node:v3.29.1"
    "quay.io/calico/cni:v3.29.1|calico/cni:v3.29.1"
    "quay.io/calico/kube-controllers:v3.29.1|calico/kube-controllers:v3.29.1"
    "quay.io/calico/pod2daemon-flexvol:v3.29.1|calico/pod2daemon-flexvol:v3.29.1"
  )

  local copied=0 failed=0 fail_list=()
  for entry in "${images[@]}"; do
    local src="${entry%%|*}"
    local dest_path="${entry##*|}"
    info "Copying $src -> $dest_repo/$dest_path"

    local dest_image="${dest_path%:*}" dest_tag="${dest_path##*:}"
    local existing_code
    existing_code=$(curl -s -u "$JFROG_CREDS" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
      -o /dev/null -w "%{http_code}" \
      "http://${JFROG_HOST}/v2/${dest_repo}/${dest_image}/manifests/${dest_tag}")
    if [[ "$existing_code" == "200" ]]; then
      info "Already in JFrog — skipping: $dest_repo/$dest_path"
      copied=$((copied+1))
      continue
    fi

    local -a src_cred_flags=()
    if [[ "$src" == docker.io/* ]] && [[ -n "$DOCKERHUB_USER" && -n "$DOCKERHUB_PASS" ]]; then
      src_cred_flags+=(--src-creds "$DOCKERHUB_USER:$DOCKERHUB_PASS")
    fi

    if run skopeo copy "${skopeo_base[@]}" "${src_cred_flags[@]}" "${skopeo_dest_flags[@]}" \
        "docker://$src" "docker://$JFROG_HOST/$dest_repo/$dest_path"; then
      copied=$((copied+1))
    else
      warn "Failed: $src"
      failed=$((failed+1))
      fail_list+=("$src")
    fi
  done

  # apisix-ingress-controller — requires Docker Hub credentials
  if [[ -n "$DOCKERHUB_USER" && -n "$DOCKERHUB_PASS" ]]; then
    local apisix_ic_code
    apisix_ic_code=$(curl -s -u "$JFROG_CREDS" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      -o /dev/null -w "%{http_code}" \
      "http://${JFROG_HOST}/v2/${dest_repo}/apache/apisix-ingress-controller/manifests/1.8.0")
    if [[ "$apisix_ic_code" == "200" ]]; then
      info "Already in JFrog — skipping: $dest_repo/apache/apisix-ingress-controller:1.8.0"
      copied=$((copied+1))
    else
      info "Copying apache/apisix-ingress-controller:1.8.0 from Docker Hub..."
      if run skopeo copy "${skopeo_base[@]}" \
          --src-creds "$DOCKERHUB_USER:$DOCKERHUB_PASS" \
          "${skopeo_dest_flags[@]}" \
          "docker://docker.io/apache/apisix-ingress-controller:1.8.0" \
          "docker://$JFROG_HOST/$dest_repo/apache/apisix-ingress-controller:1.8.0"; then
        copied=$((copied+1))
      else
        warn "Failed: apisix-ingress-controller:1.8.0"
        failed=$((failed+1))
      fi
    fi
  else
    warn "Skipping apisix-ingress-controller:1.8.0 — pass --dockerhub-user and --dockerhub-pass"
  fi

  # vault.habana.ai metric exporter — requires Habana credentials
  # Image: vault.habana.ai/gaudi-metric-exporter/metric-exporter:1.20.1-97
  # (from core/helm-charts/observability/habana-exporter/habana-metrics.yml)
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    local metric_code
    metric_code=$(curl -s -u "$JFROG_CREDS" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      -o /dev/null -w "%{http_code}" \
      "http://${JFROG_HOST}/v2/${dest_repo}/gaudi-metric-exporter/metric-exporter/manifests/1.20.1-97")
    if [[ "$metric_code" == "200" ]]; then
      info "Already in JFrog — skipping: metric-exporter:1.20.1-97"
      copied=$((copied+1))
    else
      info "Copying vault.habana.ai/gaudi-metric-exporter/metric-exporter:1.20.1-97 ..."
      if run skopeo copy "${skopeo_base[@]}" \
          --src-creds "$HABANA_USER:$HABANA_PASS" \
          "${skopeo_dest_flags[@]}" \
          "docker://vault.habana.ai/gaudi-metric-exporter/metric-exporter:1.20.1-97" \
          "docker://$JFROG_HOST/$dest_repo/gaudi-metric-exporter/metric-exporter:1.20.1-97"; then
        copied=$((copied+1))
      else
        warn "Failed: metric-exporter:1.20.1-97"
        failed=$((failed+1))
        fail_list+=("vault.habana.ai/gaudi-metric-exporter/metric-exporter:1.20.1-97")
      fi
    fi
  else
    warn "Skipping metric-exporter:1.20.1-97 — pass --habana-user and --habana-pass"
    warn "  To copy manually after obtaining credentials:"
    warn "  skopeo copy --src-creds <user>:<pass> --dest-tls-verify=false --dest-creds $JFROG_CREDS \\"
    warn "    docker://vault.habana.ai/gaudi-metric-exporter/metric-exporter:1.20.1-97 \\"
    warn "    docker://$JFROG_HOST/$dest_repo/gaudi-metric-exporter/metric-exporter:1.20.1-97"
  fi

  success "3a complete: copied=$copied  failed=$failed"
  if [[ $failed -gt 0 ]]; then
    warn "Failed images:"; for img in "${fail_list[@]}"; do warn "  $img"; done
  fi

  # kube-webhook-certgen via remote (skopeo fails on in-toto attestation layers)
  precache_via_remote "ei-docker-k8s" "ingress-nginx/kube-webhook-certgen" "v1.5.3"

  # Pre-cache observability stack images extracted from kube-prometheus-stack chart
  precache_observability_images
}

# Pre-cache all images used by kube-prometheus-stack by rendering the chart
# with helm template and extracting every image reference.
precache_observability_images() {
  info "Pre-caching kube-prometheus-stack images (chart v72.5.1)..."

  local obsdir="$WORKDIR/obs-precache"
  mkdir -p "$obsdir"

  # Pull kube-prometheus-stack chart tarball without uploading (already done in 3b)
  if [[ ! -f "$obsdir/kube-prometheus-stack-72.5.1.tgz" ]]; then
    run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    run helm repo update prometheus-community
    run helm pull prometheus-community/kube-prometheus-stack --version 72.5.1 --destination "$obsdir"
  fi

  local chart_tgz="$obsdir/kube-prometheus-stack-72.5.1.tgz"
  if [[ ! -f "$chart_tgz" ]]; then
    warn "kube-prometheus-stack tarball not found — skipping observability image pre-cache"
    return 0
  fi

  # Render all manifests and extract unique image references
  info "Extracting images from helm template output..."
  local image_list
  image_list=$(helm template obs-pre "$chart_tgz" 2>/dev/null \
    | grep -oE 'image: "[^"]+"' \
    | sed 's/image: "//;s/"//' \
    | sort -u || true)

  # Also catch unquoted image: entries
  image_list+=$'\n'$(helm template obs-pre "$chart_tgz" 2>/dev/null \
    | grep -oE 'image: [^" ][^ ]+' \
    | sed 's/image: //' \
    | sort -u || true)

  if [[ -z "$image_list" ]]; then
    warn "No images extracted from kube-prometheus-stack — skipping observability pre-cache"
    return 0
  fi

  local obs_copied=0 obs_failed=0
  while IFS= read -r img; do
    [[ -z "$img" || "$img" == "null" ]] && continue

    # Determine JFrog remote repo based on registry prefix
    local remote_repo src_img dest_path
    if [[ "$img" == quay.io/* ]]; then
      remote_repo="ei-docker-quay"
      dest_path="${img#quay.io/}"
    elif [[ "$img" == registry.k8s.io/* ]]; then
      remote_repo="ei-docker-k8s"
      dest_path="${img#registry.k8s.io/}"
    elif [[ "$img" == docker.io/* || "$img" != */* || "$img" == *:* && "$img" != */*:* ]]; then
      remote_repo="ei-docker-dockerhub"
      dest_path="${img#docker.io/}"
    elif [[ "$img" == ghcr.io/* ]]; then
      remote_repo="ei-docker-ghcr"
      dest_path="${img#ghcr.io/}"
    else
      remote_repo="ei-docker-dockerhub"
      dest_path="$img"
    fi

    local img_name="${dest_path%:*}" img_tag="${dest_path##*:}"
    [[ "$img_name" == "$dest_path" ]] && img_tag="latest"

    local check_code
    check_code=$(curl -s -u "$JFROG_CREDS" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
      -o /dev/null -w "%{http_code}" \
      "http://${JFROG_HOST}/v2/ei-docker-local/${img_name}/manifests/${img_tag}")

    if [[ "$check_code" == "200" ]]; then
      info "Already cached — skipping: $img"
      obs_copied=$((obs_copied+1))
      continue
    fi

    info "Pre-caching observability image: $img via $remote_repo"
    local tmpdir
    tmpdir=$(mktemp -d)

    curl -su "$JFROG_CREDS" -X POST "$JFROG_URL/api/repositories/$remote_repo" \
      -H "Content-Type: application/json" -d '{"offline":false}' > /dev/null 2>&1

    if skopeo copy \
        --src-tls-verify=false --src-creds "$JFROG_CREDS" \
        --override-arch amd64 --override-os linux \
        "docker://${JFROG_HOST}/${remote_repo}/${dest_path}" \
        "dir:${tmpdir}" 2>&1 | sed 's/^/    /'; then
      obs_copied=$((obs_copied+1))
    else
      warn "Could not pre-cache: $img"
      obs_failed=$((obs_failed+1))
    fi

    curl -su "$JFROG_CREDS" -X POST "$JFROG_URL/api/repositories/$remote_repo" \
      -H "Content-Type: application/json" -d '{"offline":true}' > /dev/null 2>&1

    rm -rf "$tmpdir"
  done <<< "$image_list"

  success "Observability images: cached=$obs_copied failed=$obs_failed"
}

# ---------------------------------------------------------------------------
# Step 3b — Helm Charts
# ---------------------------------------------------------------------------
step_3b() {
  step_hdr "3b - Helm Charts"
  local helmdir="$WORKDIR/helm-charts"
  mkdir -p "$helmdir"
  cd "$helmdir"

  if echo "$JFROG_URL" | grep -qE "localhost|127\.0\.0\.1"; then
    error "JFROG_URL contains localhost — index.yaml would have URLs VM2 cannot reach."
    error "Re-run with: --jfrog-url http://<VM1-IP>:8082/artifactory"
    return 1
  fi

  # Base infrastructure charts
  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  run helm repo add langfuse https://langfuse.github.io/langfuse-k8s
  run helm repo add apisix https://charts.apiseven.com
  run helm repo add nri-plugins https://containers.github.io/nri-plugins
  run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  run helm repo update

  run helm pull ingress-nginx/ingress-nginx --version 4.12.2     --destination .
  run helm pull langfuse/langfuse           --version 1.5.1       --destination .
  run helm pull apisix/apisix               --version 2.8.1       --destination .
  run helm pull nri-plugins/nri-resource-policy-balloons --version v0.12.2 --destination .

  # Observability stack — kube-prometheus-stack (deploy-observability.yml default: 72.5.1)
  run helm pull prometheus-community/kube-prometheus-stack --version 72.5.1 --destination .

  # Bitnami OCI charts (GenAI Gateway + Keycloak dependencies)
  run helm pull oci://registry-1.docker.io/bitnamicharts/keycloak   --version 22.1.0  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 16.7.4  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/redis      --version 21.1.3  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/clickhouse --version 8.0.5   --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/minio      --version 14.10.5 --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/valkey     --version 2.2.4   --destination .

  # Habana AI Operator chart from vault.habana.ai
  # Version matches gaudi2_operator / gaudi3_operator in inference-metadata.cfg
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    info "Pulling habana-ai-operator chart (version: $GAUDI_OPERATOR_VERSION) from vault.habana.ai ..."
    run helm repo add gaudi-helm \
      https://vault.habana.ai/artifactory/api/helm/gaudi-helm \
      --username "$HABANA_USER" --password "$HABANA_PASS" --force-update
    run helm repo update gaudi-helm
    run helm pull gaudi-helm/habana-ai-operator --version "$GAUDI_OPERATOR_VERSION" --destination .
  else
    warn "Skipping habana-ai-operator chart pull — pass --habana-user and --habana-pass"
    warn "  To pull manually:"
    warn "  helm repo add gaudi-helm https://vault.habana.ai/artifactory/api/helm/gaudi-helm \\"
    warn "    --username <user> --password <pass>"
    warn "  helm pull gaudi-helm/habana-ai-operator --version $GAUDI_OPERATOR_VERSION --destination ."
  fi

  # Upload all pulled charts to JFrog ei-helm-local
  for chart in *.tgz; do
    [[ -f "$chart" ]] || continue
    jfrog_upload "$chart" "ei-helm-local/$chart"
  done

  # Generate and upload index.yaml — JFrog HelmOCI repos do not auto-generate it
  run helm repo index . --url "$JFROG_URL/ei-helm-local"
  jfrog_upload "index.yaml" "ei-helm-local/index.yaml"

  success "3b complete"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Step 3c — PyPI Packages
# ---------------------------------------------------------------------------
step_3c() {
  step_hdr "3c - PyPI Packages"
  local wheelsdir="$WORKDIR/wheels"
  mkdir -p "$wheelsdir"

  run pip3 download \
    ansible==9.13.0 ansible-core==2.16.18 \
    jinja2 jmespath==1.0.1 jsonschema==4.23.0 jsonschema-specifications \
    netaddr==1.3.0 kubernetes==35.0.0 pyyaml==6.0.3 \
    cryptography==44.0.0 requests oauthlib requests-oauthlib urllib3 \
    certifi charset-normalizer idna packaging typing-extensions \
    six python-dateutil attrs rpds-py referencing resolvelib \
    durationpy websocket-client cffi pycparser markupsafe \
    -d "$wheelsdir"

  run pip3 download cryptography==46.0.7 -d "$wheelsdir"

  for pkg in "$wheelsdir"/*.whl "$wheelsdir"/*.tar.gz; do
    [[ -f "$pkg" ]] || continue
    jfrog_upload "$pkg" "ei-pypi-local/$(basename "$pkg")"
  done

  success "3c complete"
}

# ---------------------------------------------------------------------------
# Step 3d — pip Bootstrap Wheel
# ---------------------------------------------------------------------------
step_3d() {
  step_hdr "3d - pip Bootstrap Wheel"
  local pipdir="$WORKDIR/pip-dl"
  mkdir -p "$pipdir"

  run pip3 download pip --no-deps -d "$pipdir"

  local whl
  whl=$(ls "$pipdir"/pip-*.whl 2>/dev/null | head -1)
  if [[ -z "$whl" ]]; then
    error "pip wheel not found in $pipdir"
    return 1
  fi

  jfrog_upload "$whl" "ei-generic-binaries/pip.whl"
  success "3d complete"
}

# ---------------------------------------------------------------------------
# Step 3e — Ansible Collections
# ---------------------------------------------------------------------------
step_3e() {
  step_hdr "3e - Ansible Collections"
  local colldir="$WORKDIR/ansible-collections"
  mkdir -p "$colldir"

  run ansible-galaxy collection download \
    kubernetes.core:6.3.0 \
    community.general:12.5.0 \
    ansible.posix \
    -p "$colldir"

  local kube_core_tgz community_general_tgz ansible_posix_tgz
  kube_core_tgz=$(ls "$colldir"/kubernetes-core-*.tar.gz 2>/dev/null | head -1)
  community_general_tgz=$(ls "$colldir"/community-general-*.tar.gz 2>/dev/null | head -1)
  ansible_posix_tgz=$(ls "$colldir"/ansible-posix-*.tar.gz 2>/dev/null | head -1)

  if [[ -n "$kube_core_tgz" ]]; then
    jfrog_upload "$kube_core_tgz" "ei-generic-binaries/ansible-collections/kubernetes-core-6.3.0.tar.gz"
    jfrog_upload "$kube_core_tgz" "ei-generic-binaries/ansible-collections/kubernetes-core-latest.tar.gz"
  else
    warn "kubernetes.core tarball not found — skipping"
  fi

  if [[ -n "$community_general_tgz" ]]; then
    jfrog_upload "$community_general_tgz" "ei-generic-binaries/ansible-collections/community-general-12.5.0.tar.gz"
    jfrog_upload "$community_general_tgz" "ei-generic-binaries/ansible-collections/community-general-latest.tar.gz"
  else
    warn "community.general tarball not found — skipping"
  fi

  if [[ -n "$ansible_posix_tgz" ]]; then
    jfrog_upload "$ansible_posix_tgz" "ei-generic-binaries/ansible-collections/ansible-posix-latest.tar.gz"
  else
    warn "ansible.posix tarball not found — skipping"
  fi

  run ansible-galaxy collection download community.kubernetes:2.0.1 -p "$colldir" || true
  local community_kubernetes_tgz
  community_kubernetes_tgz=$(ls "$colldir"/community-kubernetes-*.tar.gz 2>/dev/null | head -1)
  if [[ -n "$community_kubernetes_tgz" ]]; then
    jfrog_upload "$community_kubernetes_tgz" "ei-generic-binaries/ansible-collections/community-kubernetes-2.0.1.tar.gz"
  else
    warn "community.kubernetes tarball not found — skipping"
  fi

  success "3e complete"
}

# ---------------------------------------------------------------------------
# Step 3f — apt .deb Files
#   Part 1: jq .deb files for inference-tools role (dpkg path)
#   Part 2: Pre-cache Kubespray apt packages in JFrog Debian remote
#   Part 3: Download Habana runtime .deb packages
#           habanalabs-container-runtime=1.18.0-524 (deploy-habana-ai-operator.yml)
#           habanalabs-firmware-odm=1.18.0-524      (gaudi-firmware-driver-updater.sh)
# ---------------------------------------------------------------------------
step_3f() {
  step_hdr "3f - apt .deb Files (base + Habana runtime)"
  local debdir="$WORKDIR/apt-debs"
  mkdir -p "$debdir"

  # ── Part 1: jq via dpkg path ─────────────────────────────────────────────
  info "Downloading jq, libjq1, libonig5..."
  cd "$debdir"
  sudo apt-get update -qq 2>/dev/null || true
  if ! run sudo apt-get download jq libjq1 libonig5; then
    warn "apt-get download for jq/libjq1/libonig5 failed — debs not uploaded to JFrog"
    warn "Upload manually: sudo apt-get download jq libjq1 libonig5 && curl -u $JFROG_CREDS -T <deb> $JFROG_URL/ei-generic-binaries/apt-debs/<deb>"
  fi
  for deb in *.deb; do
    [[ -f "$deb" ]] || continue
    jfrog_upload "$deb" "ei-generic-binaries/apt-debs/$deb"
  done
  cd - >/dev/null

  # ── Part 2: Kubespray apt packages via JFrog Debian remote ───────────────
  info "Pre-caching Kubespray apt packages in JFrog..."
  local http_code
  http_code=$(curl -su "$JFROG_CREDS" -X POST \
    "$JFROG_URL/api/repositories/ei-debian-ubuntu" \
    -H "Content-Type: application/json" \
    -d '{"offline":false}' \
    -o /dev/null -w "%{http_code}")
  if [[ "$http_code" != "200" ]]; then
    warn "Could not set ei-debian-ubuntu Online (HTTP $http_code) — skipping Kubespray apt pre-cache"
  else
    local jfrog_src="http://${JFROG_CREDS}@${JFROG_HOST}/artifactory/ei-debian-virtual"
    local jfrog_list="/etc/apt/sources.list.d/jfrog-precache.list"
    echo "deb [trusted=yes] $jfrog_src jammy main restricted universe multiverse" \
      | sudo tee "$jfrog_list" > /dev/null
    echo "deb [trusted=yes] $jfrog_src jammy-updates main restricted universe multiverse" \
      | sudo tee -a "$jfrog_list" > /dev/null
    sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak

    if run sudo apt-get update; then
      sudo rm -f /var/cache/apt/archives/unzip*.deb \
                 /var/cache/apt/archives/conntrack*.deb \
                 /var/cache/apt/archives/socat*.deb \
                 /var/cache/apt/archives/ipset*.deb \
                 /var/cache/apt/archives/ebtables*.deb \
                 /var/cache/apt/archives/nfs-common*.deb \
                 /var/cache/apt/archives/apt-transport-https*.deb \
                 /var/cache/apt/archives/ipvsadm*.deb
      run sudo apt-get install --download-only -y \
        conntrack socat ipset ebtables nfs-common apt-transport-https ipvsadm \
        python3-pip \
        || warn "Some Kubespray packages may not have been cached"
      run sudo apt-get install --download-only --reinstall -y unzip \
        || warn "unzip may not have been cached"
    else
      warn "apt-get update through JFrog failed"
    fi

    sudo mv /etc/apt/sources.list.bak /etc/apt/sources.list
    sudo rm -f "$jfrog_list"
    curl -su "$JFROG_CREDS" -X POST \
      "$JFROG_URL/api/repositories/ei-debian-ubuntu" \
      -H "Content-Type: application/json" \
      -d '{"offline":true}' > /dev/null 2>&1
    info "ei-debian-ubuntu set back to Offline"
  fi

  # ── Part 3: Habana runtime packages ──────────────────────────────────────
  # habanalabs-container-runtime and habanalabs-firmware-odm are served from
  # the Habana APT repository (configured by habanalabs-installer.sh).
  # In airgap mode these must be pre-downloaded and uploaded to JFrog.
  #
  # Version: 1.18.0-524
  #   - habanalabs-container-runtime=1.18.0-524 (deploy-habana-ai-operator.yml line 89)
  #   - habanalabs-firmware-odm=1.18.0-524      (gaudi-firmware-driver-updater.sh line 117)
  info "Downloading Habana runtime .deb packages (version 1.18.0-524)..."
  info "NOTE: Habana packages require the Habana APT repo to be configured."
  info "      If not already set up, run: bash habanalabs-installer.sh install --type base -y"
  info "      This configures /etc/apt/sources.list.d/artifactory.list for vault.habana.ai"

  local habana_debdir="$WORKDIR/habana-debs"
  mkdir -p "$habana_debdir"
  cd "$habana_debdir"

  # Check if Habana APT repo is configured
  if apt-cache policy habanalabs-container-runtime 2>/dev/null | grep -q "vault.habana.ai"; then
    info "Habana APT repo detected — downloading packages..."
    if run sudo apt-get download \
        habanalabs-container-runtime=1.18.0-524 \
        habanalabs-firmware-odm=1.18.0-524; then
      for deb in *.deb; do
        [[ -f "$deb" ]] || continue
        jfrog_upload "$deb" "ei-generic-binaries/apt-debs/$deb"
        info "Uploaded: $deb"
      done
      success "Habana .deb packages uploaded to JFrog"
    else
      warn "apt-get download for Habana packages failed — upload manually:"
      warn "  sudo apt-get download habanalabs-container-runtime=1.18.0-524 habanalabs-firmware-odm=1.18.0-524"
      warn "  curl -u $JFROG_CREDS -T <deb> $JFROG_URL/ei-generic-binaries/apt-debs/<deb>"
    fi
  else
    warn "Habana APT repo not configured on VM1 — skipping Habana .deb download"
    warn "To pre-cache Habana packages:"
    warn "  1. Run: wget https://vault.habana.ai/artifactory/gaudi-installer/1.18.0/habanalabs-installer.sh"
    warn "  2. Run: bash habanalabs-installer.sh install --type base -y"
    warn "  3. Re-run: ./jfrog-setup-gaudi.sh --step 3f"
    warn "  OR download debs directly from vault.habana.ai and upload to ei-generic-binaries/apt-debs/"
  fi

  cd - >/dev/null
  success "3f complete"
}

# ---------------------------------------------------------------------------
# Step 3g — Kubernetes / Kubespray Binaries
# ---------------------------------------------------------------------------
step_3g() {
  step_hdr "3g - Kubernetes Binaries"
  local bindir="$WORKDIR/k8s-binaries"
  mkdir -p "$bindir"
  cd "$bindir"

  for bin in kubeadm kubectl kubelet; do
    run curl -fsSLO "https://dl.k8s.io/release/v1.30.4/bin/linux/amd64/$bin"
    jfrog_upload "$bin" "ei-generic-binaries/dl.k8s.io/release/v1.30.4/bin/linux/amd64/$bin"
  done

  run curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz"
  jfrog_upload "cni-plugins-linux-amd64-v1.4.0.tgz" \
    "ei-generic-binaries/github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz"

  run curl -fsSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.1/crictl-v1.30.1-linux-amd64.tar.gz"
  jfrog_upload "crictl-v1.30.1-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.1/crictl-v1.30.1-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/etcd-io/etcd/releases/download/v3.5.16/etcd-v3.5.16-linux-amd64.tar.gz"
  jfrog_upload "etcd-v3.5.16-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/etcd-io/etcd/releases/download/v3.5.16/etcd-v3.5.16-linux-amd64.tar.gz"

  run curl -fsSL -o "calicoctl-linux-amd64-v3.28.1" \
    "https://github.com/projectcalico/calico/releases/download/v3.28.1/calicoctl-linux-amd64"
  jfrog_upload "calicoctl-linux-amd64-v3.28.1" \
    "ei-generic-binaries/github.com/projectcalico/calico/releases/download/v3.28.1/calicoctl-linux-amd64"

  run curl -fsSL -o "calico-v3.28.1.tar.gz" "https://github.com/projectcalico/calico/archive/v3.28.1.tar.gz"
  jfrog_upload "calico-v3.28.1.tar.gz" \
    "ei-generic-binaries/github.com/projectcalico/calico/archive/v3.28.1.tar.gz"

  run curl -fsSLO "https://github.com/projectcalico/calico/releases/download/v3.29.1/calicoctl-linux-amd64"
  jfrog_upload "calicoctl-linux-amd64" \
    "ei-generic-binaries/github.com/projectcalico/calico/releases/download/v3.29.1/calicoctl-linux-amd64"

  run curl -fsSL -o "calico-v3.29.1.tar.gz" "https://github.com/projectcalico/calico/archive/v3.29.1.tar.gz"
  jfrog_upload "calico-v3.29.1.tar.gz" \
    "ei-generic-binaries/github.com/projectcalico/calico/archive/v3.29.1.tar.gz"

  run curl -fsSLO "https://github.com/containerd/containerd/releases/download/v1.7.24/containerd-1.7.24-linux-amd64.tar.gz"
  jfrog_upload "containerd-1.7.24-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/containerd/containerd/releases/download/v1.7.24/containerd-1.7.24-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/containerd/nerdctl/releases/download/v1.7.7/nerdctl-1.7.7-linux-amd64.tar.gz"
  jfrog_upload "nerdctl-1.7.7-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/containerd/nerdctl/releases/download/v1.7.7/nerdctl-1.7.7-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v1.2.3/runc.amd64"
  jfrog_upload "runc.amd64" \
    "ei-generic-binaries/github.com/opencontainers/runc/releases/download/v1.2.3/runc.amd64"

  run curl -fsSLO "https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz"
  jfrog_upload "helm-v3.15.4-linux-amd64.tar.gz" \
    "ei-generic-binaries/get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz"
  run tar -xzf "helm-v3.15.4-linux-amd64.tar.gz" "linux-amd64/helm"
  run mv "linux-amd64/helm" "helm"
  jfrog_upload "helm" "ei-generic-binaries/helm"

  run curl -fsSL -o "get-pip.py" "https://bootstrap.pypa.io/get-pip.py"
  jfrog_upload "get-pip.py" "ei-generic-binaries/get-pip.py"

  jfrog_upload "kubectl" "ei-generic-binaries/kubectl"

  run curl -fsSL -o "yq" \
    "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64"
  run chmod +x yq
  jfrog_upload "yq" "ei-generic-binaries/yq"

  run curl -fsSL -o "kubectx" \
    "https://github.com/ahmetb/kubectx/releases/download/v0.9.5/kubectx"
  run chmod +x kubectx
  jfrog_upload "kubectx" "ei-generic-binaries/kubectx"

  run curl -fsSL -o "kubens" \
    "https://github.com/ahmetb/kubectx/releases/download/v0.9.5/kubens"
  run chmod +x kubens
  jfrog_upload "kubens" "ei-generic-binaries/kubens"

  success "3g complete"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Step 3h — Kubespray Tarball
# ---------------------------------------------------------------------------
step_3h() {
  step_hdr "3h - Kubespray Tarball"
  local kubedir="$WORKDIR/kubespray-build"
  mkdir -p "$kubedir"
  cd "$kubedir"

  if [[ ! -d "kubespray" ]]; then
    run git clone https://github.com/kubernetes-sigs/kubespray
  fi
  run git -C kubespray fetch --tags
  run git -C kubespray checkout v2.27.0
  run tar -czf kubespray.tar.gz kubespray/
  jfrog_upload "kubespray.tar.gz" "ei-generic-binaries/kubespray.tar.gz"

  success "3h complete"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Step 3k — Habana Binaries
#   - habanalabs-installer.sh  (used by gaudi-firmware-driver-updater.sh)
#   - habana-k8s-device-plugin.yaml  (applied by deploy-habana-ai-operator.yml)
# ---------------------------------------------------------------------------
step_3k() {
  step_hdr "3k - Habana Binaries"
  local habanadir="$WORKDIR/habana-binaries"
  mkdir -p "$habanadir"
  cd "$habanadir"

  # habanalabs-installer.sh
  # Source: vault.habana.ai/artifactory/gaudi-installer/1.18.0/habanalabs-installer.sh
  # Used by: gaudi-firmware-driver-updater.sh (line 68) to install Habana base components
  info "Downloading habanalabs-installer.sh (version 1.18.0)..."
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    run curl -fsSL \
      --user "$HABANA_USER:$HABANA_PASS" \
      -o habanalabs-installer.sh \
      "https://vault.habana.ai/artifactory/gaudi-installer/1.18.0/habanalabs-installer.sh"
    jfrog_upload "habanalabs-installer.sh" \
      "ei-generic-binaries/habana/habanalabs-installer-1.18.0.sh"
    success "habanalabs-installer.sh uploaded"
  else
    warn "Skipping habanalabs-installer.sh — pass --habana-user and --habana-pass"
    warn "  Download manually and upload:"
    warn "  curl -u <user>:<pass> -o habanalabs-installer.sh \\"
    warn "    https://vault.habana.ai/artifactory/gaudi-installer/1.18.0/habanalabs-installer.sh"
    warn "  curl -u $JFROG_CREDS -T habanalabs-installer.sh \\"
    warn "    $JFROG_URL/ei-generic-binaries/habana/habanalabs-installer-1.18.0.sh"
  fi

  # habana-k8s-device-plugin.yaml
  # Source: vault.habana.ai/artifactory/docker-k8s-device-plugin/habana-k8s-device-plugin.yaml
  # Applied by: deploy-habana-ai-operator.yml (line 121) via kubernetes.core.k8s src:
  # In airgap mode this manifest must be served locally — upload to ei-generic-binaries
  # and patch the playbook to use the JFrog URL instead of direct vault.habana.ai access.
  info "Downloading habana-k8s-device-plugin.yaml ..."
  if [[ -n "$HABANA_USER" && -n "$HABANA_PASS" ]]; then
    run curl -fsSL \
      --user "$HABANA_USER:$HABANA_PASS" \
      -o habana-k8s-device-plugin.yaml \
      "https://vault.habana.ai/artifactory/docker-k8s-device-plugin/habana-k8s-device-plugin.yaml"
    jfrog_upload "habana-k8s-device-plugin.yaml" \
      "ei-generic-binaries/habana/habana-k8s-device-plugin.yaml"
    success "habana-k8s-device-plugin.yaml uploaded"
    warn "ACTION REQUIRED: patch deploy-habana-ai-operator.yml to fetch device plugin from JFrog:"
    warn "  Replace: src: https://vault.habana.ai/artifactory/docker-k8s-device-plugin/habana-k8s-device-plugin.yaml"
    warn "  With:    src: http://<VM1-IP>:8082/artifactory/ei-generic-binaries/habana/habana-k8s-device-plugin.yaml"
  else
    warn "Skipping habana-k8s-device-plugin.yaml — pass --habana-user and --habana-pass"
    warn "  Download manually and upload:"
    warn "  curl -u <user>:<pass> -o habana-k8s-device-plugin.yaml \\"
    warn "    https://vault.habana.ai/artifactory/docker-k8s-device-plugin/habana-k8s-device-plugin.yaml"
    warn "  curl -u $JFROG_CREDS -T habana-k8s-device-plugin.yaml \\"
    warn "    $JFROG_URL/ei-generic-binaries/habana/habana-k8s-device-plugin.yaml"
  fi

  success "3k complete"
  cd - >/dev/null
}

# ---------------------------------------------------------------------------
# Helper — upload a HuggingFace model to JFrog one file at a time
# ---------------------------------------------------------------------------
upload_hf_model() {
  local hf_repo="$1" jfrog_folder="$2" modeldir="$3"
  mkdir -p "$modeldir"
  run pip3 install -q huggingface_hub

  info "Fetching file list for $hf_repo..."
  local file_list
  file_list=$(python3 - <<PYEOF
from huggingface_hub import list_repo_files
for f in list_repo_files("$hf_repo", token="$HF_TOKEN"):
    print(f)
PYEOF
)

  info "Downloading and uploading model files one at a time..."
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local localfile="$modeldir/$rel"
    mkdir -p "$(dirname "$localfile")"

    local http_code
    http_code=$(curl -su "$JFROG_CREDS" \
      -o /dev/null -w "%{http_code}" \
      "$JFROG_URL/ei-generic-models/$jfrog_folder/$rel")
    if [[ "$http_code" == "200" ]]; then
      info "Already in JFrog, skipping: $rel"
      continue
    fi

    info "Downloading $rel..."
    python3 - <<PYEOF
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id="$hf_repo", filename="$rel", local_dir="$modeldir", token="$HF_TOKEN")
PYEOF

    jfrog_upload "$localfile" "ei-generic-models/$jfrog_folder/$rel"
    info "Removing $rel from VM1 to free disk space..."
    rm -f "$localfile"
  done <<< "$file_list"

  rm -rf "$modeldir"
}

set_jfrog_upload_limit_unlimited() {
  info "Setting JFrog file upload limit to unlimited..."
  local cfg_tmp
  cfg_tmp=$(mktemp /tmp/jfrog-config-XXXXXX.xml)
  curl -su "$JFROG_CREDS" "$JFROG_URL/api/system/configuration" > "$cfg_tmp"
  if grep -q "fileUploadMaxSizeMb" "$cfg_tmp"; then
    sed -i 's|<fileUploadMaxSizeMb>[0-9]*</fileUploadMaxSizeMb>|<fileUploadMaxSizeMb>0</fileUploadMaxSizeMb>|' "$cfg_tmp"
    local http_code
    http_code=$(curl -su "$JFROG_CREDS" -X POST \
      "$JFROG_URL/api/system/configuration" \
      -H "Content-Type: application/xml" \
      --data-binary @"$cfg_tmp" \
      -o /dev/null -w "%{http_code}")
    [[ "$http_code" == "200" ]] && success "File upload limit set to unlimited" \
      || warn "Could not update file upload limit (HTTP $http_code)"
  fi
  rm -f "$cfg_tmp"
}

# ---------------------------------------------------------------------------
# Step 3i — Meta-Llama-3.1-8B-Instruct (optional)
# ---------------------------------------------------------------------------
step_3i() {
  step_hdr "3i - LLM Model: Meta-Llama-3.1-8B-Instruct"
  if [[ -z "$HF_TOKEN" ]]; then
    warn "Skipping 3i: --hf-token not provided"
    warn "Re-run with: --step 3i --hf-token hf_..."
    return 0
  fi
  set_jfrog_upload_limit_unlimited
  upload_hf_model "meta-llama/Llama-3.1-8B-Instruct" "Meta-Llama-3.1-8B-Instruct" "$WORKDIR/Llama-3.1-8B-Instruct"
  success "3i complete"
}

# ---------------------------------------------------------------------------
# Step 3j — Meta-Llama-3.2-3B-Instruct (optional)
# ---------------------------------------------------------------------------
step_3j() {
  step_hdr "3j - LLM Model: Meta-Llama-3.2-3B-Instruct"
  if [[ -z "$HF_TOKEN" ]]; then
    warn "Skipping 3j: --hf-token not provided"
    warn "Re-run with: --step 3j --hf-token hf_..."
    return 0
  fi
  set_jfrog_upload_limit_unlimited
  upload_hf_model "meta-llama/Llama-3.2-3B-Instruct" "Meta-Llama-3.2-3B-Instruct" "$WORKDIR/Llama-3.2-3B-Instruct"
  success "3j complete"
}

# ---------------------------------------------------------------------------
# Step 4 — Set Remote Repos to Offline
# ---------------------------------------------------------------------------
step_4() {
  step_hdr "4 - Set Remote Repos to Offline"

  local remote_repos=(
    ei-docker-dockerhub
    ei-docker-ecr
    ei-docker-ghcr
    ei-docker-k8s
    ei-docker-quay
    ei-docker-vault-habana
    ei-pypi-remote
    ei-debian-ubuntu
    ei-helm-ingress-nginx
    ei-helm-langfuse
    ei-helm-prometheus
    ei-helm-gaudi
    ei-hf-remote
  )

  for repo in "${remote_repos[@]}"; do
    info "Setting $repo to Offline..."
    local http_code
    http_code=$(curl -su "$JFROG_CREDS" -X POST \
      "$JFROG_URL/api/repositories/$repo" \
      -H "Content-Type: application/json" \
      -d '{"offline":true}' \
      -o /dev/null -w "%{http_code}")
    if [[ "$http_code" == "200" ]]; then
      success "$repo set to Offline"
    else
      warn "$repo — unexpected HTTP $http_code (may already be Offline or not exist)"
    fi
  done

  success "Step 4 complete — all remote repos set to Offline"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  EI Airgap — JFrog Gaudi Setup"
echo "  JFrog:    $JFROG_URL"
echo "  Workdir:  $WORKDIR"
echo "  Dry-run:  $DRY_RUN"
echo "  Only step: ${ONLY_STEP:-all}"
echo "  Skip steps: ${SKIP_STEPS[*]:-none}"
echo "  Gaudi operator: $GAUDI_OPERATOR_VERSION"
echo "  Habana creds:   ${HABANA_USER:-<not set>}"
echo "============================================================"
echo ""

if [[ -z "$HABANA_USER" || -z "$HABANA_PASS" ]]; then
  warn "Habana credentials not provided — vault.habana.ai artifacts will be skipped."
  warn "Pass --habana-user and --habana-pass to include:"
  warn "  - metric-exporter:1.20.1-97 Docker image"
  warn "  - habana-ai-operator:$GAUDI_OPERATOR_VERSION Helm chart"
  warn "  - habanalabs-installer.sh binary"
  warn "  - habana-k8s-device-plugin.yaml manifest"
  echo ""
fi

if ! $DRY_RUN; then
  check_prereqs
  mkdir -p "$WORKDIR"
fi

should_run "1"  && step_1
should_run "2"  && step_2
should_run "3a" && step_3a
should_run "3b" && step_3b
should_run "3c" && step_3c
should_run "3d" && step_3d
should_run "3e" && step_3e
should_run "3f" && step_3f
should_run "3g" && step_3g
should_run "3h" && step_3h
should_run "3k" && step_3k
should_run "3i" && step_3i
should_run "3j" && step_3j

should_run "4"  && step_4

echo ""
success "JFrog Gaudi setup complete. Proceed with EI Gaudi deployment on the target node."
