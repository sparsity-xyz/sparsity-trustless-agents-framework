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

# Basic env validation
step "Checking required environment variables"
MISSING=()
[ -z "$EC2_PEM_KEY" ] && MISSING+=(EC2_PEM_KEY)
[ -z "$EC2_USER" ] && MISSING+=(EC2_USER)
[ -z "$EC2_HOST" ] && MISSING+=(EC2_HOST)
if [ ${#MISSING[@]} -gt 0 ]; then
    err "Missing required env vars: ${MISSING[*]}"
    exit 1
fi
if [ ! -f "$EC2_PEM_KEY" ]; then
    err "EC2_PEM_KEY file not found: $EC2_PEM_KEY"
    exit 1
fi
success "Environment validation passed"

# Set default values
DOCKER_IMAGE_NAME=${DOCKER_IMAGE_NAME:-test-app}
EIF_FILE_NAME=${EIF_FILE_NAME:-test-app.eif}
ENCLAVE_MEMORY=${ENCLAVE_MEMORY:-4096}
ENCLAVE_CPU_COUNT=${ENCLAVE_CPU_COUNT:-2}

step "Deployment configuration"
info "Remote: $EC2_USER@$EC2_HOST"
info "Docker image: $DOCKER_IMAGE_NAME"
info "Enclave image file: $EIF_FILE_NAME"
info "Enclave CPU: $ENCLAVE_CPU_COUNT | Memory: ${ENCLAVE_MEMORY}MiB"

# Terminate existing enclaves
step "Terminating existing enclaves on remote"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "HOME=/home/$EC2_USER sudo nitro-cli terminate-enclave --all || true"
success "Termination command executed (ignored errors)"

# Copy src/ to remote
step "Copying source files to remote"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "mkdir -p ~/app"
if scp -i "$EC2_PEM_KEY" -r src/* "$EC2_USER@$EC2_HOST:~/app/"; then
    success "Sources copied"
else
    err "Failed to copy sources"
    exit 1
fi

# Build Docker image
step "Building Docker image on remote"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "cd ~/app && sudo docker build --no-cache --build-arg VSOCK=true --build-arg HTTP=true --build-arg DNS=true -t $DOCKER_IMAGE_NAME ."
success "Docker image built: $DOCKER_IMAGE_NAME"

# Build enclave image
step "Building enclave image (EIF) on remote"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "cd ~/app && sudo nitro-cli build-enclave --docker-uri $DOCKER_IMAGE_NAME --output-file $EIF_FILE_NAME"
success "EIF built: $EIF_FILE_NAME"

# Install nitro-toolkit on host if not already installed
step "Installing nitro-toolkit on remote host"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "python3 -m venv ~/venv"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "/home/ec2-user/venv/bin/python3 -m pip install --upgrade pip"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "~/venv/bin/pip install  --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ nitro-toolkit~=0.0.7-dev6"
success "nitro-toolkit installed/updated"

# Start host proxy
step "Starting host proxy on remote (background)"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "sudo pkill python3 || true"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "sudo ~/venv/bin/python3 -m nitro_toolkit.host.main --vsock --cid 16 --server-port 80 > ~/host.log 2>&1 &"
success "Host proxy started (logging to ~/host.log)"

info "Waiting 2 seconds for host proxy to initialize..."
sleep 2
success "Host proxy warm-up complete"

# Run enclave in debug mode
step "Running enclave in debug mode on remote"
ssh -i "$EC2_PEM_KEY" "$EC2_USER@$EC2_HOST" "cd ~/app && HOME=/home/$EC2_USER sudo nitro-cli run-enclave --eif-path $EIF_FILE_NAME --cpu-count $ENCLAVE_CPU_COUNT --memory $ENCLAVE_MEMORY --debug-mode --enclave-cid 16"
success "Enclave run command executed"
