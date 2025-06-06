#!/bin/bash

# Kubeconfig and Vault Manager for IDP
# Part of shlapolosa/idp repository: https://github.com/shlapolosa/idp
# Manages kubeconfigs for multiple clusters with Vault integration

set -e

# Configuration
VAULT_ENABLED="${VAULT_ENABLED:-false}"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_PATH_PREFIX="${VAULT_PATH_PREFIX:-secret/kubeconfigs}"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$HOME/.kube}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/.kube/backups}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if Vault is available and configured
check_vault() {
    if [[ "$VAULT_ENABLED" != "true" ]]; then
        warn "Vault integration disabled. Using local file storage only."
        return 1
    fi
    
    if ! command -v vault >/dev/null 2>&1; then
        warn "Vault CLI not found. Installing..."
        install_vault_cli
    fi
    
    if [[ -z "$VAULT_ADDR" ]]; then
        error "VAULT_ADDR not set. Please configure Vault connection."
    fi
    
    if [[ -z "$VAULT_TOKEN" ]]; then
        # Try to use existing vault token
        if [[ -f "$HOME/.vault-token" ]]; then
            VAULT_TOKEN=$(cat "$HOME/.vault-token")
        else
            error "VAULT_TOKEN not set and no token file found."
        fi
    fi
    
    export VAULT_ADDR VAULT_TOKEN
    
    # Test vault connection
    if ! vault auth -method=token token="$VAULT_TOKEN" >/dev/null 2>&1; then
        error "Failed to authenticate with Vault"
    fi
    
    success "Vault connection verified"
    return 0
}

# Install Vault CLI
install_vault_cli() {
    log "Installing Vault CLI..."
    
    local vault_version="${VAULT_VERSION:-1.15.0}"
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case $arch in
        x86_64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) error "Unsupported architecture: $arch" ;;
    esac
    
    local download_url="https://releases.hashicorp.com/vault/${vault_version}/vault_${vault_version}_${os}_${arch}.zip"
    
    curl -fsSL "$download_url" -o /tmp/vault.zip
    sudo unzip -o /tmp/vault.zip -d /usr/local/bin/
    sudo chmod +x /usr/local/bin/vault
    rm -f /tmp/vault.zip
    
    success "Vault CLI installed: $(vault version)"
}

# Setup Vault secrets engine for kubeconfigs
setup_vault_secrets() {
    if ! check_vault; then
        return 1
    fi
    
    log "Setting up Vault secrets engine..."
    
    # Enable KV v2 secrets engine if not already enabled
    if ! vault secrets list | grep -q "^${VAULT_PATH_PREFIX}/"; then
        vault secrets enable -path="${VAULT_PATH_PREFIX%/*}" kv-v2
    fi
    
    success "Vault secrets engine configured"
}

# Store kubeconfig in Vault
store_kubeconfig_vault() {
    local cluster_name="$1"
    local kubeconfig_content="$2"
    
    if ! check_vault; then
        warn "Vault not available, storing locally only"
        return 1
    fi
    
    log "Storing kubeconfig for $cluster_name in Vault..."
    
    # Encode kubeconfig as base64 for safe storage
    local encoded_config=$(echo "$kubeconfig_content" | base64 -w 0)
    
    # Store in Vault with metadata
    vault kv put "${VAULT_PATH_PREFIX}/${cluster_name}" \
        kubeconfig="$encoded_config" \
        cluster_name="$cluster_name" \
        created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        created_by="$(whoami)" \
        source="idp-deployment"
    
    success "Kubeconfig for $cluster_name stored in Vault"
}

# Retrieve kubeconfig from Vault
retrieve_kubeconfig_vault() {
    local cluster_name="$1"
    local output_file="$2"
    
    if ! check_vault; then
        error "Vault not available for retrieval"
    fi
    
    log "Retrieving kubeconfig for $cluster_name from Vault..."
    
    # Get kubeconfig from Vault
    local encoded_config=$(vault kv get -field=kubeconfig "${VAULT_PATH_PREFIX}/${cluster_name}" 2>/dev/null)
    
    if [[ -z "$encoded_config" ]]; then
        error "Kubeconfig for $cluster_name not found in Vault"
    fi
    
    # Decode and save
    echo "$encoded_config" | base64 -d > "$output_file"
    chmod 600 "$output_file"
    
    success "Kubeconfig for $cluster_name retrieved from Vault"
}

