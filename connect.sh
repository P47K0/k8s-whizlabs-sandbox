#!/bin/bash
# connect.sh — look up a lab VM's public IP and SSH into it
# usage: bash connect.sh <control|worker> [resource-group]
# if resource-group is omitted, falls back to .last-resource-group in this folder

set -euo pipefail

RG_FILE=".last-resource-group"

NODE="${1:-}"

if [[ "$NODE" != "control" && "$NODE" != "worker" ]]; then
  echo "Usage: bash connect.sh <control|worker> [resource-group]"
  exit 1
fi

RESOURCE_GROUP="${2:-}"

if [[ -z "$RESOURCE_GROUP" ]]; then
  if [[ ! -r "$RG_FILE" ]]; then
    echo "❌ No resource group specified and $RG_FILE not found."
    echo "   Run: bash connect.sh $NODE <resource-group>"
    exit 1
  fi

  RESOURCE_GROUP="$(cat "$RG_FILE")"

  if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "❌ $RG_FILE exists but is empty."
    echo "   Run: bash connect.sh $NODE <resource-group>"
    exit 1
  fi
fi

case "$NODE" in
  control) PIP_NAME="pk-vm1-pip" ;;
  worker)  PIP_NAME="pk-vm2-pip" ;;
esac

IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PIP_NAME" \
  --query "ipAddress" \
  --output tsv)

if [[ -z "$IP" ]]; then
  echo "❌ Could not retrieve IP for $PIP_NAME in resource group $RESOURCE_GROUP"
  exit 1
fi

echo "🔗 Connecting to $NODE node ($PIP_NAME) in $RESOURCE_GROUP at $IP..."
exec ssh azureuser@"$IP"
