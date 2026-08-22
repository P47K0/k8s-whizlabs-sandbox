#!/usr/bin/env bash
set -Eeuo pipefail
KUBERNETES_MINOR_VERSION="${KUBERNETES_MINOR_VERSION:-v1.36}"
NODE_ROLE="${NODE_ROLE:-worker}"  # "control" or "worker"

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

apt-get update

# OS-level prerequisites and kube-proxy/kubeadm preflight dependencies
apt-get install -y --no-install-recommends \
  apt-transport-https ca-certificates curl gpg containerd \
  conntrack socat ebtables ethtool

# etcd-client is only needed on the control-plane node (etcd runs there)
if [[ "$NODE_ROLE" == "control" ]]; then
  apt-get install -y --no-install-recommends etcd-client
fi

swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system
install -d -m 0755 /etc/containerd
containerd config default >/etc/containerd/config.toml
# Support both common containerd configuration layouts.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR_VERSION}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update

# kubectl is only needed on the control-plane node
if [[ "$NODE_ROLE" == "control" ]]; then
  apt-get install -y --no-install-recommends kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
else
  apt-get install -y --no-install-recommends kubelet kubeadm
  apt-mark hold kubelet kubeadm
fi

# CKA practice tools — not required by kubeadm, but useful for hands-on troubleshooting
apt-get install -y --no-install-recommends cri-tools bash-completion jq

systemctl enable kubelet
systemctl restart kubelet || true
printf 'Installed containerd, kubelet, kubeadm%s using %s (role: %s).\n' \
  "$( [[ "$NODE_ROLE" == "control" ]] && echo ', kubectl, and etcd-client' )" \
  "$KUBERNETES_MINOR_VERSION" "$NODE_ROLE"