# List kubeconfigs in Vault
list_kubeconfigs_vault() {
    if ! check_vault; then
        warn "Vault not available"
        return 1
    fi
    
    log "Listing kubeconfigs in Vault..."
    
    vault kv list "${VAULT_PATH_PREFIX}/" 2>/dev/null || {
        warn "No kubeconfigs found in Vault"
        return 1
    }
}

# Backup existing kubeconfigs
backup_kubeconfigs() {
    log "Backing up existing kubeconfigs..."
    
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [[ -f "$KUBECONFIG_DIR/config" ]]; then
        cp "$KUBECONFIG_DIR/config" "$BACKUP_DIR/config_${timestamp}"
        success "Main kubeconfig backed up"
    fi
    
    # Backup individual cluster configs
    for config_file in "$KUBECONFIG_DIR"/*.yaml "$KUBECONFIG_DIR"/*.yml; do
        if [[ -f "$config_file" ]]; then
            local basename=$(basename "$config_file")
            cp "$config_file" "$BACKUP_DIR/${basename}_${timestamp}"
        fi
    done
    
    success "Kubeconfigs backed up to $BACKUP_DIR"
}

# Setup kubeconfig for main cluster (EKS)
setup_main_cluster_kubeconfig() {
    local cluster_name="${1:-modern-engineering}"
    local region="${2:-us-west-2}"
    
    log "Setting up kubeconfig for main cluster: $cluster_name"
    
    # Create kubeconfig directory
    mkdir -p "$KUBECONFIG_DIR"
    
    # Update kubeconfig for main cluster
    aws eks update-kubeconfig --region "$region" --name "$cluster_name" --kubeconfig "$KUBECONFIG_DIR/config"
    
    # Set proper permissions
    chmod 600 "$KUBECONFIG_DIR/config"
    
    # Store in Vault if enabled
    if check_vault; then
        store_kubeconfig_vault "$cluster_name" "$(cat "$KUBECONFIG_DIR/config")"
    fi
    
    success "Main cluster kubeconfig configured"
}

# Setup kubeconfig for vCluster
setup_vcluster_kubeconfig() {
    local vcluster_name="$1"
    local namespace="vcluster-$vcluster_name"
    local config_file="$KUBECONFIG_DIR/${vcluster_name}-vcluster.yaml"
    
    log "Setting up kubeconfig for vCluster: $vcluster_name"
    
    # Generate vCluster kubeconfig
    vcluster connect "$vcluster_name" --namespace "$namespace" --print-config > "$config_file"
    
    # Set proper permissions
    chmod 600 "$config_file"
    
    # Store in Vault if enabled
    if check_vault; then
        store_kubeconfig_vault "vcluster-$vcluster_name" "$(cat "$config_file")"
    fi
    
    success "vCluster kubeconfig configured for $vcluster_name"
}

# Create kubeconfig switching functions
create_switching_functions() {
    log "Creating kubeconfig switching functions..."
    
    local bashrc_additions="$HOME/.bashrc_kubeconfig"
    
    cat > "$bashrc_additions" << 'EOF'
# Kubeconfig Management Functions
# Generated by kubeconfig-vault-manager.sh

export KUBECONFIG_DIR="${KUBECONFIG_DIR:-$HOME/.kube}"

# Function to switch to main cluster
use_main() {
    export KUBECONFIG="$KUBECONFIG_DIR/config"
    echo "🔄 Switched to main cluster (modern-engineering)"
    kubectl config current-context
}

# Function to switch to vCluster
use_vcluster() {
    local vcluster_name="$1"
    if [[ -z "$vcluster_name" ]]; then
        echo "Usage: use_vcluster <vcluster-name>"
        echo "Available vClusters:"
        ls -1 "$KUBECONFIG_DIR"/*-vcluster.yaml 2>/dev/null | sed 's/.*\///;s/-vcluster.yaml//' || echo "No vClusters found"
        return 1
    fi
    
    local config_file="$KUBECONFIG_DIR/${vcluster_name}-vcluster.yaml"
    if [[ ! -f "$config_file" ]]; then
        echo "❌ vCluster config not found: $config_file"
        return 1
    fi
    
    export KUBECONFIG="$config_file"
    echo "🔄 Switched to vCluster: $vcluster_name"
    kubectl config current-context
}

# Aliases for common clusters
alias engineering='use_main'
alias dev='use_vcluster modernengg-dev'
alias prod='use_vcluster modernengg-prod'
alias mgmt='use_vcluster modern-engineering'

# Function to show current context
kctx() {
    echo "Current context: $(kubectl config current-context 2>/dev/null || echo 'No context set')"
    echo "Current kubeconfig: ${KUBECONFIG:-$HOME/.kube/config}"
}

# Function to list all available contexts
kctx_list() {
    echo "Available contexts:"
    echo "🔹 Main cluster: use_main (or 'engineering')"
    if ls "$KUBECONFIG_DIR"/*-vcluster.yaml >/dev/null 2>&1; then
        echo "🔹 vClusters:"
        for config in "$KUBECONFIG_DIR"/*-vcluster.yaml; do
            local name=$(basename "$config" -vcluster.yaml)
            echo "  - use_vcluster $name (or '$name' if aliased)"
        done
    fi
}

# Function to retrieve kubeconfig from Vault
restore_from_vault() {
    local cluster_name="$1"
    if [[ -z "$cluster_name" ]]; then
        echo "Usage: restore_from_vault <cluster-name>"
        return 1
    fi
    
    if [[ "$VAULT_ENABLED" == "true" ]] && command -v vault >/dev/null 2>&1; then
        local script_dir="$(dirname "$BASH_SOURCE")"
        "$script_dir/kubeconfig-vault-manager.sh" retrieve "$cluster_name"
    else
        echo "❌ Vault not available or not enabled"
        return 1
    fi
}

EOF

    # Source the functions in .bashrc
    if ! grep -q "source.*bashrc_kubeconfig" "$HOME/.bashrc"; then
        echo "" >> "$HOME/.bashrc"
        echo "# Kubeconfig management functions" >> "$HOME/.bashrc"
        echo "source $bashrc_additions" >> "$HOME/.bashrc"
    fi
    
    success "Kubeconfig switching functions created"
}

# Store credentials and URLs in Vault
store_platform_secrets() {
    if ! check_vault; then
        warn "Vault not available, storing in AWS SSM Parameters instead"
        return 1
    fi
    
    log "Storing platform secrets in Vault..."
    
    # Get platform URLs and credentials
    local dns_engineering=$(kubectl get svc -A -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null | head -1)
    
    if [[ -n "$dns_engineering" ]]; then
        # Store platform secrets
        vault kv put "secret/platform/urls" \
            argocd="https://$dns_engineering/argocd" \
            gitea="https://$dns_engineering/gitea" \
            keycloak="https://$dns_engineering/keycloak" \
            backstage="https://$dns_engineering/" \
            argo_workflows="https://$dns_engineering/argo-workflows" \
            jupyterhub="https://$dns_engineering/jupyterhub"
        
        # Store credentials (if available)
        local argocd_pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
        local gitea_pw=$(kubectl get secrets -n gitea gitea-credential -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
        local keycloak_pw=$(kubectl get secrets -n keycloak keycloak-config -o jsonpath="{.data.KEYCLOAK_ADMIN_PASSWORD}" 2>/dev/null | base64 -d || echo "")
        
        if [[ -n "$argocd_pw" ]]; then
            vault kv put "secret/platform/credentials" \
                argocd_admin_password="$argocd_pw" \
                gitea_admin_password="$gitea_pw" \
                keycloak_admin_password="$keycloak_pw"
        fi
        
        success "Platform secrets stored in Vault"
    else
        warn "Platform services not yet available"
    fi
}

# Function to retrieve platform secrets from Vault
get_platform_secrets() {
    if ! check_vault; then
        warn "Vault not available, checking AWS SSM Parameters instead"
        get_platform_secrets_ssm
        return $?
    fi
    
    local secret_type="${1:-all}"
    
    case $secret_type in
        "urls")
            log "Retrieving platform URLs from Vault..."
            vault kv get -format=json secret/platform/urls 2>/dev/null | jq -r '.data.data // {}' | jq -r 'to_entries[] | "\(.key)=\(.value)"'
            ;;
        "credentials")
            log "Retrieving platform credentials from Vault..."
            vault kv get -format=json secret/platform/credentials 2>/dev/null | jq -r '.data.data // {}' | jq -r 'to_entries[] | "\(.key)=\(.value)"'
            ;;
        "ssh")
            log "Retrieving SSH information from Vault..."
            vault kv get -format=json secret/platform/ssh 2>/dev/null | jq -r '.data.data // {}'
            ;;
        "api-keys")
            log "Retrieving API keys from Vault..."
            vault kv get -format=json secret/platform/api-keys 2>/dev/null | jq -r '.data.data // {}'
            ;;
        "all")
            log "Retrieving all platform secrets from Vault..."
            echo "=== PLATFORM URLS ==="
            get_platform_secrets "urls"
            echo
            echo "=== PLATFORM CREDENTIALS ==="
            get_platform_secrets "credentials"
            echo
            echo "=== SSH ACCESS ==="
            get_platform_secrets "ssh"
            echo
            echo "=== API KEYS ==="
            get_platform_secrets "api-keys"
            ;;
        *)
            error "Unknown secret type: $secret_type. Use: urls, credentials, ssh, api-keys, or all"
            ;;
    esac
}

# Fallback function to get secrets from AWS SSM
get_platform_secrets_ssm() {
    log "Retrieving platform secrets from AWS SSM Parameters..."
    
    echo "=== PLATFORM URLS ==="
    aws ssm get-parameter --name "ArgoCDURL" --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    aws ssm get-parameter --name "GiteaURL" --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    aws ssm get-parameter --name "KeycloakURL" --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    aws ssm get-parameter --name "BackstageURL" --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    
    echo
    echo "=== PLATFORM CREDENTIALS ==="
    aws ssm get-parameter --name "ArgoCDPW" --with-decryption --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    aws ssm get-parameter --name "GiteaPW" --with-decryption --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
    aws ssm get-parameter --name "KeycloakPW" --with-decryption --query "Parameter.Value" --output text 2>/dev/null || echo "Not found"
}

# Function to setup EC2 SSH access from Vault
setup_ssh_from_vault() {
    if ! check_vault; then
        error "Vault not available for SSH setup"
    fi
    
    log "Setting up SSH access from Vault..."
    
    # Get SSH information from Vault
    local ssh_info=$(vault kv get -format=json secret/platform/ssh 2>/dev/null | jq -r '.data.data // {}')
    
    if [[ "$ssh_info" == "{}" ]]; then
        warn "No SSH information found in Vault"
        return 1
    fi
    
    local key_name=$(echo "$ssh_info" | jq -r '.key_name // ""')
    local username=$(echo "$ssh_info" | jq -r '.username // "ubuntu"')
    local instructions=$(echo "$ssh_info" | jq -r '.instructions // ""')
    
    if [[ -n "$key_name" ]]; then
        success "SSH Key Information Retrieved:"
        echo "Key Name: $key_name"
        echo "Username: $username"
        echo "Instructions: $instructions"
        echo
        echo "To use SSH access:"
        echo "1. Download private key: AWS Console > EC2 > Key Pairs > $key_name > Actions > Download"
        echo "2. Set permissions: chmod 400 $key_name.pem"
        echo "3. Get instance IP: aws ec2 describe-instances --filters 'Name=tag:Name,Values=*vscode*' --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"
        echo "4. Connect: ssh -i $key_name.pem $username@<instance-ip>"
    else
        warn "SSH key information incomplete in Vault"
        return 1
    fi
}

# Function to store private key in Vault (for user-provided keys)
store_ssh_key_vault() {
    local key_file="$1"
    local key_name="${2:-$(basename "$key_file" .pem)}"
    
    if [[ -z "$key_file" ]] || [[ ! -f "$key_file" ]]; then
        error "Private key file required: store_ssh_key_vault <key_file> [key_name]"
    fi
    
    if ! check_vault; then
        error "Vault not available for SSH key storage"
    fi
    
    log "Storing SSH private key in Vault..."
    
    # Read private key content
    local private_key_content=$(cat "$key_file")
    
    # Store in Vault
    vault kv patch secret/platform/ssh \
        private_key="$private_key_content" \
        stored_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        stored_by="$(whoami)"
    
    success "SSH private key stored in Vault securely"
    warn "Consider removing local key file for security: rm $key_file"
}

# Function to retrieve private key from Vault
get_ssh_key_vault() {
    local output_file="${1:-id_rsa}"
    
    if ! check_vault; then
        error "Vault not available for SSH key retrieval"
    fi
    
    log "Retrieving SSH private key from Vault..."
    
    # Get private key from Vault
    local private_key=$(vault kv get -field=private_key secret/platform/ssh 2>/dev/null)
    
    if [[ -z "$private_key" ]]; then
        warn "No private key found in Vault"
        echo "You may need to:"
        echo "1. Download from AWS Console and store with: ./kubeconfig-vault-manager.sh store-ssh-key <key_file>"
        echo "2. Or download directly from AWS Console each time"
        return 1
    fi
    
    # Write to file with secure permissions
    echo "$private_key" > "$output_file"
    chmod 600 "$output_file"
    
    success "SSH private key retrieved from Vault: $output_file"
    echo "Use with: ssh -i $output_file ubuntu@<instance-ip>"
}

# Main command handler
main() {
    case "${1:-setup}" in
        "setup")
            backup_kubeconfigs
            setup_vault_secrets
            setup_main_cluster_kubeconfig "${2:-modern-engineering}" "${3:-us-west-2}"
            create_switching_functions
            
            # Setup vCluster configs if available
            for vcluster in "modern-engineering" "modernengg-dev" "modernengg-prod"; do
                if vcluster list | grep -q "$vcluster"; then
                    setup_vcluster_kubeconfig "$vcluster"
                fi
            done
            
            store_platform_secrets
            ;;
        "store")
            local cluster_name="$2"
            local kubeconfig_file="${3:-$KUBECONFIG_DIR/config}"
            [[ -z "$cluster_name" ]] && error "Cluster name required"
            [[ ! -f "$kubeconfig_file" ]] && error "Kubeconfig file not found: $kubeconfig_file"
            store_kubeconfig_vault "$cluster_name" "$(cat "$kubeconfig_file")"
            ;;
        "retrieve")
            local cluster_name="$2"
            local output_file="${3:-$KUBECONFIG_DIR/${cluster_name}.yaml}"
            [[ -z "$cluster_name" ]] && error "Cluster name required"
            retrieve_kubeconfig_vault "$cluster_name" "$output_file"
            ;;
        "list")
            list_kubeconfigs_vault
            ;;
        "backup")
            backup_kubeconfigs
            ;;
        "install-vault")
            install_vault_cli
            ;;
        "get-secrets")
            local secret_type="${2:-all}"
            get_platform_secrets "$secret_type"
            ;;
        "setup-ssh")
            setup_ssh_from_vault
            ;;
        "store-ssh-key")
            local key_file="$2"
            local key_name="$3"
            [[ -z "$key_file" ]] && error "SSH key file required: $0 store-ssh-key <key_file> [key_name]"
            store_ssh_key_vault "$key_file" "$key_name"
            ;;
        "get-ssh-key")
            local output_file="${2:-id_rsa}"
            get_ssh_key_vault "$output_file"
            ;;
        "help"|"-h"|"--help")
            echo "Kubeconfig and Vault Manager"
            echo
            echo "Usage: $0 <command> [options]"
            echo
            echo "Commands:"
            echo "  setup [cluster] [region]    Setup kubeconfigs and Vault integration"
            echo "  store <cluster> [file]      Store kubeconfig in Vault"
            echo "  retrieve <cluster> [file]   Retrieve kubeconfig from Vault"
            echo "  list                        List kubeconfigs in Vault"
            echo "  backup                      Backup existing kubeconfigs"
            echo "  install-vault               Install Vault CLI"
            echo
            echo "Platform Secret Management:"
            echo "  get-secrets [type]          Get platform secrets (urls|credentials|ssh|api-keys|all)"
            echo "  setup-ssh                   Setup SSH access using stored key information"
            echo "  store-ssh-key <file> [name] Store SSH private key in Vault"
            echo "  get-ssh-key [output]        Retrieve SSH private key from Vault"
            echo
            echo "Environment Variables:"
            echo "  VAULT_ENABLED=true|false    Enable Vault integration"
            echo "  VAULT_ADDR=<url>            Vault server address"
            echo "  VAULT_TOKEN=<token>         Vault authentication token"
            echo "  VAULT_PATH_PREFIX=<path>    Vault path prefix (default: secret/kubeconfigs)"
            echo
            echo "Examples:"
            echo "  $0 setup                              # Setup with defaults"
            echo "  $0 setup my-cluster us-east-1        # Custom cluster/region"
            echo "  VAULT_ENABLED=true $0 setup          # With Vault integration"
            echo "  $0 retrieve modern-engineering        # Restore from Vault"
            echo "  $0 get-secrets urls                   # Get platform URLs"
            echo "  $0 setup-ssh                         # Setup SSH access"
            echo "  $0 store-ssh-key ~/.ssh/my-key.pem   # Store SSH key in Vault"
            echo "  $0 get-ssh-key my-key.pem            # Retrieve SSH key from Vault"
            exit 0
            ;;
        *)
            error "Unknown command: $1. Use 'help' for usage information."
            ;;
    esac
}

# Run main function
main "$@"