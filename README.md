# Automated Two-Node Kubernetes Azure Sandbox

This repository provisions and configures a two-node, self-managed Kubernetes cluster on Azure virtual machines.

The setup uses:

- Ubuntu Azure VMs.
- `kubeadm` for Kubernetes bootstrapping.
- `containerd` as the container runtime.
- Calico as the pod network plugin.
- VXLAN cross-node networking.
- Azure NIC IP forwarding for pod traffic between nodes.
- An Azure NSG rule that allows SSH from the current Cloud Shell public IP.

The main entry point is:

```bash
bash ./sandbox-up-calico.sh
```

## What the script does

The parent script automates the complete workflow:

1. Detects the current Cloud Shell public IPv4 address.
2. Passes the address to the Bicep deployment as an SSH `/32` source.
3. Creates the Azure networking resources and two VMs.
4. Enables IP forwarding on both VM NICs.
5. Configures SSH access through the NSG.
6. Installs the Kubernetes prerequisites.
7. Initializes the control-plane node with `kubeadm`.
8. Retrieves the worker join command.
9. Joins the second VM as a worker.
10. Downloads and installs the Calico operator and CRDs.
11. Applies the Calico installation configuration using the selected pod CIDR.
12. Waits for the cluster and Calico to become ready.
13. Runs the configured connectivity checks.

## Prerequisites

You need:

- An Azure subscription or sandbox account.
- Azure Cloud Shell with Bash.
- Azure CLI.
- `curl`, `ssh`, `ssh-agent`, and `scp`.
- Permission to create and update Azure resources in the target resource group.
- The repository files copied into Cloud Shell.

Log in to Azure before running the script if necessary:

```bash
az login
```

Check the active subscription:

```bash
az account show
```

If you have more than one subscription, select the correct one:

```bash
az account set --subscription "<subscription-id-or-name>"
```

## Create the SSH key pair

Create an Ed25519 key pair for the sandbox:

```bash
ssh-keygen -t ed25519 -f ./cka-sandbox -C "cka-sandbox"
```

When prompted for a passphrase, using a passphrase is recommended. This creates:

```text
cka-sandbox       Private key
cka-sandbox.pub   Public key
```

Never commit the private key to GitHub. The `.gitignore` file should include:

```gitignore
cka-sandbox
cka-sandbox.pub
*.pem
*.key
```

If you already have the required key pair, do not create another one. Make sure the paths used by the script match the files you intend to use.

## Set SSH key permissions

Run these commands in the cloud shell from the repository directory:

```bash
chmod 700 .
chmod 600 cka-sandbox
chmod 644 cka-sandbox.pub
```

Start the SSH agent and add the private key:

```bash
eval "$(ssh-agent -s)"
ssh-add ./cka-sandbox
```

Confirm that the key is loaded:

```bash
ssh-add -l
```

If the private key has a passphrase, `ssh-add` will prompt for it.

## Configure the resource group

You can define the resource group directly in `sandbox-up-calico.sh`, for example:

```bash
RESOURCE_GROUP="rg_k8s_sandbox"
```

Alternatively, pass it as an environment variable when starting the script:

```bash
RESOURCE_GROUP="rg_k8s_sandbox" bash ./sandbox-up-calico.sh
```

The environment-variable method is useful when the resource group changes between sandbox sessions.

## Run the sandbox

Make the parent script executable if needed:

```bash
chmod +x ./sandbox-up-calico.sh
```

Then run it:

```bash
bash ./sandbox-up-calico.sh
```

If the script requires explicit key paths, run:

```bash
RESOURCE_GROUP="rg_k8s_sandbox" \
SSH_PUBLIC_KEY="$PWD/cka-sandbox.pub" \
SSH_PRIVATE_KEY="$PWD/cka-sandbox" \
bash ./sandbox-up-calico.sh
```

The script automatically detects the Cloud Shell public IPv4 address with `curl` and adds `/32` before passing it to the Azure deployment. The resulting NSG rule permits SSH only from the current Cloud Shell egress address.

## Configuration variables

Common variables include:

