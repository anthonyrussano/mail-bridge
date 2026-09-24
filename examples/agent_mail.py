#!/usr/bin/env python3
"""Minimal mail client for agents talking to the Bridge container.

Credentials are read from Vault KV v2 or, as a fallback, from BRIDGE_USER /
BRIDGE_PASS environment variables. The Vault token comes from VAULT_TOKEN,
then ~/.vault-token, then an AppRole login with VAULT_ROLE_ID/VAULT_SECRET_ID.

    export VAULT_ADDR=https://vault.wikip.co
    export MAIL_SECRET=proton/bridge            # KV path under the "secret/" mount

    ./agent_mail.py --as orangey@wikip.co list --limit 5
    ./agent_mail.py --as orangey@wikip.co read 42
    ./agent_mail.py --as orangey@wikip.co send someone@example.com "Subject" "Body"

The Vault secret holds `username` and `password`: the Bridge IMAP/SMTP
credentials shown by `info` in the Bridge CLI (NOT the Proton account password).

In Bridge's combined mode every address shares one mailbox and one login, so
`--as` (or MAIL_ADDRESS) sets the From address when sending and limits `list`
to mail addressed to that address. Any address on the Proton account can send.
"""
import argparse
import email
import email.policy
import imaplib
import json
import os
import smtplib
import ssl
import sys
import urllib.request
from email.message import EmailMessage

IMAP_HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")
IMAP_PORT = int(os.environ.get("BRIDGE_IMAP_PORT", "1143"))
SMTP_PORT = int(os.environ.get("BRIDGE_SMTP_PORT", "1025"))


def tls_context() -> ssl.SSLContext:
    # Bridge uses a self-signed certificate. Pin it by exporting it from the
    # Bridge CLI (`cert export`) and pointing BRIDGE_CA_FILE at it.
    ca = os.environ.get("BRIDGE_CA_FILE")
    if ca:
        ctx = ssl.create_default_context(cafile=ca)
        ctx.check_hostname = False
        return ctx
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def vault_request(path: str, token: str | None = None, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"{os.environ['VAULT_ADDR'].rstrip('/')}/v1/{path}",
        data=json.dumps(body).encode() if body else None,
        headers={"X-Vault-Token": token} if token else {},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def credentials() -> tuple[str, str]:
    if "VAULT_ADDR" not in os.environ:
        return os.environ["BRIDGE_USER"], os.environ["BRIDGE_PASS"]
    token = os.environ.get("VAULT_TOKEN")
    token_file = os.path.expanduser("~/.vault-token")
    if not token and os.path.exists(token_file):
        with open(token_file) as f:
            token = f.read().strip()
    if not token:
        login = vault_request(
            "auth/approle/login",
            body={"role_id": os.environ["VAULT_ROLE_ID"], "secret_id": os.environ["VAULT_SECRET_ID"]},
        )
        token = login["auth"]["client_token"]
    mount = os.environ.get("VAULT_KV_MOUNT", "secret")
    data = vault_request(f"{mount}/data/{os.environ['MAIL_SECRET']}", token=token)["data"]["data"]
    return data["username"], data["password"]


def imap_connect(user: str, password: str) -> imaplib.IMAP4:
    conn = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
    conn.starttls(ssl_context=tls_context())
    conn.login(user, password)
    return conn


def cmd_list(args, user, password):
    with imap_connect(user, password) as imap:
        imap.select(args.folder, readonly=True)
        criteria = ["UNSEEN" if args.unseen else "ALL"]
        if args.address:
            criteria += ["TO", f'"{args.address}"']
        _, data = imap.uid("search", None, *criteria)
        uids = data[0].split()[-args.limit:]
        for uid in reversed(uids):
            _, msg = imap.uid("fetch", uid, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
            hdr = email.message_from_bytes(msg[0][1], policy=email.policy.default)
            print(f"{uid.decode():>6}  {hdr['Date']}  {hdr['From']}  {hdr['Subject']}")


def cmd_read(args, user, password):
    with imap_connect(user, password) as imap:
        imap.select(args.folder, readonly=not args.mark_seen)
        _, msg = imap.uid("fetch", args.uid, "(RFC822)" if args.mark_seen else "(BODY.PEEK[])")
        m = email.message_from_bytes(msg[0][1], policy=email.policy.default)
        for h in ("From", "To", "Date", "Subject"):
            print(f"{h}: {m[h]}")
        body = m.get_body(preferencelist=("plain", "html"))
        print()
        print(body.get_content() if body else "(no text body)")


def cmd_send(args, user, password):
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = args.address or user, args.to, args.subject
    msg.set_content(args.body)
    with smtplib.SMTP(IMAP_HOST, SMTP_PORT, timeout=30) as smtp:
        smtp.starttls(context=tls_context())
        smtp.login(user, password)
        smtp.send_message(msg)
    print(f"sent to {args.to}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--as", dest="address", default=os.environ.get("MAIL_ADDRESS"),
                   help="Proton address to act as (From when sending, To filter when listing)")
    sub = p.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("--folder", default="INBOX")
    ls.add_argument("--limit", type=int, default=10)
    ls.add_argument("--unseen", action="store_true")
    rd = sub.add_parser("read")
    rd.add_argument("uid")
    rd.add_argument("--folder", default="INBOX")
    rd.add_argument("--mark-seen", action="store_true")
    sd = sub.add_parser("send")
    sd.add_argument("to")
    sd.add_argument("subject")
    sd.add_argument("body")
    args = p.parse_args()

    user, password = credentials()
    {"list": cmd_list, "read": cmd_read, "send": cmd_send}[args.cmd](args, user, password)


if __name__ == "__main__":
    try:
        main()
    except (imaplib.IMAP4.error, smtplib.SMTPException, OSError) as e:
        sys.exit(f"error: {e}")
