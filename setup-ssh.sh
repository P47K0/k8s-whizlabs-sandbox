#!/bin/bash
# setup-ssh.sh — prep SSH key permissions and load into agent
# usage: source setup-ssh.sh [key-dir]   (defaults to ../)

# Detect if the script is being sourced or executed directly
(return 0 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "    This script must be sourced, not executed directly."
  echo "    The ssh-agent environment variables won't persist otherwise."
  echo ""
  echo "    Run it as:  source ${BASH_SOURCE[0]} <key-dir>"
  echo "    Or:         . ${BASH_SOURCE[0]} <key-dir>"
  exit 1
fi

set -uo pipefail

KEY_DIR="${1:-../}"

chmod 700 "$KEY_DIR"
chmod 600 "$KEY_DIR/cka-sandbox"
chmod 644 "$KEY_DIR/cka-sandbox.pub"

eval "$(ssh-agent -s)"
ssh-add "$KEY_DIR/cka-sandbox"
