#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# jfrog-setup.sh
#
# One-shot script that sets up JFrog Artifactory for EI airgapped deployment:
#   Step 1  - Create all required repositories
#   Step 2  - Enable anonymous access (XML config patch + permissions)
#   Step 3a - Docker images (via skopeo)
#   Step 3b - Helm charts
#   Step 3c - PyPI packages
#   Step 3d - pip bootstrap wheel
#   Step 3e - Ansible collections
#   Step 3f - apt .deb files for jq
#   Step 3g - Kubernetes / Kubespray binaries
#   Step 3h - Kubespray tarball
#   Step 3i - Meta-Llama-3.1-8B-Instruct model (optional, requires HuggingFace token)
#   Step 3j - Meta-Llama-3.2-3B-Instruct model (optional, requires HuggingFace token)
#
# Run this script on VM1 (internet-connected machine with JFrog installed).
#
# Usage:
#   ./jfrog-setup.sh [OPTIONS]
#
# Options:
#   --jfrog-url URL        JFrog base URL (default: http://localhost:8082/artifactory)
#   --jfrog-user USER      JFrog username (default: admin)
#   --jfrog-pass PASS      JFrog password (default: password)
#   --hf-token TOKEN       HuggingFace token (required for steps 3i and 3j)
#   --dockerhub-user USER  Docker Hub username (required for apisix-ingress-controller)
#   --dockerhub-pass PASS  Docker Hub password / PAT
#   --step STEP            Run only a specific step (e.g. --step 1, --step 3a)
#   --skip STEP            Skip a specific step (repeatable)
#   --workdir DIR          Working directory for downloads (default: /tmp/ei-airgap-upload)
#   --dry-run              Print commands without executing them
#   -h, --help             Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
JFROG_URL="${JFROG_URL:-http://localhost:8082/artifactory}"
JFROG_USER="${JFROG_USER:-admin}"
JFROG_PASS="${JFROG_PASS:-password}"
HF_TOKEN="${HF_TOKEN:-}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_PASS="${DOCKERHUB_PASS:-}"
ONLY_STEP=""
SKIP_STEPS=()
WORKDIR="/tmp/ei-airgap-upload"
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
    --jfrog-url)      JFROG_URL="$2";       shift 2 ;;
    --jfrog-user)     JFROG_USER="$2";      shift 2 ;;
    --jfrog-pass)     JFROG_PASS="$2";      shift 2 ;;
    --hf-token)       HF_TOKEN="$2";        shift 2 ;;
    --dockerhub-user) DOCKERHUB_USER="$2";  shift 2 ;;
    --dockerhub-pass) DOCKERHUB_PASS="$2";  shift 2 ;;
    --step)           ONLY_STEP="$2";       shift 2 ;;
    --skip)           SKIP_STEPS+=("$2");   shift 2 ;;
    --workdir)        WORKDIR="$2";         shift 2 ;;
    --dry-run)        DRY_RUN=true;         shift ;;
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
  create_repo "ei-docker-virtual" \
    '{"rclass":"virtual","packageType":"docker","repositories":["ei-docker-local","ei-docker-dockerhub","ei-docker-ecr","ei-docker-ghcr","ei-docker-k8s","ei-docker-quay"]}'

  echo "── Helm Repositories ────────────────────────────────────────"
  create_repo "ei-helm-local" \
    '{"rclass":"local","packageType":"helmoci"}'
  create_repo "ei-helm-ingress-nginx" \
    '{"rclass":"remote","packageType":"helmoci","url":"https://kubernetes.github.io/ingress-nginx"}'
  create_repo "ei-helm-langfuse" \
    '{"rclass":"remote","packageType":"helmoci","url":"https://langfuse.github.io/langfuse-k8s"}'
  create_repo "ei-helm-virtual" \
    '{"rclass":"virtual","packageType":"helmoci","repositories":["ei-helm-local","ei-helm-ingress-nginx","ei-helm-langfuse"]}'

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

  # Patch XML config to set enabledForAnonymous=true
  # The UI toggle only sets buildGlobalBasicReadForAnonymous but NOT enabledForAnonymous
  info "Fetching JFrog system configuration..."
  curl -su "$JFROG_CREDS" \
    "$JFROG_URL/api/system/configuration" > /tmp/jfrog-config.xml

  if grep -q "<enabledForAnonymous>false</enabledForAnonymous>" /tmp/jfrog-config.xml; then
    sed -i 's|<enabledForAnonymous>false</enabledForAnonymous>|<enabledForAnonymous>true</enabledForAnonymous>|g' \
      /tmp/jfrog-config.xml
    info "Applying updated configuration..."
    local http_code
    http_code=$(curl -su "$JFROG_CREDS" -X POST \
      "$JFROG_URL/api/system/configuration" \
      -H "Content-Type: application/xml" \
      --data-binary @/tmp/jfrog-config.xml \
      -o /tmp/jfrog-config-resp.txt -w "%{http_code}")
    if [[ "$http_code" == "200" ]]; then
      success "enabledForAnonymous set to true"
    else
      error "Failed to apply config (HTTP $http_code): $(cat /tmp/jfrog-config-resp.txt)"
    fi
  else
    success "enabledForAnonymous already true — skipping"
  fi

  # Set anonymous read permissions on all Docker repos
  # Note: virtual repos cannot be added to permission targets (JFrog returns 400)
  info "Setting anonymous read permissions on Docker repos..."
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
open('/tmp/jfrog-perm.json', 'w').write(json.dumps(perm))
"
  local http_code
  http_code=$(curl -su "$JFROG_CREDS" -X PUT \
    "$JFROG_URL/api/security/permissions/anonymous-docker-read" \
    -H "Content-Type: application/json" \
    -d @/tmp/jfrog-perm.json \
    -o /tmp/jfrog-perm-resp.txt -w "%{http_code}")
  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    success "Anonymous read permissions set"
  else
    warn "Permissions API returned HTTP $http_code: $(cat /tmp/jfrog-perm-resp.txt)"
  fi

  success "Step 2 complete — anonymous access enabled"
}

