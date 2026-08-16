#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

CONTROL_PLANE="${CONTROL_PLANE:-false}"
POD_CIDR="${POD_CIDR:?POD_CIDR is required}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
ADVERTISE_ADDRESS="${ADVERTISE_ADDRESS:-}"
JOIN_COMMAND="${JOIN_COMMAND:-}"
KUBEADM_CONFIG="/root/kubeadm-config.yaml"

if [[ "$CONTROL_PLANE" == 'true' ]]; then
  [[ -z "$JOIN_COMMAND" ]] || { echo 'Do not specify JOIN_COMMAND with CONTROL_PLANE=true.' >&2; exit 1; }
  [[ -n "$ADVERTISE_ADDRESS" ]] || { echo 'ADVERTISE_ADDRESS is required.' >&2; exit 1; }

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo 'Control plane is already initialized; nothing to do.'
    exit 0
  fi

  cat >"$KUBEADM_CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ADVERTISE_ADDRESS}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: kubernetes
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${ADVERTISE_ADDRESS}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

  kubeadm init --config "$KUBEADM_CONFIG" --upload-certs

  install -d -m 0700 /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  chmod 0600 /root/.kube/config

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    install -d -m 0700 "$USER_HOME/.kube"
    cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$SUDO_USER":"$SUDO_USER" "$USER_HOME/.kube"
  fi

  kubeadm token create --print-join-command >/root/kubeadm-worker-join.sh
  chmod 0700 /root/kubeadm-worker-join.sh
  echo 'Control plane initialized. Join command: /root/kubeadm-worker-join.sh'
else
  [[ -n "$JOIN_COMMAND" ]] || { echo 'JOIN_COMMAND is required for a worker.' >&2; exit 1; }

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo 'Worker is already joined; nothing to do.'
    exit 0
  fi

  read -r -a JOIN_ARGS <<<"$JOIN_COMMAND"
  [[ "${JOIN_ARGS[0]:-}" == 'kubeadm' && "${JOIN_ARGS[1]:-}" == 'join' ]] || {
    echo 'JOIN_COMMAND must start with: kubeadm join' >&2
    exit 1
  }
  kubeadm "${JOIN_ARGS[@]:1}"
  echo 'Worker joined the cluster.'
fi
