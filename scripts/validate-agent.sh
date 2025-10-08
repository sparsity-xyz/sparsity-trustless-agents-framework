#!/bin/bash
set -e

# Color helpers
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
    err " .env file not found"
    exit 1
fi
source .env

step "Loaded .env file"

# Check required variables
step "Checking required environment variables"
if [ -z "$REGISTRY" ] || [ -z "$RPC_URL" ] || [ -z "$PRIVATE_KEY" ]; then
    err "REGISTRY, RPC_URL, and PRIVATE_KEY must be set in .env"
    exit 1
else
    success "Required environment variables present"
fi

# Default parameters (can be overridden by environment or CLI)
PROOF_PATH=${PROOF_PATH:-proof.json}
AGENT_URL=${AGENT_URL:-"http://example.com"}
TEE_ARCH=${TEE_ARCH:-"nitro"}

# CLI argument parsing to allow passing proof path
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--proof-path)
            if [[ -n "$2" && "$2" != -* ]]; then
                PROOF_PATH="$2"
                shift 2
            else
                echo "Error: $1 requires a value"
                exit 1
            fi
            ;;
        --proof-path=*)
            PROOF_PATH="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--proof-path PATH]"
            echo
            echo "Options:"
            echo "  -p, --proof-path PATH   Path to proof JSON (overrides .env PROOF_PATH)"
            echo "  -h, --help              Show this help message"
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1"
            exit 1
            ;;
    esac
done

step "Starting validation against TEEValidationRegistry"
info "Registry: $REGISTRY"
info "Agent URL: $AGENT_URL"
info "TEE Arch: $TEE_ARCH"
info "Proof path: $PROOF_PATH"
echo

# Ensure proof file exists
step "Checking proof file exists"
if [ ! -f "$PROOF_PATH" ]; then
    err "Proof file not found at '$PROOF_PATH'"
    exit 1
else
    success "Found proof file: $PROOF_PATH"
fi

step "Parsing proof JSON"
JOURNAL=$(jq -r '.raw_proof.journal' "$PROOF_PATH")
ONCHAIN_PROOF=$(jq -r '.onchain_proof' "$PROOF_PATH")
PROOF_TYPE=$(jq -r '.proof_type' "$PROOF_PATH")
ZK_TYPE=$(jq -r '.zktype' "$PROOF_PATH")
success "Parsed proof JSON"

# Verify proof type
step "Verifying proof type"
if [ "$PROOF_TYPE" != "Verifier" ]; then
    err "Expected proof_type 'Verifier', got: $PROOF_TYPE"
    exit 1
else
    success "Proof type is 'Verifier'"
fi

# Convert zktype to enum value (0 = Risc0, 1 = SP1)
# Convert zktype to enum value (1 = Risc0, 2 = Succinct)
step "Converting zktype to enum"
if [ "$ZK_TYPE" = "Risc0" ]; then
    ZK_TYPE_ENUM=1
    success "ZK type: Risc0 -> enum $ZK_TYPE_ENUM"
elif [ "$ZK_TYPE" = "Succinct" ]; then
    ZK_TYPE_ENUM=2
    success "ZK type: Succinct -> enum $ZK_TYPE_ENUM"
else
    err "Unknown zktype: $ZK_TYPE"
    exit 1
fi

# Convert TEE arch to bytes32
TEE_ARCH_BYTES32=$(echo -n "$TEE_ARCH" | xxd -p | tr -d '\n' | awk '{printf "0x%-64s\n", $0}' | sed 's/ /0/g')

step "Converted values"
info "TEE Arch (bytes32): $TEE_ARCH_BYTES32"
info "ZK Type (enum): $ZK_TYPE_ENUM ($ZK_TYPE)"
echo

# First check if zkVerifier is set
step "Checking zkVerifier in registry"
ZK_VERIFIER=$(cast call "$REGISTRY" "zkVerifier()(address)" --rpc-url "$RPC_URL")
info "zkVerifier: $ZK_VERIFIER"

if [ "$ZK_VERIFIER" = "0x0000000000000000000000000000000000000000" ]; then
    err "zkVerifier is not set in registry"
    exit 1
else
    success "zkVerifier present: $ZK_VERIFIER"
fi

echo

# Call validateAgent with correct parameter order from interface
step "Calling validateAgent on registry (sending transaction)"
RESULT=$(cast send "$REGISTRY" \
    "validateAgent(string,bytes32,uint8,bytes,bytes)" \
    "$AGENT_URL" \
    "$TEE_ARCH_BYTES32" \
    "$ZK_TYPE_ENUM" \
    "$JOURNAL" \
    "$ONCHAIN_PROOF" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --gas-limit 3000000 \
    --json)

info "Transaction result (raw):"
echo "$RESULT"
success "Transaction submitted"

# Extract agent ID from event logs (second topic in the AgentValidated event)
AGENT_ID=$(echo "$RESULT" | jq -r '.logs[0].topics[1]' 2>/dev/null)

if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "null" ]; then
    # Convert hex to decimal
    AGENT_ID_DEC=$((AGENT_ID))
    echo
    success "Agent validated successfully!"
    info "Agent ID: $AGENT_ID_DEC (hex: $AGENT_ID)"
else
    echo
    success "Agent validated successfully!"
    warn "Could not extract agent ID from transaction"
fi

