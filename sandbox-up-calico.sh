#!/usr/bin/env bash
set -Eeuo pipefail

# Creates the Azure sandbox, installs Kubernetes prerequisites, initializes VM1,
# installs Calico, joins VM2, and prints cluster status.
# Expected companion files:
#   kubernetes-sandbox-bicep.bicep
#   kubernetes-node-install.sh
#   kubernetes-cluster-provision.sh
#
# Example:
#   RESOURCE_GROUP=k8s-sandbox \
#   SSH_SOURCE_ADDRESS_PREFIX='98.133.214.96/32' \
#   CALICO_VERSION=v3.31.3 \
#   ./sandbox-up-calico.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

BICEP_FILE="${BICEP_FILE:-${SCRIPT_DIR}/kubernetes-sandbox-bicep.bicep}"
NODE_INSTALL="${NODE_INSTALL:-${SCRIPT_DIR}/kubernetes-node-install.sh}"
CLUSTER_PROVISION="${CLUSTER_PROVISION:-${SCRIPT_DIR}/kubernetes-cluster-provision.sh}"

RESOURCE_GROUP="rg_sb_"
LOCATION="$(
  az group show \
    --name "$RESOURCE_GROUP" \
    --query location \
    --output tsv
)"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-${SCRIPT_DIR}/cka-sandbox.pub}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-${SCRIPT_DIR}/cka-sandbox}"
KUBERNETES_MINOR_VERSION="${KUBERNETES_MINOR_VERSION:-v1.36}"
SSH_SOURCE_ADDRESS_PREFIX="${SSH_SOURCE_ADDRESS_PREFIX:-}"

# Pin this in real use. It must have matching manifests at the URLs below.
CALICO_VERSION="${CALICO_VERSION:-v3.31.3}"

# The Bicep default is 192.168.0.0/16. The Calico custom resource is generated
# locally from the Bicep output so it always uses the actual pod CIDR.
CALICO_CRD_URL="${CALICO_CRD_URL:-https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml}"
CALICO_OPERATOR_URL="${CALICO_OPERATOR_URL:-https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml}"

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v az >/dev/null || fail 'Azure CLI is required.'
command -v ssh >/dev/null || fail 'ssh is required.'
command -v scp >/dev/null || fail 'scp is required.'
command -v curl >/dev/null || fail 'curl is required to download Calico manifests.'
az account show >/dev/null 2>&1 || fail 'Run az login first.'

if [[ -n "${CLOUD_SHELL_PUBLIC_IP:-}" ]]; then
  log "Using supplied Cloud Shell public IP: $CLOUD_SHELL_PUBLIC_IP"
else
  CLOUD_SHELL_PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://ifconfig.me)" || \
    fail "Could not determine the Cloud Shell public IP with curl"
fi

CLOUD_SHELL_PUBLIC_IP="$(printf '%s' "$CLOUD_SHELL_PUBLIC_IP" | tr -d '[:space:]')"

