# Affix/CA

A modular, self-hosted **Public Key Infrastructure (PKI)** platform delivered as a single Docker container. Built on PowerShell 7 + Pode + OpenSSL.

Supports three-tier PKI (Root → Intermediate → Issuing CA) in either **standalone** or **distributed** mode. Includes a full web UI for setup, certificate management, CRL distribution, and web server TLS management.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Linux Install (One-Liner)](#linux-install)
3. [First-Run Setup Wizard](#first-run-setup-wizard)
4. [Web Server TLS](#web-server-tls)
5. [Deploying Multiple Instances](#deploying-multiple-instances)
6. [Factory Reset](#factory-reset)
7. [Certificate Templates](#certificate-templates)
8. [API Reference](#api-reference)
9. [Ports & Volumes](#ports--volumes)
10. [Publishing](#publishing)

---

## Quick Start

### Development (Mac / Windows)

```powershell
# Clone / navigate to the project directory
cd AffixCA

# Build image and start the container
.\build.ps1
```

`build.ps1` does everything automatically:

1. Generates a random passphrase → `secrets/ca-pass.txt`
2. Copies `.env.example` → `.env` if it doesn't exist yet
3. Builds the Docker image (Debian + PowerShell 7 + Pode + OpenSSL)
4. Starts the container via `docker compose`

Once it completes, open **https://localhost** (or whatever port is set in `.env`).

> The container serves HTTPS using a self-signed certificate on first run. Your browser will show a certificate warning — this is expected.

### Docker Compose

```powershell
docker compose up --build -d
```

---

## Linux Install

For production Linux servers (Ubuntu/Debian, RHEL/CentOS/Fedora/Rocky/AlmaLinux):

```bash
sudo bash install.sh
```

The installer:

1. Installs Docker Engine + Compose plugin (if not present)
2. Creates `/opt/affix-ca` with secrets and a `docker-compose.yml`
3. Registers a `affix-ca.service` systemd unit
4. Pulls the image from GHCR and starts the container

Options:

```bash
sudo bash install.sh --port 443 --dir /opt/affix-ca --pass "my-secret-passphrase"
```

| Flag | Default | Description |
|---|---|---|
| `--port` | `443` | Host port to map to the container |
| `--dir` | `/opt/affix-ca` | Install directory |
| `--pass` | *(random)* | CA key passphrase (auto-generated if omitted) |

After install, manage the service with:

```bash
systemctl start   affix-ca
systemctl stop    affix-ca
systemctl restart affix-ca
docker logs -f affix-ca
```

---

## First-Run Setup Wizard

The first time you visit the URL, the server has no `config.json` and automatically redirects to the setup wizard. Work through the 8 steps:

| Step | What you configure |
|---|---|
| 1 · Deployment Mode | **Standalone** (all three tiers in one container) or **Distributed** (one role per container) |
| 2 · Role | Root, Intermediate, or Issuing (distributed only) |
| 3 · Parent CA | URL of the parent CA to submit a CSR to (distributed non-root only) |
| 4 · Identity (DN) | Country, State, Locality, Organization, Common Name |
| 5 · Key Algorithm | RSA-2048, RSA-4096, ECDSA-P-256, ECDSA-P-384 |
| 6 · URLs | CDP, AIA, and OCSP distribution point URLs |
| 7 · Templates | Which certificate types this issuing CA can issue |
| 8 · Review | Review all settings and set the admin password |

After confirming, the ceremony runs, `config.json` is written to the persistent volume, and you're redirected to the login page.

### Default credentials

The setup wizard prompts you to set an admin password. If you skip it, the default credentials are `admin` / `admin`. **Change this immediately.**

### Recommended settings for a standalone deployment

- Mode: **Standalone full PKI**
- Key: **RSA-4096** (most compatible)
- Validity: **10957 days** (30 years) for root
- Templates: select all that apply to your environment

---

## Web Server TLS

The container always serves HTTPS (port 8443 internally). On first run, it generates a self-signed certificate for the web server automatically.

To replace it with a CA-signed certificate:

1. Navigate to **Web Server** in the sidebar
2. Enter the server's hostname and any Subject Alternative Names
3. Click **Generate CSR**
4. Either:
   - **Self-Sign** — use the CA itself to sign the web server cert (convenient for internal use)
   - **Copy/Download** the CSR, submit it to an external CA, and paste the signed certificate back
5. The server restarts automatically with the new certificate

---

## Deploying Multiple Instances

Each container is a self-contained CA node. Instances communicate over HTTPS — a child CA submits a CSR to its parent's `/api/sign-csr` endpoint during setup.

### Example: 3-tier distributed PKI (4 containers)

```yaml
services:
  root-ca:
    image: ghcr.io/jayarep/affix-ca:latest
    ports: ["8443:8443"]
    volumes: ["root-ca-data:/ca"]
    secrets: ["root_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/root_pass
    networks: ["pki"]
    restart: unless-stopped

  policy-ca:
    image: ghcr.io/jayarep/affix-ca:latest
    ports: ["8444:8443"]
    volumes: ["policy-ca-data:/ca"]
    secrets: ["policy_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/policy_pass
    depends_on: ["root-ca"]
    networks: ["pki"]
    restart: unless-stopped

  issuing-ca-1:
    image: ghcr.io/jayarep/affix-ca:latest
    ports: ["8445:8443"]
    volumes: ["issuing-1-data:/ca"]
    secrets: ["issuing_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/issuing_pass
    depends_on: ["policy-ca"]
    networks: ["pki"]
    restart: unless-stopped

  issuing-ca-2:
    image: ghcr.io/jayarep/affix-ca:latest
    ports: ["8446:8443"]
    volumes: ["issuing-2-data:/ca"]
    secrets: ["issuing_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/issuing_pass
    depends_on: ["policy-ca"]
    networks: ["pki"]
    restart: unless-stopped

volumes:
  root-ca-data:
  policy-ca-data:
  issuing-1-data:
  issuing-2-data:

networks:
  pki:
    driver: bridge

secrets:
  root_pass:
    file: ./secrets/root-pass.txt
  policy_pass:
    file: ./secrets/policy-pass.txt
  issuing_pass:
    file: ./secrets/issuing-pass.txt
```

```powershell
docker compose -f docker-compose.multi.yml up -d
```

### Setup order (must follow this sequence)

**Step 1 — Root CA** → https://localhost:8443
- Mode: Distributed
- Role: Root
- Key: RSA-4096, 10957 days
- No parent URL

**Step 2 — Policy/Intermediate CA** → https://localhost:8444
- Mode: Distributed
- Role: Intermediate
- Parent URL: `https://root-ca:8443`
- Click "Test Connection" — must succeed before proceeding
- Key: RSA-4096 or ECDSA-P-384, 5475 days

**Step 3 — Issuing CA 1** → https://localhost:8445
- Mode: Distributed
- Role: Issuing
- Parent URL: `https://policy-ca:8443`
- Key: ECDSA-P-384, 3652 days
- Select templates

**Step 4 — Issuing CA 2** → https://localhost:8446
- Same as Issuing CA 1 — independent node, separate volume, same trust chain

### How instances connect

- During wizard setup, the child CA generates a key pair and CSR, POSTs it to `POST /api/sign-csr` on the parent, and stores the returned certificate locally.
- After init, no ongoing communication between tiers is required. Each issuing CA holds a copy of the full trust chain.
- The parent URL is stored in the child's `config.json` for reference but is not polled at runtime.
- Containers must be reachable by hostname/IP **only during the setup ceremony**.

### Scaling issuing CAs

You can run as many issuing CA instances as needed — add more services to the compose file with unique ports and volumes. Each one goes through the same setup ceremony pointing at the same policy CA. There is no shared state between issuing CAs; they operate independently.

### Root CA offline (air-gap) best practice

Once the intermediate CA is signed, the root CA can be stopped and kept offline:

```powershell
docker compose stop root-ca
```

Bring it back only to sign a new intermediate CA or regenerate root CRLs.

---

## Factory Reset

### Wipe a single instance

Stop the container and remove its data volume:

```powershell
docker compose down
docker volume rm affix-ca_ca-data
```

On next start the setup wizard will appear again.

### Full reset — wipe everything

```powershell
.\fullreset.ps1
```

Prompts for confirmation, then:

1. Runs `docker compose down -v` — stops containers and removes all volumes
2. Regenerates `secrets/ca-pass.txt` with a new random passphrase
3. Deletes `version.txt`

Rebuild and start fresh:

```powershell
.\build.ps1
```

To also remove the Docker images (forces a full image rebuild):

```powershell
.\fullreset.ps1 -RemoveImages
```

To skip the confirmation prompt (e.g. in automation):

```powershell
.\fullreset.ps1 -Force
```

### What a reset touches vs. preserves

| Item | Reset wipes it? |
|---|---|
| CA private keys | Yes (volume removed) |
| Issued certificates | Yes (volume removed) |
| `config.json` | Yes (volume removed) |
| `auth.json` | Yes (volume removed) |
| Web server cert/key | Yes (volume removed) |
| `secrets/ca-pass.txt` | Yes (regenerated) |
| Docker images | No (unless `-RemoveImages`) |
| `.env` | No |
| `docker-compose.yml` | No |

---

## Certificate Templates

Templates define what kind of end-entity certificate an issuing CA can sign. Selected during the setup wizard and stored in `config.json`.

| Template | Use case | Max validity |
|---|---|---|
| `tls-server` | Web servers, APIs, load balancers | 825 days |
| `tls-client` | Mutual TLS, service mesh, client auth | 825 days |
| `code-signing` | Windows/macOS software signing | 1095 days |
| `smime` | Email encryption (PKCS#7 / S/MIME) | 825 days |
| `vpn-server` | IPSec/IKEv2 VPN server | 825 days |
| `vpn-client` | IPSec/IKEv2 VPN client | 825 days |
| `device-auth` | 802.1x NAC, network device certificates | 825 days |
| `smartcard-logon` | Windows smart card / PIV logon | 365 days |
| `wifi-802.1x` | RADIUS EAP-TLS Wi-Fi authentication | 365 days |

---

## API Reference

### Authentication

All API endpoints (except `/api/health`, `/api/setup/status`, and public CRL/chain endpoints) require a Bearer token:

```
Authorization: Bearer <token>
```

Obtain a token via `POST /api/auth/login` with `{ "username": "...", "password": "..." }`.

### Health & Status

```
GET /api/health
→ { "status": "ok", "initialized": true|false }

GET /api/status
→ { "roles": [...], "standalone": true, "caName": "...", "stats": {...}, "tiers": {...} }
```

### Setup

```
POST /api/setup/init         Run the setup ceremony
POST /api/setup/test-parent  Test connectivity to a parent CA URL
GET  /api/setup/status       Check whether this instance is configured
```

### Certificates

```
GET  /api/certificates              List all issued certificates
GET  /api/certificates/:serial      Get a specific certificate
GET  /api/certificates/:serial/pem  Download cert as PEM
POST /api/certificates/:serial/revoke  Revoke a certificate
POST /api/certificates/:serial/pkcs12  Export as PKCS#12 bundle
```

### Certificate Issuance (issuing CA only)

```
POST /api/issue              Issue a new certificate from a template
GET  /api/templates          List available templates
POST /api/sign-csr           Sign an external CSR (root/intermediate use)
```

### Trust Chain & CRL

```
GET  /api/chain              Full certificate chain (leaf → root)
GET  /api/chain/download     Download chain as PEM or PKCS#7
GET  /api/crl/pem            Download CRL as PEM
GET  /api/crl/der            Download CRL as DER
GET  /api/crl/info           CRL metadata (last generated, next update, entries)
POST /api/crl/regenerate     Force CRL regeneration
```

### Web Server Certificate

```
GET  /api/webserver/cert     Current web server certificate info
POST /api/webserver/csr      Generate a new CSR for the web server
POST /api/webserver/install  Install a signed certificate (restarts server)
```

---

## Ports & Volumes

### Default port

| Setting | Default | Override |
|---|---|---|
| Web UI + API (HTTPS) | `443` (host) → `8443` (container) | Set `CA_PORT=8443` in `.env` |

### Volume

All CA data is stored in the `/ca` mount inside the container:

```
/ca/
├── config.json          Instance configuration
├── auth.json            User accounts and credentials
├── webserver/           Web server TLS cert and key
│   ├── server.key
│   └── server.crt
├── root/                Root CA keys, certs, CRL, database
├── intermediate/        Intermediate CA keys, certs, CRL, database
└── issuing/
    ├── certs/           Issuing CA certificate
    ├── private/         Encrypted private key
    ├── issued/          All issued end-entity certificates
    └── crl/             Revocation lists
```

Private keys are encrypted with the passphrase from `secrets/ca-pass.txt` and never exist unencrypted on disk.

### Secret

| File | Purpose |
|---|---|
| `secrets/ca-pass.txt` | Random passphrase used to encrypt all CA private keys. Generated by `build.ps1` or `install.sh`. Never commit this file. |

---

## Publishing

Build and push a multi-platform image (linux/amd64 + linux/arm64) to GHCR:

```powershell
.\publishContainer.ps1 -GitHubUser <username> -Token <ghcr-pat> -ImageName affix-ca
```

Requires a GitHub Personal Access Token (Classic) with `write:packages` scope.
