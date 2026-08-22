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

The main entry point is (run from within the repository folder):

```bash
bash ./sandbox-up-calico.sh <resource-group-name>
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
.last-resource-group
```

If you already have the required key pair, do not create another one. Make sure the paths used by the script match the files you intend to use.

## Quick start

1. Clone the repository into Cloud Shell:

   ```bash
   git clone https://github.com/P47K0/k8s-whizlabs-sandbox.git
   ```

2. Upload your SSH key pair (`cka-sandbox` and `cka-sandbox.pub`) to the Cloud Shell work directory — **one level above** the cloned repository folder, not inside it.

3. Move into the repository folder:

   ```bash
   cd k8s-whizlabs-sandbox/
   ```

4. Prepare the SSH key permissions and load the key into the agent. This step must be **sourced**, not executed, so the `ssh-agent` environment variables persist in your Cloud Shell session:

   ```bash
   source setup-ssh.sh
   ```

   By default, this looks for the keys one directory above the repo (`../`). Pass a different path as an argument if your keys live elsewhere:

   ```bash
   source setup-ssh.sh /path/to/keys
   ```

   Confirm the key loaded successfully:

   ```bash
   ssh-add -l
   ```

5. Run the sandbox, passing your resource group name as an argument. This must be run from within the repository folder:

   ```bash
   bash sandbox-up-calico.sh rg_sb_centralindia_xxxxx
   ```

   This also saves the resource group name to `.last-resource-group` in the repo folder, so you don't need to type it again.

6. SSH into the control-plane node:

   ```bash
   bash connect.sh control
   ```

   Or the worker node:

   ```bash
   bash connect.sh worker
   ```

## Configuration variables

Common variables include:

| Variable | Purpose | Example |
|---|---|---|
| `LOCATION` | Azure region | `centralindia` |
| `SSH_PUBLIC_KEY` | SSH public key path | `../cka-sandbox.pub` |
| `SSH_PRIVATE_KEY` | SSH private key path | `../cka-sandbox` |
| `CALICO_VERSION` | Calico release | `v3.31.3` |
| `KUBERNETES_MINOR_VERSION` | Kubernetes minor version | `v1.36` |
| `ADMIN_USERNAME` | Administrator username | `azureuser` |

The resource group is passed as a positional CLI argument to `sandbox-up-calico.sh`, not set via an environment variable. Use the variable names defined in the current script if they differ from this table.

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

## Accessing the cluster (SSH into the lab)

The validation and troubleshooting commands below assume you are already logged into the control-plane VM (`pk-vm1`) — not just in Cloud Shell.

Use `connect.sh` to look up the right VM's public IP and SSH into it in one step:

```bash
bash connect.sh control
```

```bash
bash connect.sh worker
```

`connect.sh` reads the resource group from `.last-resource-group` (created automatically by `sandbox-up-calico.sh`), so no argument is needed after a successful sandbox run. To target a different resource group explicitly:

```bash
bash connect.sh control rg_other_sandbox
```

Once connected, `kubectl` is available directly on the control-plane node, since `kubeadm init` configures its kubeconfig automatically.

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

### `setup-ssh.sh` prints a "must be sourced" warning

This script sets `ssh-agent` environment variables that need to persist in your current shell. Run it with `source setup-ssh.sh` (or `. setup-ssh.sh`), not `bash setup-ssh.sh` or `./setup-ssh.sh`.

### `connect.sh` reports no resource group found

`connect.sh` reads the resource group from `.last-resource-group`, written automatically by `sandbox-up-calico.sh` after a successful run. If this file is missing (e.g. it was manually removed, or the sandbox script failed before completing), either re-run the sandbox script or pass the resource group explicitly:

```bash
bash connect.sh control rg_sb_centralindia_xxxxx
```

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