[[ "$CLOUD_SHELL_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
  fail "Invalid Cloud Shell public IPv4 address: $CLOUD_SHELL_PUBLIC_IP"
  
log "Cloud Shell public IP: $CLOUD_SHELL_PUBLIC_IP"
log "SSH whitelist source: $SSH_SOURCE_ADDRESS_PREFIX"
log "Resource group: $RESOURCE_GROUP"

az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1 || \
  fail "Resource group '$RESOURCE_GROUP' was not found."
  
[[ -n "$LOCATION" ]] || fail "Could not determine the resource-group location."

log "Using resource group '$RESOURCE_GROUP' in '$LOCATION'"

[[ -r "$SSH_PUBLIC_KEY" ]] || fail "SSH public key not readable: $SSH_PUBLIC_KEY"
[[ -r "$SSH_PRIVATE_KEY" ]] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"
[[ -f "$BICEP_FILE" ]] || fail "Bicep file not found: $BICEP_FILE"
[[ -f "$NODE_INSTALL" ]] || fail "Node install script not found: $NODE_INSTALL"
[[ -f "$CLUSTER_PROVISION" ]] || fail "Cluster provision script not found: $CLUSTER_PROVISION"

SSH_OPTIONS=(-i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
PARAM_ARGS=(
  "location=$LOCATION"
  "adminUsername=$ADMIN_USERNAME"
  "sshPublicKey=$(<"$SSH_PUBLIC_KEY")"
)
[[ -n "$SSH_SOURCE_ADDRESS_PREFIX" ]] && PARAM_ARGS+=("sshSourceAddressPrefix=$SSH_SOURCE_ADDRESS_PREFIX")
[[ -n "$CLOUD_SHELL_PUBLIC_IP" ]] && PARAM_ARGS+=("cloudShellPublicIp=$CLOUD_SHELL_PUBLIC_IP")

log 'Creating the resource group if necessary'
az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1 || \
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

log 'Validating the Bicep template'
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters "${PARAM_ARGS[@]}" >/dev/null

DEPLOYMENT_NAME="k8s-sandbox-$(date +%Y%m%d%H%M%S)"
log "Deploying infrastructure as $DEPLOYMENT_NAME"
az deployment group create \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters "${PARAM_ARGS[@]}" >/dev/null

output() {
  az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query "properties.outputs.$1.value" \
    --output tsv
}

VM1_NAME="$(output vm1Name)"
VM2_NAME="$(output vm2Name)"
CONTROL_PLANE_PRIVATE_IP="$(output controlPlanePrivateIp)"
WORKER_PRIVATE_IP="$(output workerPrivateIp)"
POD_CIDR="$(output podCidr)"
SERVICE_CIDR="$(output serviceCidr)"
VM1_PUBLIC_IP="$(output vm1PublicIpAddress)"
VM2_PUBLIC_IP="$(output vm2PublicIpAddress)"

[[ -n "$VM1_NAME" && -n "$VM2_NAME" ]] || fail 'VM name outputs are empty.'
[[ -n "$CONTROL_PLANE_PRIVATE_IP" && -n "$WORKER_PRIVATE_IP" ]] || fail 'Private IP outputs are empty.'
[[ -n "$POD_CIDR" && -n "$SERVICE_CIDR" ]] || fail 'Kubernetes CIDR outputs are empty.'
[[ -n "$VM1_PUBLIC_IP" && -n "$VM2_PUBLIC_IP" ]] || fail 'Public IP outputs are empty.'

cat <<EOF

Deployment outputs:
  VM1 name:             $VM1_NAME
  VM1 public IP:        $VM1_PUBLIC_IP
  VM1 private IP:       $CONTROL_PLANE_PRIVATE_IP
  VM2 name:             $VM2_NAME
  VM2 public IP:        $VM2_PUBLIC_IP
  VM2 private IP:       $WORKER_PRIVATE_IP
  Pod CIDR:             $POD_CIDR
  Service CIDR:         $SERVICE_CIDR
  Calico version:       $CALICO_VERSION
EOF

wait_for_ssh() {
  local host="$1"
  for _ in {1..30}; do
    if ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$host" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}

install_node() {
  local host="$1"

  log "[$host] Copying installation script"

  scp "${SSH_OPTIONS[@]}" "$NODE_INSTALL" \
    "$ADMIN_USERNAME@$host:/tmp/kubernetes-node-install.sh" >/dev/null

  log "[$host] Installing prerequisites"

  ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$host" \
    "chmod +x /tmp/kubernetes-node-install.sh && \
     sudo KUBERNETES_MINOR_VERSION='$KUBERNETES_MINOR_VERSION' \
     /tmp/kubernetes-node-install.sh"

  log "[$host] Installation completed"
}

log 'Waiting for SSH on both VMs'
wait_for_ssh "$VM1_PUBLIC_IP" || fail "SSH unavailable on VM1: $VM1_PUBLIC_IP"
wait_for_ssh "$VM2_PUBLIC_IP" || fail "SSH unavailable on VM2: $VM2_PUBLIC_IP"

log 'Installing Kubernetes prerequisites on VM1 and VM2'

install_node "$VM1_PUBLIC_IP" &
vm1_pid=$!

install_node "$VM2_PUBLIC_IP" &
vm2_pid=$!

vm1_status=0
vm2_status=0

wait "$vm1_pid" || vm1_status=$?
wait "$vm2_pid" || vm2_status=$?

if (( vm1_status != 0 )); then
  fail "Kubernetes prerequisite installation failed on VM1: \
$VM1_PUBLIC_IP (exit code: $vm1_status)"
fi

if (( vm2_status != 0 )); then
  fail "Kubernetes prerequisite installation failed on VM2: \
$VM2_PUBLIC_IP (exit code: $vm2_status)"
fi

log 'Kubernetes prerequisites installed successfully on both VMs'

log 'Initializing the control plane on VM1'
scp "${SSH_OPTIONS[@]}" "$CLUSTER_PROVISION" \
  "$ADMIN_USERNAME@$VM1_PUBLIC_IP:/tmp/kubernetes-cluster-provision.sh" >/dev/null
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "chmod +x /tmp/kubernetes-cluster-provision.sh && \
   sudo CONTROL_PLANE=true \
   POD_CIDR='$POD_CIDR' \
   SERVICE_CIDR='$SERVICE_CIDR' \
   ADVERTISE_ADDRESS='$CONTROL_PLANE_PRIVATE_IP' \
   /tmp/kubernetes-cluster-provision.sh"

CALICO_CRD_FILE="$(mktemp)"
CALICO_OPERATOR_FILE="$(mktemp)"
CALICO_CUSTOM_RESOURCES_FILE="$(mktemp)"

trap 'rm -f "$CALICO_CRD_FILE" "$CALICO_OPERATOR_FILE" "$CALICO_CUSTOM_RESOURCES_FILE"' EXIT

log "Downloading Calico $CALICO_VERSION manifests"

CALICO_BASE_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"

CALICO_CRD_URL="${CALICO_BASE_URL}/operator-crds.yaml"
CALICO_OPERATOR_URL="${CALICO_BASE_URL}/tigera-operator.yaml"

curl --fail --silent --show-error --location \
  --retry 3 \
  --retry-delay 2 \
  --connect-timeout 10 \
  --max-time 120 \
  "$CALICO_CRD_URL" \
  --output "$CALICO_CRD_FILE"

curl --fail --silent --show-error --location \
  --retry 3 \
  --retry-delay 2 \
  --connect-timeout 10 \
  --max-time 120 \
  "$CALICO_OPERATOR_URL" \
  --output "$CALICO_OPERATOR_FILE"

cat >"$CALICO_CUSTOM_RESOURCES_FILE" <<EOF
# Generated by sandbox-up.sh
# Pod CIDR comes from the Bicep deployment output.
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
EOF

log "Copying Calico manifests to VM1"

scp "${SSH_OPTIONS[@]}" "$CALICO_CRD_FILE" \
  "$ADMIN_USERNAME@$VM1_PUBLIC_IP:/tmp/calico-operator-crds.yaml" >/dev/null

scp "${SSH_OPTIONS[@]}" "$CALICO_OPERATOR_FILE" \
  "$ADMIN_USERNAME@$VM1_PUBLIC_IP:/tmp/calico-operator.yaml" >/dev/null

scp "${SSH_OPTIONS[@]}" "$CALICO_CUSTOM_RESOURCES_FILE" \
  "$ADMIN_USERNAME@$VM1_PUBLIC_IP:/tmp/calico-custom-resources.yaml" >/dev/null

log "Installing Calico operator CRDs and Tigera Operator"

ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "sudo cp /etc/kubernetes/admin.conf /tmp/admin.conf && \
   sudo chown $ADMIN_USERNAME:$ADMIN_USERNAME /tmp/admin.conf && \
   export KUBECONFIG=/tmp/admin.conf && \
   kubectl create -f /tmp/calico-operator-crds.yaml && \
   kubectl create -f /tmp/calico-operator.yaml"
   
log "Waiting for Tigera Operator and CRDs"

ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "export KUBECONFIG=/tmp/admin.conf && \
   kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=300s && \
   kubectl wait --for=condition=Established \
     crd/installations.operator.tigera.io \
     --timeout=300s && \
   kubectl wait --for=condition=Established \
     crd/apiservers.operator.tigera.io \
     --timeout=300s && \
   kubectl wait --for=condition=Established \
     crd/goldmanes.operator.tigera.io \
     --timeout=300s && \
   kubectl wait --for=condition=Established \
     crd/whiskers.operator.tigera.io \
     --timeout=300s"   

log "Applying Calico custom resources"

ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "export KUBECONFIG=/tmp/admin.conf && \
   kubectl create -f /tmp/calico-custom-resources.yaml"

log 'Waiting for Calico installation'

ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "export KUBECONFIG=/tmp/admin.conf && \
   for i in \$(seq 1 60); do \
     echo \"Calico status check \$i/60\"; \
     kubectl get tigerastatus 2>/dev/null || true; \
     kubectl -n calico-system get pods -o wide 2>/dev/null || true; \
     status=\$(kubectl get tigerastatus calico \
       -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' \
       2>/dev/null || true); \
     if [[ \"\$status\" == \"True\" ]]; then \
       echo 'Calico is available'; \
       exit 0; \
     fi; \
     sleep 10; \
   done; \
   echo 'Calico did not become available within 10 minutes'; \
   kubectl describe tigerastatus calico || true; \
   kubectl get pods -A -o wide || true; \
   kubectl get events -A --sort-by=.lastTimestamp | tail -n 100 || true; \
   exit 1"

log 'Retrieving the worker join command'

JOIN_COMMAND="$(
  ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
    'sudo cat /root/kubeadm-worker-join.sh'
)"

[[ -n "$JOIN_COMMAND" ]] || fail 'Worker join command is empty.'

: "${POD_CIDR:?POD_CIDR is required}"
: "${SERVICE_CIDR:?SERVICE_CIDR is required}"

log "Joining VM2 as a worker with POD_CIDR=$POD_CIDR"

scp "${SSH_OPTIONS[@]}" "$CLUSTER_PROVISION" \
  "$ADMIN_USERNAME@$VM2_PUBLIC_IP:/tmp/kubernetes-cluster-provision.sh" >/dev/null

ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM2_PUBLIC_IP" \
  "chmod +x /tmp/kubernetes-cluster-provision.sh && \
   sudo env \
     POD_CIDR='$POD_CIDR' \
     SERVICE_CIDR='$SERVICE_CIDR' \
     JOIN_COMMAND='$JOIN_COMMAND' \
     bash /tmp/kubernetes-cluster-provision.sh"

log 'Waiting for both nodes to become Ready'
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "export KUBECONFIG=/tmp/admin.conf && \
   kubectl wait --for=condition=Ready node --all --timeout=300s"

log 'Cluster status'
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USERNAME@$VM1_PUBLIC_IP" \
  "export KUBECONFIG=/tmp/admin.conf && \
   kubectl get nodes -o wide && \
   kubectl get pods -A"

printf '\nCalico Kubernetes sandbox is ready.\n'
