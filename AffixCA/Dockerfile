# ─── Affix/CA ─────────────────────────────────────────────────────────────────
# Single multi-stage Dockerfile for all CA roles.
# Supports linux/amd64 and linux/arm64.
# Role is determined at runtime via the setup wizard → /ca/config.json.

# ═══════════════════════════════════════════════════════════════════════════════
#  Stage 1 — Base: Debian + PowerShell 7 + Pode + OpenSSL
# ═══════════════════════════════════════════════════════════════════════════════
FROM debian:bookworm-slim AS base

LABEL maintainer="affix-ca" \
      description="Affix/CA — Modular PKI platform (all roles)"

# ── System dependencies ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        openssl \
        jq \
        libicu72 \
        libssl3 \
        libunwind8 \
        locales \
        && locale-gen en_US.UTF-8 \
        && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ── PowerShell 7 via GitHub release (works on amd64 + arm64) ─────────────────
ARG PS_VERSION=7.4.6
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64)  PS_ARCH="x64"   ;; \
         arm64)  PS_ARCH="arm64" ;; \
         *)      echo "Unsupported arch: $ARCH" && exit 1 ;; \
       esac \
    && curl -sSL "https://github.com/PowerShell/PowerShell/releases/download/v${PS_VERSION}/powershell-${PS_VERSION}-linux-${PS_ARCH}.tar.gz" \
         -o /tmp/powershell.tar.gz \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && rm /tmp/powershell.tar.gz

# ── Install Pode ──────────────────────────────────────────────────────────────
RUN pwsh -NoProfile -NonInteractive -Command \
    "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
     Install-Module -Name Pode -Force -Scope AllUsers -MinimumVersion 2.10.0"

WORKDIR /app

# ═══════════════════════════════════════════════════════════════════════════════
#  Stage 2 — Application layer
# ═══════════════════════════════════════════════════════════════════════════════
FROM base

# ── Shared assets ────────────────────────────────────────────────────────────
COPY shared/scripts/         /app/shared/scripts/
COPY shared/openssl/         /app/config/openssl/
COPY shared/templates/       /app/templates/
COPY shared/ui/              /app/ui/

# ── Route files (organized by role) ──────────────────────────────────────────
COPY routes/                 /app/routes/

# ── Unified server entrypoint ────────────────────────────────────────────────
COPY server.ps1              /app/server.ps1

EXPOSE 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -skf https://localhost:8443/api/health || exit 1

ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/server.ps1"]
