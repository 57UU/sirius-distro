#!/bin/bash
# sirius-ssh-init.sh: password-login once, install local pubkey for future key auth.
# Run in WSL (needs sshpass). Usage:
#   ./sirius-ssh-init.sh user@host pubkey
# Env: SIRIUS_USER / SIRIUS_PASS (or SIRIUS_SSH / SIRIUS_PUBKEY instead of args)
set -e
TARGET="${1:-${SIRIUS_SSH:-}}"
PUBKEY="${2:-${SIRIUS_PUBKEY:-}}"
if [ -z "$TARGET" ] || [ -z "$PUBKEY" ]; then echo "usage: $0 user@host pubkey" >&2; exit 1; fi
USER="${SIRIUS_USER:-u57u}"
PASS="${SIRIUS_PASS:-1234}"
test -f "$PUBKEY" || { echo "missing pubkey $PUBKEY"; exit 1; }
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8"
echo "=== password login test: $TARGET"
SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "$TARGET" 'echo LOGIN-OK; whoami'
echo "=== installing pubkey"
PUB="$(cat "$PUBKEY")"
BLOB="$(echo "$PUB" | cut -d' ' -f2)"
SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "$TARGET" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -q \"$BLOB\" ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys; echo KEY-INSTALLED"
echo "=== key-login verify (no password)"
PRIV="${PUBKEY%.pub}"
TMPKEY="$(mktemp)"
trap 'rm -f "$TMPKEY"' EXIT
cp "$PRIV" "$TMPKEY"
chmod 600 "$TMPKEY"
ssh $SSH_OPTS -o PasswordAuthentication=no -o IdentitiesOnly=yes -i "$TMPKEY" "$TARGET" 'echo KEY-LOGIN-OK'