| Variable | Purpose | Example |
|---|---|---|
| `RESOURCE_GROUP` | Azure resource group for the sandbox | `rg_k8s_sandbox` |
| `LOCATION` | Azure region | `centralindia` |
| `SSH_PUBLIC_KEY` | SSH public key path | `$PWD/cka-sandbox.pub` |
| `SSH_PRIVATE_KEY` | SSH private key path | `$PWD/cka-sandbox` |
| `CALICO_VERSION` | Calico release | `v3.31.3` |
| `KUBERNETES_MINOR_VERSION` | Kubernetes minor version | `v1.36` |
| `ADMIN_USERNAME` | Administrator username | `azureuser` |

Use the variable names defined in the current script if they differ from this table.

## Networking notes

The cluster uses Calico with VXLAN cross-node networking. The following settings are important:

- The Azure VM NICs must have IP forwarding enabled.
- Linux IPv4 forwarding must be enabled on both nodes.
- The pod CIDR must match between `kubeadm` and Calico.
- The NSG must allow the required node-to-node traffic.
- The Cloud Shell public IP is used only for SSH access; it is not the pod-network address.

A direct pod-IP test is useful when troubleshooting:

```bash
ping <remote-pod-ip>
```

If this fails, DNS is not involved because the destination is already a numeric IP address. Test DNS separately:

```bash
nslookup kubernetes.default
```

The troubleshooting order should be:

```text
VM access
→ node-to-node private connectivity
→ node readiness
→ Calico status
→ pod-to-pod IP connectivity
→ DNS resolution
→ Service connectivity
```

## Calico installation order

The Calico manifests must be applied in dependency order:

```text
operator-crds.yaml
→ tigera-operator.yaml
→ wait for operator CRDs
→ Calico Installation custom resource
```

Do not apply `Installation` or `APIServer` resources before their CRDs exist. The parent script generates the custom Calico resources with the configured pod CIDR.

## Validation commands

Check the nodes:

```bash
kubectl get nodes -o wide
```

Check all pods:

```bash
kubectl get pods -A -o wide
```

Check Calico status:

```bash
kubectl get tigerastatus
```

Check the Calico system pods:

```bash
kubectl -n calico-system get pods -o wide
```

Check the Azure NIC forwarding setting:

```bash
az network nic show \
  --resource-group "$RESOURCE_GROUP" \
  --name "pk-vm1-nic" \
  --query '{name:name,ipForwarding:enableIPForwarding}' \
  --output table

az network nic show \
  --resource-group "$RESOURCE_GROUP" \
  --name "pk-vm2-nic" \
  --query '{name:name,ipForwarding:enableIPForwarding}' \
  --output table
```

Both NICs should report:

```text
True
```

## Common problems

### SSH waits indefinitely

Check the current Cloud Shell public IP:

```bash
curl -4 -fsS https://ifconfig.me
echo
```

Then verify that the NSG rule `AllowSshFromCloudShell` contains that address with `/32`.

### Calico custom resources are rejected

If Kubernetes reports that `Installation`, `APIServer`, `Goldmane`, or `Whisker` is unknown, the operator CRDs have not been installed or established yet. Apply the operator CRDs first, wait for the CRDs, and only then apply the custom resources.

### Worker script reports `POD_CIDR is required`

The parent script must pass the pod CIDR when invoking the worker provisioning script. The value must be the same one used by `kubeadm init` and the Calico `Installation` resource.

### Pod IP connectivity fails across nodes

Check:

```bash
sysctl net.ipv4.ip_forward
ip -d link show vxlan.calico
ip route
kubectl get tigerastatus
kubectl -n calico-system get pods -o wide
```

Then verify Azure NIC IP forwarding and the NSG node-to-node rules.

## Cleanup

If the resource group is dedicated to this sandbox, deleting it removes all resources inside it:

```bash
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes
```

Use this only when the resource group contains no resources you need to keep.

## Security notes

- Do not commit private SSH keys.
- Restrict the SSH NSG rule to the current Cloud Shell public IP using `/32`.
- Cloud Shell’s public egress IP can change between sessions.
- Delete the sandbox resource group when finished if it is no longer needed.
- Review the scripts before running them in a subscription containing unrelated resources.

## Learning objective

This repository is intended for learning and sandbox use. I created this for CKA preparation. It demonstrates how a self-managed, kubeadm-based Kubernetes cluster is assembled from the infrastructure layer upward:

```text
Azure VMs and networking
→ Linux prerequisites
→ container runtime
→ kubeadm control plane
→ worker join
→ Calico CNI
→ pod networking and DNS validation
```
