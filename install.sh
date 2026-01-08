#!/usr/bin/env bash
set -euo pipefail

##############################################
# CONFIGURATION VARIABLES
# YOU CAN EDIT THESE IF NEEDED, OR 
# SET VIA ENVIRONMENT VARIABLES
##############################################
CLUSTER_DIR="${CLUSTER_DIR:-./config}"
CLUSTER_NAME="${CLUSTER_NAME:-zenek}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-./pull-secret.txt}"
SSH_KEY_FILE="${SSH_KEY_FILE:-./ssh/id_rsa.pub}"
AWS_PROFILE="${AWS_PROFILE:-default}"

MASTER_FILE="./instances/master"
WORKER_FILE="./instances/worker"

##############################################
# COLORS & ICONS
##############################################
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

INFO="💡"
SUCCESS="✅"
WARN="⚠️"
ERROR="❌"

log_info() { echo -e "${CYAN}${INFO} $1${RESET}"; }
log_success() { echo -e "${GREEN}${SUCCESS} $1${RESET}"; }
log_warn() { echo -e "${YELLOW}${WARN} $1${RESET}"; }
log_error() { echo -e "${RED}${ERROR} $1${RESET}" >&2; }

##############################################
# PRE-FLIGHT CHECKS
##############################################
preflight_checks() {
  log_info "Checking required commands and files..."

  command -v ./openshift-install >/dev/null 2>&1 || { log_error "openshift-install not found in PATH"; exit 1; }
  [[ -f "$PULL_SECRET_FILE" ]] || { log_error "Pull secret not found: $PULL_SECRET_FILE"; exit 1; }
  [[ -f "$SSH_KEY_FILE" ]] || { log_error "SSH key not found: $SSH_KEY_FILE"; exit 1; }
  [[ -f "$MASTER_FILE" ]] || { log_error "Master instance list not found: $MASTER_FILE"; exit 1; }
  [[ -f "$WORKER_FILE" ]] || { log_error "Worker instance list not found: $WORKER_FILE"; exit 1; }

  aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null || {
    log_error "Cannot authenticate to AWS. Check credentials."
    exit 1
  }

  log_success "Pre-flight checks passed!"
}

##############################################
# AUTO-DETECT BASE DOMAIN
##############################################
detect_base_domain() {
  log_info "Detecting base domain from AWS Route53..."
  HOSTED_ZONES=$(aws route53 list-hosted-zones \
    --profile "$AWS_PROFILE" \
    --query "HostedZones[?Config.PrivateZone==\`false\`].Name" \
    --output text)

  if [[ -z "$HOSTED_ZONES" ]]; then
    log_error "No public hosted zones found in Route53."
    exit 1
  fi

  BASE_DOMAIN=$(echo "$HOSTED_ZONES" | head -n1 | sed 's/\.$//')
  log_success "Using base domain: $BASE_DOMAIN"
}

##############################################
# AUTO-DETECT AWS REGION
##############################################
detect_aws_region() {
  log_info "Detecting AWS region..."

  if [[ -n "${AWS_REGION:-}" ]]; then
    DETECTED_REGION="$AWS_REGION"
  elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    DETECTED_REGION="$AWS_DEFAULT_REGION"
  else
    DETECTED_REGION=$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || true)
  fi

  # Fallback: EC2 metadata
  if [[ -z "$DETECTED_REGION" ]]; then
    if curl -s --max-time 1 http://169.254.169.254/latest/meta-data/ >/dev/null; then
      DETECTED_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}')
    fi
  fi

  [[ -z "$DETECTED_REGION" ]] && { log_error "Could not auto-detect AWS region. Set AWS_REGION or AWS_DEFAULT_REGION."; exit 1; }

  AWS_REGION="$DETECTED_REGION"
  log_success "Using AWS region: $AWS_REGION"
}

##############################################
# SELECT INSTANCE TYPE
##############################################
select_instance_type() {
  local file="$1"
  local role="$2"

  # Print messages to stderr
  echo >&2
  echo -e "${MAGENTA}${INFO} Available ${role} instance types:${RESET}" >&2
  echo "----------------------------------------" >&2

  local i=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    echo "  [$i] $line" >&2
    ((i++))
  done < "$file"

  echo >&2
  read -rp "Choose ${role} instance type by number (default=1): " choice >&2
  [[ -z "$choice" ]] && choice=1

  local total
  total=$(grep -c '' "$file")
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > total)); then
    log_error "Invalid choice. Must be 1..$total"
    exit 1
  fi

  local selected
  selected=$(sed -n "${choice}p" "$file" | cut -d'|' -f1)

  # Print log to stderr
  echo >&2
  echo -e "${GREEN}${SUCCESS} Selected ${role} instance type: $selected${RESET}" >&2

  # Only return the instance type on stdout
  echo "$selected"
}