# ---------------------------------------------------------------------------
# Step 3a — Docker Images (via skopeo)
# ---------------------------------------------------------------------------
step_3a() {
  step_hdr "3a - Docker Images"
  local dest_repo="ei-docker-local"
  local -a skopeo_dest_flags=(--dest-tls-verify=false --dest-creds "$JFROG_CREDS")

  # Format: "source_image|dest_path_in_ei-docker-local"
  # busybox:1.28 is no longer available via Docker Hub v2 API — copy latest and push as 1.28
  # pause:3.9 is correct for k8s v1.30.4 (3.10 is for k8s 1.31+)
  local images=(
    # ── ECR ──────────────────────────────────────────────────────────────────
    "public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.10.2|q9t5s3a7/vllm-cpu-release-repo:v0.10.2"
    "public.ecr.aws/bitnami/minio:2024.11.7-debian-12-r0|bitnami/minio:2024.11.7-debian-12-r0"

    # ── GHCR ─────────────────────────────────────────────────────────────────
    "ghcr.io/huggingface/text-generation-inference:2.4.0-intel-cpu|huggingface/text-generation-inference:2.4.0-intel-cpu"
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.7|huggingface/text-embeddings-inference:cpu-1.7"
    "ghcr.io/berriai/litellm-non_root:main-v1.75.8-stable|berriai/litellm-non_root:main-v1.75.8-stable"
    "ghcr.io/containers/nri-plugins/nri-resource-policy-balloons:v0.12.2|containers/nri-plugins/nri-resource-policy-balloons:v0.12.2"
    "ghcr.io/containers/nri-plugins/nri-config-manager:v0.12.2|containers/nri-plugins/nri-config-manager:v0.12.2"

    # ── Docker Hub ────────────────────────────────────────────────────────────
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
    "docker.io/kubernetesui/dashboard:v2.7.0|kubernetesui/dashboard:v2.7.0"
    "docker.io/kubernetesui/metrics-scraper:v1.0.8|kubernetesui/metrics-scraper:v1.0.8"
    "docker.io/library/nginx:1.25.2-alpine|library/nginx:1.25.2-alpine"
    "docker.io/library/ubuntu:22.04|library/ubuntu:22.04"
    "docker.io/library/registry:2.8.1|library/registry:2.8.1"
    "docker.io/openvino/model_server:2025.4|openvino/model_server:2025.4"
    "docker.io/rancher/local-path-provisioner:v0.0.24|rancher/local-path-provisioner:v0.0.24"
    "docker.io/library/busybox:latest|library/busybox:1.28"    # 1.28 manifest no longer in Hub v2 API — copy latest, push as 1.28

    # ── registry.k8s.io ───────────────────────────────────────────────────────
    "registry.k8s.io/ingress-nginx/controller:v1.12.2|ingress-nginx/controller:v1.12.2"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.3|ingress-nginx/kube-webhook-certgen:v1.5.3"
    "registry.k8s.io/pause:3.9|pause:3.9"                      # k8s v1.30.4 uses pause:3.9
    "registry.k8s.io/etcd:3.5.12-0|etcd:3.5.12-0"
    "registry.k8s.io/kube-apiserver:v1.30.4|kube-apiserver:v1.30.4"
    "registry.k8s.io/kube-controller-manager:v1.30.4|kube-controller-manager:v1.30.4"
    "registry.k8s.io/kube-scheduler:v1.30.4|kube-scheduler:v1.30.4"
    "registry.k8s.io/kube-proxy:v1.30.4|kube-proxy:v1.30.4"
    "registry.k8s.io/coredns/coredns:v1.11.1|coredns/coredns:v1.11.1"
    "registry.k8s.io/dns/k8s-dns-node-cache:1.22.28|dns/k8s-dns-node-cache:1.22.28"
    "registry.k8s.io/cpa/cluster-proportional-autoscaler:v1.8.8|cpa/cluster-proportional-autoscaler:v1.8.8"

    # ── quay.io ───────────────────────────────────────────────────────────────
    "quay.io/calico/node:v3.28.1|calico/node:v3.28.1"
    "quay.io/calico/node:v3.29.1|calico/node:v3.29.1"
    "quay.io/calico/cni:v3.28.1|calico/cni:v3.28.1"
    "quay.io/calico/kube-controllers:v3.28.1|calico/kube-controllers:v3.28.1"
    "quay.io/calico/pod2daemon-flexvol:v3.28.1|calico/pod2daemon-flexvol:v3.28.1"
  )

  local copied=0 failed=0 fail_list=()
  for entry in "${images[@]}"; do
    local src="${entry%%|*}"
    local dest_path="${entry##*|}"
    info "Copying $src -> $dest_repo/$dest_path"
    if run skopeo copy --src-tls-verify=false "${skopeo_dest_flags[@]}" \
        "docker://$src" "docker://$JFROG_HOST/$dest_repo/$dest_path"; then
      copied=$((copied+1))
    else
      warn "Failed: $src"
      failed=$((failed+1))
      fail_list+=("$src")
    fi
  done

  # apisix-ingress-controller requires Docker Hub credentials (rate-limited / auth required)
  if [[ -n "$DOCKERHUB_USER" && -n "$DOCKERHUB_PASS" ]]; then
    info "Copying apache/apisix-ingress-controller:1.8.0 from Docker Hub..."
    if run skopeo copy \
        --src-creds "$DOCKERHUB_USER:$DOCKERHUB_PASS" \
        "${skopeo_dest_flags[@]}" \
        "docker://docker.io/apache/apisix-ingress-controller:1.8.0" \
        "docker://$JFROG_HOST/$dest_repo/apache/apisix-ingress-controller:1.8.0"; then
      copied=$((copied+1))
    else
      warn "Failed: apisix-ingress-controller:1.8.0"
      failed=$((failed+1))
    fi
  else
    warn "Skipping apisix-ingress-controller:1.8.0 — pass --dockerhub-user and --dockerhub-pass"
  fi

  success "3a complete: copied=$copied  failed=$failed"
  if [[ $failed -gt 0 ]]; then
    warn "Failed images:"; for img in "${fail_list[@]}"; do warn "  $img"; done
  fi

  # Verify nginx is properly cached — must use Docker Accept headers; plain curl returns 404 even if cached
  info "Verifying nginx:1.25.2-alpine manifest is accessible in JFrog..."
  local http_code
  http_code=$(curl -s -u "$JFROG_CREDS" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -o /dev/null -w "%{http_code}" \
    "${JFROG_URL%/artifactory}/v2/ei-docker-virtual/library/nginx/manifests/1.25.2-alpine")
  if [[ "$http_code" == "200" ]]; then
    success "nginx:1.25.2-alpine verified in JFrog (HTTP $http_code)"
  else
    warn "nginx manifest check returned HTTP $http_code — expected 200; image may not be cached correctly"
  fi
}

