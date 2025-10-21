#!/usr/bin/env bash
set -euo pipefail

# --- Prompt for inputs
read -p "Enter your Hugging Face token: " HF_TOKEN
read -p "Enter your Model ID: " MODEL_ID

# --- Validate inputs
if [[ -z "$HF_TOKEN" || -z "$MODEL_ID" ]]; then
  echo "Usage: $0 <huggingface_token> <model_id>"
  exit 1
fi

echo "Checking model: $MODEL_ID ..."
echo

# --- Fetch metadata
meta=$(curl -s -H "Authorization: Bearer $HF_TOKEN" "https://huggingface.co/api/models/$MODEL_ID")

# --- If the API failed
if [[ -z "$meta" ]]; then
  echo "Failed to fetch metadata. Please check your token or model ID."
  exit 1
fi

# --- Parse metadata (using jq if available, otherwise fallback to grep)
if command -v jq >/dev/null 2>&1; then
  private=$(echo "$meta" | jq -r '.private // "unknown"')
  gated=$(echo "$meta" | jq -r '.gated // "unknown"')
else
  private=$(echo "$meta" | grep -o '"private":[^,}]*' | cut -d: -f2 | tr -d ' "')
  gated=$(echo "$meta" | grep -o '"gated":[^,}]*' | cut -d: -f2 | tr -d ' "')
fi

# --- Try downloading a small file (config.json) to check access
status=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/$MODEL_ID/resolve/main/config.json")

# --- Print results
echo "--------------------------------------"
echo "Private:      ${private:-unknown}"
echo "Gated:        ${gated:-unknown}"
echo -n "Downloadable: "
case "$status" in
  200) echo "true (You can access model files)";;
  403) echo "false (Forbidden — you lack permission)";;
  404) echo "false (File not found — maybe no config.json)";;
  *)   echo "unknown (HTTP $status)";;
esac
echo "--------------------------------------"

# --- Explain meaning
cat <<'EOT'
Meaning of each term:
- Private=false → The model is public (anyone can view/download).
- Private=true  → The model is private (only specific users/org can access).

- Gated=false   → Open access; no approval needed.
- Gated=true    → Access requires manual approval or license acceptance.

- Downloadable=true  → Your token can fetch files (model accessible).
- Downloadable=false → You cannot download files (403/404).
EOT