###############################################
# FETCH AVAILABLE OCP VERSIONS FOR GIVEN MINOR
###############################################
get_ocp_versions() {
    local channel="stable-4.20"

    echo "💡 Fetching OpenShift versions from channel: $channel ..." >&2

    ALL_VERSIONS=$(curl -s "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${channel}" \
        | jq -r '.nodes[].version')

    VERSIONS=$(echo "$ALL_VERSIONS" | grep '^4\.20\.' | sort -V)

    if [[ -z "$VERSIONS" ]]; then
        echo "❌ No OpenShift 4.20 versions found in $channel" >&2
        exit 1
    fi

    # IMPORTANT: print ONLY versions here, NOTHING ELSE
    echo "$VERSIONS"
}

###############################################
# SELECT OCP VERSION
###############################################
select_ocp_version() {
    # Read get_ocp_versions line by line into array
    versions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && versions+=("$line")
    done < <(get_ocp_versions)

    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "❌ No OpenShift versions found!" >&2
        exit 1
    fi

    echo "💡 Available OpenShift ${versions[0]%.*}.x versions:"
    echo "----------------------------------------"

    for i in "${!versions[@]}"; do
        printf "  [%d] %s\n" $((i+1)) "${versions[$i]}"
    done

    # default is last element
    default_choice=${#versions[@]}
    read -p "Choose OpenShift version (default=${versions[$((default_choice-1))]}): " choice

    if [[ -z "$choice" ]]; then
        SELECTED_VERSION="${versions[$((default_choice-1))]}"
    else
        # validate choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#versions[@]} )); then
            echo "❌ Invalid choice. Must be 1..${#versions[@]}" >&2
            exit 1
        fi
        SELECTED_VERSION="${versions[$((choice-1))]}"
    fi

    echo "✅ Selected OpenShift version: $SELECTED_VERSION"
}

##############################################
# SET RELEASE IMAGE
##############################################
set_release_image() {
    RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${SELECTED_VERSION}-x86_64"

    echo "💡 Using release image:"
    echo "   $RELEASE_IMAGE"

    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$RELEASE_IMAGE"

    echo "✅ Release override set successfully."
}

##############################################
# GENERATE INSTALL CONFIG
##############################################
generate_install_config() {

  rm -rf "$CLUSTER_DIR"
  mkdir -p "$CLUSTER_DIR"

  log_info "Generating $CLUSTER_DIR/install-config.yaml ..."

  cat > "$CLUSTER_DIR/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
additionalTrustBundlePolicy: Proxyonly
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      rootVolume:
        iops: 4000
        size: 500
        type: io1
      metadataService:
        authentication: Optional
      type: ${WORKER_INSTANCE_TYPE}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      rootVolume:
        iops: 4000
        size: 500
        type: io1
      metadataService:
        authentication: Optional
      type: ${MASTER_INSTANCE_TYPE}
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${AWS_REGION}
    propagateUserTags: true
    userTags:
      Environment: TESTING
      Owner: Ragnar
publish: External
fips: false
pullSecret: '$(cat ${PULL_SECRET_FILE} | tr -d '\n')'
sshKey: '$(cat ${SSH_KEY_FILE})'
EOF

  log_success "install-config.yaml generated successfully!"
}

##############################################
# MAIN
##############################################
main() {
  preflight_checks
  detect_base_domain
  detect_aws_region

  MASTER_INSTANCE_TYPE=$(select_instance_type "$MASTER_FILE" "master")
  WORKER_INSTANCE_TYPE=$(select_instance_type "$WORKER_FILE" "worker")

  # log_info "Master instance type: ${MASTER_INSTANCE_TYPE}"
  # log_info "Worker instance type: ${WORKER_INSTANCE_TYPE}"
  echo -e "$YELLOW${INFO} -------------------------------------------------${RESET}"

  generate_install_config
  get_ocp_versions
  select_ocp_version
  set_release_image

  log_info "Release image set to:"
  log_info "  $RELEASE_IMAGE"
  log_info "Starting automated OpenShift installation..."
  
  ./openshift-install create cluster --dir "$CLUSTER_DIR" \
  # --log-level debug

  log_success "OpenShift cluster installation complete."
  echo -e "${CYAN}Kubeconfig: ${CLUSTER_DIR}/auth/kubeconfig${RESET}"
  echo -e "${CYAN}Kubeadmin password: ${CLUSTER_DIR}/auth/kubeadmin-password${RESET}"
}

main "$@"