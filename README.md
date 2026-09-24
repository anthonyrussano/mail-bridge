# mail-bridge

Headless [Proton Mail Bridge](https://proton.me/mail/bridge) in a container, exposing
IMAP/SMTP so automated agents can read and send mail from Proton addresses.

- **Image:** `ghcr.io/anthonyrussano/mail-bridge` — tags `latest`, `<bridge-version>` (e.g. `3.27.0`), `sha-<commit>`
- **Source of Bridge:** the official `.deb` from `proton.me/download/bridge/`, verified against
  Proton's signing key (`keys/bridge_pubkey.gpg`, fingerprint `D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07`).
  Only the headless `bridge` binary is shipped; the Qt GUI and self-updating launcher are dropped.
- **Updates:** `.github/workflows/bridge-update.yml` polls Proton's stable feed every 6 hours; when a new
  version appears it bumps `BRIDGE_VERSION` in the Dockerfile and builds/pushes a new image. The image is
  also rebuilt weekly for Debian security patches, and Dependabot keeps actions and the base image current.

## Architecture

```
agents ──IMAP 1143 / SMTP 1025 (STARTTLS, Bridge password)──▶ mail-bridge container ──HTTPS──▶ Proton API
   │                                                            (session + pass store in volume)
   └── Vault → secret/proton/bridge = {username, password}
```

## First-time setup

Logging in to Proton needs your account credentials, so it is a one-time interactive step per Bridge
instance. State (session, keychain, cache) lives in the `bridge-data` volume. Each login generates a new
Bridge password, so run **one** long-lived Bridge (e.g. on a LAN server) and point all agents at it rather
than logging in on every device.

```bash
docker compose pull                      # or: docker compose build
docker compose run --rm bridge init      # opens the Bridge CLI
>>> login                                # username, password, then mailbox password (two-password mode)
>>> info                                 # shows the IMAP/SMTP username + Bridge password
>>> exit
docker compose up -d
```

Store the Bridge credentials from `info` in Vault at `secret/proton/bridge` (`username`, `password`).

To keep the pass-store GPG key in Vault instead of generating one, export an ASCII-armored,
passphrase-less key to `secrets/bridge_gpg_key.asc` and uncomment `GPG_KEY_FILE`/`secrets` in
`compose.yaml`.

## Using it from an agent

`examples/agent_mail.py` is a dependency-free client (Python ≥ 3.10):

```bash
export VAULT_ADDR=https://vault.wikip.co    # token from VAULT_TOKEN, ~/.vault-token, or AppRole env
export MAIL_SECRET=proton/bridge MAIL_ADDRESS=orangey@wikip.co
./examples/agent_mail.py list --unseen      # only mail addressed to orangey@wikip.co
./examples/agent_mail.py read 42
./examples/agent_mail.py send friend@example.com "Hello" "Sent by Orangey"   # From: orangey@wikip.co
```

Any IMAP/SMTP library works: host `127.0.0.1`, IMAP `1143`, SMTP `1025`, STARTTLS,
Bridge username/password. Bridge's certificate is self-signed; export it with `cert export`
in the CLI and set `BRIDGE_CA_FILE` to pin it.

## Notes

- **Combined vs split mode:** combined (the default) exposes every address on the account through one
  mailbox and one Bridge login; sending from any address just means setting the `From` header. Split mode
  gives each address its own Bridge login that only sees that address's mail. That's useful if bots should
  be isolated from each other, but not needed to send as them.
- **Proton SMTP submission tokens** (`smtp.protonmail.ch:587`) only *send* mail. Reading requires Bridge.
- **Exposure:** ports are published on `127.0.0.1` unless `BRIDGE_BIND` is set (e.g. `BRIDGE_BIND=10.32.25.x`
  in `.env` on the server). Keep them on the LAN/Tailscale; never expose IMAP/SMTP publicly. Update
  `imap_host` in Vault to the server's address so agents on any device can connect.
- **Hosting on Proxmox:** a small Debian VM with Docker is the simplest option. An unprivileged LXC also
  works but needs `nesting=1,keyctl=1` for Docker. Back up the `bridge-data` volume, which holds the
  logged-in session; don't run two copies of it at once.
- Running `init` while the service is up will conflict on Bridge's lock file; stop it first.

## Development

```bash
docker build -t mail-bridge .
docker run --rm --entrypoint bridge mail-bridge --version
docker compose run --rm bridge shell
```
