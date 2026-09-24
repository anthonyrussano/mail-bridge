# syntax=docker/dockerfile:1

# Proton Mail Bridge version to package. Bumped automatically by
# .github/workflows/bridge-update.yml when Proton publishes a new stable release.
ARG BRIDGE_VERSION=3.27.0
ARG DEBIAN_TAG=trixie-slim

# ---------------------------------------------------------------------------
# Stage 1: download the official .deb from proton.me, verify Proton's GPG
# signature against the pinned key in keys/, and extract the headless binary.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BRIDGE_VERSION
# Fingerprint of "Proton Technologies AG (ProtonMail Bridge developers)"
ARG BRIDGE_SIGNING_FPR=D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY keys/bridge_pubkey.gpg .
RUN set -eux; \
    deb="protonmail-bridge_${BRIDGE_VERSION}-1_amd64.deb"; \
    curl -fsSLo "$deb"     "https://proton.me/download/bridge/${deb}"; \
    curl -fsSLo "$deb.sig" "https://proton.me/download/bridge/${deb}.sig"; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --import bridge_pubkey.gpg; \
    gpg --batch --status-fd 1 --verify "$deb.sig" "$deb" \
      | grep -q "^\[GNUPG:\] VALIDSIG ${BRIDGE_SIGNING_FPR} "; \
    dpkg-deb -x "$deb" pkg; \
    install -Dm755 pkg/usr/lib/protonmail/bridge/bridge /out/bridge; \
    /out/bridge --version 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime. Only the headless Go binary is shipped (the Qt GUI
# and launcher are dropped), so Bridge cannot self-update inside the container;
# new versions arrive as new images instead.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}
ARG BRIDGE_VERSION

LABEL org.opencontainers.image.title="mail-bridge" \
      org.opencontainers.image.description="Headless Proton Mail Bridge exposing IMAP/SMTP for automation" \
      org.opencontainers.image.source="https://github.com/anthonyrussano/mail-bridge" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${BRIDGE_VERSION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates gnupg pass socat tini libsecret-1-0 libfido2-1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1000 --shell /bin/bash bridge

COPY --from=fetch /out/bridge /usr/local/bin/bridge
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER bridge
WORKDIR /home/bridge
# Bridge state: login session, pass store, GPG key, message cache.
VOLUME ["/home/bridge"]

# 2143 -> Bridge IMAP (127.0.0.1:1143), 2025 -> Bridge SMTP (127.0.0.1:1025)
EXPOSE 2143 2025

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/1143 && </dev/tcp/127.0.0.1/1025' || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["run"]