# ---------------------------------------------------------------------------
# Step 3b — Helm Charts
# ---------------------------------------------------------------------------
step_3b() {
  step_hdr "3b - Helm Charts"
  local helmdir="$WORKDIR/helm-charts"
  mkdir -p "$helmdir"
  cd "$helmdir"

  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  run helm repo add langfuse https://langfuse.github.io/langfuse-k8s
  run helm repo add apisix https://charts.apiseven.com
  run helm repo add nri-plugins https://containers.github.io/nri-plugins
  run helm repo update

  run helm pull ingress-nginx/ingress-nginx --version 4.12.2     --destination .
  run helm pull langfuse/langfuse           --version 1.5.1       --destination .
  run helm pull apisix/apisix               --version 2.8.1       --destination .
  run helm pull nri-plugins/nri-resource-policy-balloons --version v0.12.2 --destination .

  run helm pull oci://registry-1.docker.io/bitnamicharts/keycloak   --version 22.1.0  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 16.7.4  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/redis      --version 21.1.3  --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/clickhouse --version 8.0.5   --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/minio      --version 14.10.5 --destination .
  run helm pull oci://registry-1.docker.io/bitnamicharts/valkey     --version 2.2.4   --destination .

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
    cryptography==44.0.0 cryptography==46.0.7 requests oauthlib requests-oauthlib urllib3 \
    certifi charset-normalizer idna packaging typing-extensions \
    six python-dateutil attrs rpds-py referencing resolvelib \
    durationpy websocket-client cffi pycparser markupsafe \
    -d "$wheelsdir"

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

  # Uploaded as generic 'pip.whl' — deployment script reads version from WHEEL metadata inside the zip
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

  # setup-env.sh looks for <namespace>-<name>-latest.tar.gz
  local kube_core_tgz community_general_tgz ansible_posix_tgz
  kube_core_tgz=$(ls "$colldir"/kubernetes-core-*.tar.gz 2>/dev/null | head -1)
  community_general_tgz=$(ls "$colldir"/community-general-*.tar.gz 2>/dev/null | head -1)
  ansible_posix_tgz=$(ls "$colldir"/ansible-posix-*.tar.gz 2>/dev/null | head -1)

  if [[ -n "$kube_core_tgz" ]]; then
    # Upload both versioned name (matches JFrog listing) and -latest (what setup-env.sh looks for)
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

  # community.kubernetes is the legacy name — upload same tarball as community-kubernetes-2.0.1
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
#   Part 1: Download jq .deb files and upload to ei-generic-binaries/apt-debs/
#           (installed via dpkg on VM2 by the inference-tools role)
#   Part 2: Pre-cache all Kubespray apt packages in JFrog by routing VM1 apt
#           through ei-debian-virtual so JFrog fetches and caches each package
#           and its dependencies before going Offline
# ---------------------------------------------------------------------------
step_3f() {
  step_hdr "3f - apt .deb Files"
  local debdir="$WORKDIR/apt-debs"
  mkdir -p "$debdir"

  # ── Part 1: jq via dpkg path ─────────────────────────────────────────────
  info "Downloading jq, libjq1, libonig5..."
  cd "$debdir"
  run sudo apt-get download jq libjq1 libonig5
  for deb in *.deb; do
    [[ -f "$deb" ]] || continue
    jfrog_upload "$deb" "ei-generic-binaries/apt-debs/$deb"
  done
  cd - >/dev/null

  # ── Part 2: Kubespray apt packages via JFrog Debian remote ───────────────
  # Kubespray kubernetes/preinstall requires these packages on VM2.
  # VM2 apt is pointed at JFrog in airgap mode, so JFrog must have them
  # cached before going Offline. Route VM1 apt through JFrog here to
  # trigger fetching and caching of each package and its dependencies.
  info "Pre-caching Kubespray apt packages in JFrog..."

  local http_code
  http_code=$(curl -su "$JFROG_CREDS" -X POST \
    "$JFROG_URL/api/repositories/ei-debian-ubuntu" \
    -H "Content-Type: application/json" \
    -d '{"offline":false}' \
    -o /dev/null -w "%{http_code}")
  if [[ "$http_code" != "200" ]]; then
    warn "Could not set ei-debian-ubuntu Online (HTTP $http_code) — skipping Kubespray apt pre-cache"
    success "3f complete (jq packages only)"
    return 0
  fi
  info "ei-debian-ubuntu set to Online"

  local jfrog_src="http://${JFROG_CREDS}@${JFROG_HOST}/artifactory/ei-debian-virtual"
  local jfrog_list="/etc/apt/sources.list.d/jfrog-precache.list"

  # Write sources file using two separate tee calls to avoid shell line-wrap issues
  echo "deb [trusted=yes] $jfrog_src jammy main restricted universe multiverse" \
    | sudo tee "$jfrog_list" > /dev/null
  echo "deb [trusted=yes] $jfrog_src jammy-updates main restricted universe multiverse" \
    | sudo tee -a "$jfrog_list" > /dev/null

  # Disable default Ubuntu sources so apt only talks to JFrog
  sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak

  local precache_ok=true
  if run sudo apt-get update; then
    # Clear any locally cached .deb files so apt must fetch from JFrog
    # (if the package is already in /var/cache/apt/archives, apt skips the
    # download entirely and JFrog never sees the request)
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
      || { warn "Some packages may not have been cached"; precache_ok=false; }

    # unzip requires --reinstall because it is typically already installed
    run sudo apt-get install --download-only --reinstall -y unzip \
      || { warn "unzip may not have been cached"; precache_ok=false; }
  else
    warn "apt-get update through JFrog failed — Kubespray packages may not be cached"
    precache_ok=false
  fi

  sudo mv /etc/apt/sources.list.bak /etc/apt/sources.list
  sudo rm -f "$jfrog_list"

  # Set ei-debian-ubuntu back to Offline
  curl -su "$JFROG_CREDS" -X POST \
    "$JFROG_URL/api/repositories/ei-debian-ubuntu" \
    -H "Content-Type: application/json" \
    -d '{"offline":true}' > /dev/null 2>&1
  info "ei-debian-ubuntu set back to Offline"

  if $precache_ok; then
    success "3f complete — jq debs uploaded, Kubespray apt packages cached in JFrog"
  else
    warn "3f finished with warnings — some apt packages may be missing from JFrog cache"
  fi
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

  run curl -fsSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.0/crictl-v1.30.0-linux-amd64.tar.gz"
  jfrog_upload "crictl-v1.30.0-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.0/crictl-v1.30.0-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz"
  jfrog_upload "etcd-v3.5.12-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/etcd-io/etcd/releases/download/v3.5.12/etcd-v3.5.12-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/projectcalico/calico/releases/download/v3.28.1/calicoctl-linux-amd64"
  jfrog_upload "calicoctl-linux-amd64" \
    "ei-generic-binaries/github.com/projectcalico/calico/releases/download/v3.28.1/calicoctl-linux-amd64"

  run curl -fsSL -o "calico-v3.28.1.tar.gz" "https://github.com/projectcalico/calico/archive/v3.28.1.tar.gz"
  jfrog_upload "calico-v3.28.1.tar.gz" \
    "ei-generic-binaries/github.com/projectcalico/calico/archive/v3.28.1.tar.gz"

  run curl -fsSLO "https://github.com/containerd/containerd/releases/download/v1.7.21/containerd-1.7.21-linux-amd64.tar.gz"
  jfrog_upload "containerd-1.7.21-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/containerd/containerd/releases/download/v1.7.21/containerd-1.7.21-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-amd64.tar.gz"
  jfrog_upload "nerdctl-1.7.6-linux-amd64.tar.gz" \
    "ei-generic-binaries/github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-amd64.tar.gz"

  run curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v1.1.13/runc.amd64"
  jfrog_upload "runc.amd64" \
    "ei-generic-binaries/github.com/opencontainers/runc/releases/download/v1.1.13/runc.amd64"

  run curl -fsSLO "https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz"
  jfrog_upload "helm-v3.15.4-linux-amd64.tar.gz" \
    "ei-generic-binaries/get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz"
  # Also upload the bare helm binary (extracted from tarball)
  run tar -xzf "helm-v3.15.4-linux-amd64.tar.gz" "linux-amd64/helm"
  run mv "linux-amd64/helm" "helm"
  jfrog_upload "helm" "ei-generic-binaries/helm"

  run curl -fsSL -o "get-pip.py" "https://bootstrap.pypa.io/get-pip.py"
  jfrog_upload "get-pip.py" "ei-generic-binaries/get-pip.py"

  # kubectl is already uploaded under dl.k8s.io path — also upload as bare binary at root
  jfrog_upload "kubectl" "ei-generic-binaries/kubectl"

  # yq
  run curl -fsSL -o "yq" \
    "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64"
  run chmod +x yq
  jfrog_upload "yq" "ei-generic-binaries/yq"

  # kubectx + kubens
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
# Helper — upload a HuggingFace model to JFrog one file at a time
#   $1 = HuggingFace repo ID  (e.g. meta-llama/Llama-3.1-8B-Instruct)
#   $2 = JFrog destination folder name under ei-generic-models/
#   $3 = local working directory
# ---------------------------------------------------------------------------
upload_hf_model() {
  local hf_repo="$1"
  local jfrog_folder="$2"
  local modeldir="$3"

  mkdir -p "$modeldir"
  run pip3 install -q huggingface_hub

  # Get the list of all files in the model repo without downloading anything
  info "Fetching file list for $hf_repo..."
  local file_list
  file_list=$(python3 - <<PYEOF
from huggingface_hub import list_repo_files
for f in list_repo_files("$hf_repo", token="$HF_TOKEN"):
    print(f)
PYEOF
)

  # Download each file one at a time, upload to JFrog, then delete it.
  # This keeps VM1 disk usage to one file at a time instead of the full model.
  # Before downloading, check if the file already exists in JFrog and skip it.
  # This makes reruns safe -- if the script fails halfway, it picks up where it left off.
  info "Downloading and uploading model files one at a time..."
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local localfile="$modeldir/$rel"
    mkdir -p "$(dirname "$localfile")"

    # Check if the file is already in JFrog -- skip if so
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
hf_hub_download(
    repo_id="$hf_repo",
    filename="$rel",
    local_dir="$modeldir",
    token="$HF_TOKEN"
)
PYEOF

    jfrog_upload "$localfile" "ei-generic-models/$jfrog_folder/$rel"

    info "Removing $rel from VM1 to free disk space..."
    rm -f "$localfile"
  done <<< "$file_list"

  # Clean up the model directory including any leftover cache files
  rm -rf "$modeldir"
}

# ---------------------------------------------------------------------------
# Helper — patch JFrog file upload size limit to unlimited
# ---------------------------------------------------------------------------
set_jfrog_upload_limit_unlimited() {
  info "Setting JFrog file upload limit to unlimited..."
  local cfg_tmp
  cfg_tmp=$(mktemp /tmp/jfrog-config-XXXXXX.xml)
  curl -su "$JFROG_CREDS" \
    "$JFROG_URL/api/system/configuration" > "$cfg_tmp"
  if grep -q "fileUploadMaxSizeMb" "$cfg_tmp"; then
    sed -i 's|<fileUploadMaxSizeMb>[0-9]*</fileUploadMaxSizeMb>|<fileUploadMaxSizeMb>0</fileUploadMaxSizeMb>|' "$cfg_tmp"
    local http_code
    http_code=$(curl -su "$JFROG_CREDS" -X POST \
      "$JFROG_URL/api/system/configuration" \
      -H "Content-Type: application/xml" \
      --data-binary @"$cfg_tmp" \
      -o /dev/null -w "%{http_code}")
    if [[ "$http_code" == "200" ]]; then
      success "File upload limit set to unlimited"
    else
      warn "Could not update file upload limit (HTTP $http_code) -- large files may fail"
    fi
  else
    warn "fileUploadMaxSizeMb not found in config -- skipping limit patch"
  fi
  rm -f "$cfg_tmp"
}

# ---------------------------------------------------------------------------
# Step 3i — Meta-Llama-3.1-8B-Instruct (optional)
# ---------------------------------------------------------------------------
step_3i() {
  step_hdr "3i - LLM Model: Meta-Llama-3.1-8B-Instruct"

  if [[ -z "$HF_TOKEN" ]]; then
    warn "Skipping 3h: --hf-token not provided"
    warn "Re-run with: --step 3i --hf-token hf_..."
    return 0
  fi

  set_jfrog_upload_limit_unlimited
  upload_hf_model \
    "meta-llama/Llama-3.1-8B-Instruct" \
    "Meta-Llama-3.1-8B-Instruct" \
    "$WORKDIR/Llama-3.1-8B-Instruct"

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
  upload_hf_model \
    "meta-llama/Llama-3.2-3B-Instruct" \
    "Meta-Llama-3.2-3B-Instruct" \
    "$WORKDIR/Llama-3.2-3B-Instruct"

  success "3j complete"
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
    ei-pypi-remote
    ei-debian-ubuntu
    ei-helm-ingress-nginx
    ei-helm-langfuse
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
echo "  EI Airgap — JFrog Full Setup"
echo "  JFrog: $JFROG_URL"
echo "  Workdir: $WORKDIR"
echo "  Dry-run: $DRY_RUN"
echo "  Only step: ${ONLY_STEP:-all}"
echo "  Skip steps: ${SKIP_STEPS[*]:-none}"
echo "============================================================"
echo ""

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
should_run "3i" && step_3i
should_run "3j" && step_3j

should_run "4"  && step_4

echo ""
success "JFrog setup is complete. Proceed with EI deployment on VM2."
