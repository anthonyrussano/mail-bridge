#!/usr/bin/env bash
# Entrypoint for the headless Proton Mail Bridge container.
#
#   run    (default) start Bridge non-interactively and expose IMAP/SMTP
#   init   open the Bridge CLI to log in, switch to split mode, read passwords
#   shell  drop into bash for debugging
#
# Optional: GPG_KEY_FILE points at an ASCII-armored, passphrase-less private
# key (e.g. a Docker secret sourced from Vault) used to encrypt the pass store.
# If unset and no key exists yet, one is generated on first start.
set -euo pipefail

IMAP_LISTEN_PORT="${IMAP_LISTEN_PORT:-2143}"
SMTP_LISTEN_PORT="${SMTP_LISTEN_PORT:-2025}"
BRIDGE_IMAP_PORT="${BRIDGE_IMAP_PORT:-1143}"
BRIDGE_SMTP_PORT="${BRIDGE_SMTP_PORT:-1025}"

log() { echo "[entrypoint] $*" >&2; }

setup_keychain() {
  export GNUPGHOME="${HOME}/.gnupg"
  mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

  if [[ -n "${GPG_KEY_FILE:-}" ]]; then
    log "importing GPG key from ${GPG_KEY_FILE}"
    gpg --batch --quiet --import "$GPG_KEY_FILE"
  fi

  if ! gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    log "no GPG key found; generating a passphrase-less key for the pass store"
    gpg --batch --quiet --passphrase '' \
        --quick-gen-key 'mail-bridge <mail-bridge@localhost>' default default never
  fi

  if [[ ! -f "${HOME}/.password-store/.gpg-id" ]]; then
    local fpr
    fpr="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"
    log "initialising pass store with key ${fpr}"
    pass init "$fpr" >/dev/null
  fi
}

case "${1:-run}" in
  run)
    setup_keychain
    # Bridge only listens on localhost; forward container ports to it.
    socat "TCP-LISTEN:${IMAP_LISTEN_PORT},fork,reuseaddr" "TCP:127.0.0.1:${BRIDGE_IMAP_PORT}" &
    socat "TCP-LISTEN:${SMTP_LISTEN_PORT},fork,reuseaddr" "TCP:127.0.0.1:${BRIDGE_SMTP_PORT}" &
    log "starting Bridge (IMAP :${IMAP_LISTEN_PORT}, SMTP :${SMTP_LISTEN_PORT})"
    exec bridge --noninteractive --log-level "${BRIDGE_LOG_LEVEL:-info}"
    ;;
  init)
    setup_keychain
    exec bridge --cli
    ;;
  shell)
    exec bash
    ;;
  *)
    exec "$@"
    ;;
esac
