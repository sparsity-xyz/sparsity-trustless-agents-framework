#!/bin/bash
set -e

# Color & logging helpers
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

info() { printf "%b%s%b\n" "${BLUE}" "[INFO] $*" "${RESET}"; }
step() { printf "%b%s%b\n" "${BOLD}${BLUE}" "==> $*" "${RESET}"; }
success() { printf "%b%s%b\n" "${GREEN}" "[OK] $*" "${RESET}"; }
warn() { printf "%b%s%b\n" "${YELLOW}" "[WARN] $*" "${RESET}"; }
err() { printf "%b%s%b\n" "${RED}" "[ERROR] $*" "${RESET}" 1>&2; }

trap 'err "Script failed at line $LINENO."; exit 1' ERR

# Load environment variables
if [ ! -f .env ]; then
    err ".env file not found"
    exit 1
fi
source .env
step "Loaded .env file"

PROOF_PATH=${PROOF_PATH:-proof.json}

# Check required variables
step "Checking required environment variables"
if [ -z "$ETH_PROVER_SERVICE_URL" ] || [ -z "$ATTESTATION_URL" ] || [ -z "$ETH_ADDRESS" ]; then
    err "ETH_PROVER_SERVICE_URL, ATTESTATION_URL, and ETH_ADDRESS must be set in .env"
    exit 1
else
    success "Required environment variables present"
fi

# Tool checks
step "Checking required tools"
for t in curl jq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    err "Required tool not found: $t"
    exit 1
  fi
done
success "All required tools available"

step "Nitro Attestation Proof Service"
info "Service URL: $ETH_PROVER_SERVICE_URL"
info "Attestation URL: $ATTESTATION_URL"
info "ETH Address: $ETH_ADDRESS"
echo

# Upload attestation
step "Uploading attestation"
RESPONSE=$(curl -s -X POST "$ETH_PROVER_SERVICE_URL/upload" \
    -H "Content-Type: application/json" \
    -d "{\"url\": \"$ATTESTATION_URL\", \"eth_address\": \"$ETH_ADDRESS\"}")

info "Upload response:"
echo "$RESPONSE" | jq .
DIR_NAME=$(echo "$RESPONSE" | jq -r '.directory_name')

if [ "$DIR_NAME" = "null" ] || [ -z "$DIR_NAME" ]; then
    err "Failed to upload attestation"
    exit 1
fi

echo
success "Attestation uploaded"
info "Directory: $DIR_NAME"
info "Polling for proof (timeout: 150s)..."
echo

# Poll for proof with 100 second total timeout
START_TIME=$(date +%s)
TIMEOUT=150

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout: Proof not ready after ${TIMEOUT}s"
        exit 1
    fi
    
    STATUS_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "$ETH_PROVER_SERVICE_URL/proof/$DIR_NAME")
    HTTP_STATUS=$(echo "$STATUS_RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
    BODY=$(echo "$STATUS_RESPONSE" | sed '/HTTP_STATUS/d')
    
    if [ "$HTTP_STATUS" = "200" ]; then
        success "Proof ready! Downloading..."
        PROOF_FILE="proof_${DIR_NAME}.json"
        curl -s "$ETH_PROVER_SERVICE_URL/proof/$DIR_NAME" -o "$PROOF_FILE"
        info "Saved to: $PROOF_FILE"
        exit 0
    elif [ "$HTTP_STATUS" = "202" ]; then
        info "[${ELAPSED}s] Processing... (HTTP $HTTP_STATUS)"
        echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
        sleep 5
    else
        err "Error (HTTP $HTTP_STATUS) while polling proof"
        echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
        exit 1
    fi
done

