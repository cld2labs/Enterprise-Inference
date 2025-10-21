set -euo pipefail
HF_TOKEN="Your hugging face token"; MODEL_ID="Model Id you want to use"
[ -z "$HF_TOKEN" ] || [ -z "$MODEL_ID" ] && { echo "Usage: $0 hf_<TOKEN> <model_id>"; exit 1; }

echo "Checking model: $MODEL_ID"

# --- Fetch metadata
meta=$(curl -s -H "Authorization: Bearer $HF_TOKEN" "https://huggingface.co/api/models/$MODEL_ID")

# --- Parse metadata
private=$(echo "$meta" | grep -o '"private":[^,}]*' | cut -d: -f2 | tr -d ' "')
gated=$(echo "$meta" | grep -o '"gated":[^,}]*' | cut -d: -f2 | tr -d ' "')

# --- Try downloading a small file to test access
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

# --- Explain terms
cat <<'EOT'
Meaning of each term:
- Private=false → The model is public (anyone can view/download).
- Private=true  → The model is private (only specific users/org can access).

- Gated=false   → Open access; no approval needed.
- Gated=true    → Access requires manual approval or license acceptance.

- Downloadable=true  → Your token can fetch files (model accessible).
- Downloadable=false → You cannot download files (403/404).
EOT
