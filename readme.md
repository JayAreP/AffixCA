# Affix/CA

A self-hosted **Public Key Infrastructure (PKI)** platform delivered as a single Docker container. Supports three-tier PKI (Root → Intermediate → Issuing CA) in either **standalone** or **distributed** mode. Includes a web UI for setup, certificate management, topology visualization, CRL distribution, and logging.

---

## Table of Contents

1. [Deployment Options](#deployment-options)
2. [Standalone Deployment](#standalone-deployment)
3. [Distributed Deployment](#distributed-deployment)
4. [First-Run Setup Wizard](#first-run-setup-wizard)
5. [Web Server TLS](#web-server-tls)
6. [Topology & Trust Chain](#topology--trust-chain)
7. [Administration](#administration)
8. [Logging](#logging)
9. [Certificate Templates](#certificate-templates)
10. [API Reference](#api-reference)
11. [Ports & Volumes](#ports--volumes)

---

## Deployment Options

Affix/CA supports two deployment models:

| Mode | Description | Best for |
|---|---|---|
| **Standalone** | Complete three-tier PKI (Root → Intermediate → Issuing) in a single container | Labs, small environments, quick setup |
| **Distributed** | One role per VM/server, each running its own Affix/CA instance | Production environments requiring isolation, air-gapped root CAs, multiple issuing CAs |

Both models use the same container image and the same setup wizard — the only difference is what you select during first-run configuration.

---

## Standalone Deployment

A standalone deployment runs the entire PKI hierarchy in a single container. This is the simplest way to get started.

### Option A — Linux one-liner (recommended)

For production Linux servers (Ubuntu/Debian, RHEL/CentOS/Fedora/Rocky/AlmaLinux):

```bash
curl -fsSL https://raw.githubusercontent.com/JayAreP/affix-ca/main/install.sh | sudo bash
```

The installer handles everything: Docker installation, image pull, systemd service registration, and container startup on port 443.

To customize the install:

```bash
sudo bash install.sh --port 443 --dir /opt/affix-ca --pass "my-secret-passphrase"
```

| Flag | Default | Description |
|---|---|---|
| `--port` | `443` | Host HTTPS port |
| `--dir` | `/opt/affix-ca` | Install directory |
| `--pass` | *(auto-generated)* | CA key passphrase |

After install, manage the service with:

```bash
systemctl start   affix-ca
systemctl stop    affix-ca
systemctl restart affix-ca
docker logs -f affix-ca
```

Re-running the installer on an existing installation will pull the latest image and upgrade in place — all CA data is preserved.

### Option B — Docker Compose

If you prefer to manage the container yourself, use a `docker-compose.yml`:

```yaml
name: affix-ca

secrets:
  ca_pass:
    file: ./secrets/ca-pass.txt

volumes:
  ca-data:

services:
  affix-ca:
    image: ghcr.io/jayarep/affix-ca:latest
    container_name: affix-ca
    hostname: affix-ca
    ports:
      - "443:8443"
      - "80:8080"
    volumes:
      - ca-data:/ca
    secrets:
      - ca_pass
    environment:
      CA_SECRET_FILE: /run/secrets/ca_pass
    restart: unless-stopped
```

```bash
# Create a passphrase file
mkdir -p secrets
openssl rand -base64 48 > secrets/ca-pass.txt

# Start
docker compose up -d
```

Open **https://your-server** to begin the setup wizard.

> The container serves HTTPS using a self-signed certificate on first run. Your browser will show a certificate warning — this is expected.

---

## Distributed Deployment

A distributed deployment places each CA role on its own dedicated VM or server. This provides proper isolation — particularly important for keeping a root CA offline — and allows you to scale issuing CAs independently.

Each node runs the same Affix/CA image and is configured through the setup wizard to serve a single role: **Root**, **Intermediate**, or **Issuing**.

### Planning your topology

A typical three-tier distributed PKI looks like this:

```
┌──────────┐
│  Root CA  │      VM 1  (taken offline after signing the intermediate)
└────┬─────┘
     │
┌────┴─────────────┐
│  Intermediate CA  │  VM 2
└────┬─────────────┘
     │
┌────┴──────┐  ┌───────────┐
│ Issuing 1 │  │ Issuing 2 │  VM 3, VM 4, ...
└───────────┘  └───────────┘
```

You can run as many issuing CAs as needed. Each operates independently with no shared state.

### Deploying each node

Run the same one-liner on each VM. The only thing that changes is what you select in the setup wizard.

```bash
curl -fsSL https://raw.githubusercontent.com/JayAreP/affix-ca/main/install.sh | sudo bash
```

Then open `https://<vm-ip>` and walk through the setup wizard, selecting **Distributed** mode and the appropriate role.

### Setup order

Nodes **must** be configured in top-down order — each child submits a CSR to its parent during setup.

**Step 1 — Root CA** (`https://root-ca-ip`)
- Deployment Mode: **Distributed**
- Role: **Root**
- Key Algorithm: RSA-4096, Validity: 10957 days (30 years)
- No parent URL required

**Step 2 — Intermediate CA** (`https://intermediate-ca-ip`)
- Deployment Mode: **Distributed**
- Role: **Intermediate**
- Parent CA URL: `https://root-ca-ip` — use **Test Connection** to verify reachability
- Key Algorithm: RSA-4096 or ECDSA-P-384, Validity: 5475 days (15 years)

**Step 3 — Issuing CA(s)** (`https://issuing-ca-ip`)
- Deployment Mode: **Distributed**
- Role: **Issuing**
- Parent CA URL: `https://intermediate-ca-ip`
- Key Algorithm: ECDSA-P-384, Validity: 3652 days (10 years)
- Select certificate templates this CA should issue

Repeat Step 3 for each additional issuing CA, all pointing at the same intermediate.

### How nodes connect

During setup, the child CA generates a key pair and CSR, submits it to the parent's `/api/sign-csr` endpoint, and stores the returned signed certificate locally. After initialization, each non-root node refreshes its trust chain from the parent on every server start.

All nodes must be reachable by IP or hostname during setup and for ongoing health/topology features.

### Taking the root CA offline

Once the intermediate CA is signed, the root CA should be taken offline for security:

```bash
sudo systemctl stop affix-ca
```

Bring it back only when you need to sign a new intermediate CA or regenerate the root CRL.

### Updating nodes

When deploying a new version, update nodes **top-down** — root first, then intermediate, then issuing. Re-running the installer on each VM pulls the latest image and recreates the container while preserving all CA data:

```bash
curl -fsSL https://raw.githubusercontent.com/JayAreP/affix-ca/main/install.sh | sudo bash
```

---

## First-Run Setup Wizard

On first access, the server redirects to the setup wizard. Walk through the steps:

| Step | What you configure |
|---|---|
| 1 · Deployment Mode | **Standalone** or **Distributed** |
| 2 · Role | Root, Intermediate, or Issuing (distributed only) |
| 3 · Parent CA | URL of the parent CA (distributed non-root only) |
| 4 · Identity (DN) | Country, State, Locality, Organization, Common Name |
| 5 · Key Algorithm | RSA-2048, RSA-4096, ECDSA-P-256, ECDSA-P-384 |
| 6 · URLs | CDP, AIA, and OCSP distribution point URLs |
| 7 · Templates | Certificate types this issuing CA can issue |
| 8 · Review | Review all settings and set the admin password |

After confirming, the key ceremony runs, configuration is written to the persistent volume, and you're redirected to the login page.

### Default credentials

The setup wizard prompts you to set an admin password. If you skip it, the default credentials are `admin` / `admin`. **Change this immediately.**

---

## Web Server TLS

The container serves HTTPS on port 8443. On first run, it generates a self-signed certificate automatically.

To replace it with a CA-signed certificate:

1. Navigate to **Web Server** in the sidebar
2. Enter the server's hostname and any Subject Alternative Names
3. Click **Generate CSR**
4. Either:
   - **Self-Sign** — use the CA itself to sign the web server cert
   - **Copy/Download** the CSR, submit it to an external CA, and paste the signed certificate back
5. The server restarts automatically with the new certificate

---

## Topology & Trust Chain

### Dashboard

The dashboard displays an interactive hierarchy graph showing this node's position in the PKI — ancestor CAs, the current node, and direct subordinates with health indicators.

### Topology page (distributed mode)

Shows parent CA connectivity status, the full ancestor chain, and a table of all signed subordinates with serial numbers and active/revoked status.

**Evicting a subordinate:** From the Topology page on a root or intermediate CA, click **Evict** to revoke a subordinate's certificate. This revokes the certificate, regenerates the CRL, and updates tracking metadata.

### Trust chain

The **Trust Chain** page shows the full certificate chain with download options:

- **Full Chain (PEM)** — concatenated PEM file (leaf → root)
- **PKCS#7 Bundle (.p7b)** — for Windows/Java trust stores
- **Refresh from Parent** — re-fetch the chain from the parent CA

---

## Administration

### Node configuration

Read-only view of the node's identity, roles, key algorithm, certificate details, and creation date.

### Editable settings

| Setting | Description |
|---|---|
| Parent CA URL | URL of the parent CA (non-root distributed nodes only) |
| CDP URL | CRL Distribution Point for issued certificates |
| AIA URL | Authority Information Access URL |
| OCSP URL | OCSP responder URL |
| DNS Servers | Comma-separated DNS server IPs for container name resolution |

### Decommission

Removes all CA configuration, certificates, keys, and CRLs from the node, returning it to the setup wizard. The current configuration is archived before removal. Requires typing `DECOMMISSION` to confirm.

---

## Logging

Structured, filterable server logs accessible from the **Logs** page in the web UI.

### Categories

| Category | What it captures |
|---|---|
| System | Server startup, route loading, DNS configuration |
| Setup | Setup wizard ceremony steps, CSR submission, chain fetching |
| Admin | Configuration changes, DNS updates, decommission operations |
| Signing | CSR signing requests, success/failure |
| Topology | Subordinate eviction, backfill operations |
| Auth | Authentication events |
| Certificates | Certificate issuance from templates |
| Errors | Uncaught errors with stack traces |

Logs are written to `/ca/logs/server.log` (JSON lines, auto-rotates at 5 MB) and emitted to stdout for `docker logs` compatibility.

---

## Certificate Templates

Templates define what kind of end-entity certificate an issuing CA can sign. Selected during setup and stored in `config.json`.

| Template | Use case | Max validity |
|---|---|---|
| `tls-server` | Web servers, APIs, load balancers | 825 days |
| `tls-client` | Mutual TLS, service mesh, client auth | 825 days |
| `code-signing` | Windows/macOS software signing | 1095 days |
| `smime` | Email encryption (S/MIME) | 825 days |
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
GET /api/health              → { "status": "ok", "initialized": true|false, "caName": "..." }
GET /api/status              → { "roles": [...], "standalone": true, "caName": "...", "stats": {...} }
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
POST /api/sign-csr           Sign a subordinate CA CSR (root/intermediate)
```

### Trust Chain & CRL

```
GET  /api/chain              Full certificate chain (leaf → root)
GET  /api/chain/download     Download chain as PEM or PKCS#7 (?format=pem|p7b)
POST /api/chain/refresh      Re-fetch chain from parent CA
GET  /api/crl/pem            Download CRL as PEM
GET  /api/crl/der            Download CRL as DER
GET  /api/crl/info           CRL metadata (last generated, next update, entries)
POST /api/crl/regenerate     Force CRL regeneration
```

### Topology & Administration

```
GET  /api/topology           Get parent, ancestors, and subordinate relationships
POST /api/subordinates/evict Revoke and untrack a subordinate CA ({ serial, reason })
POST /api/admin/update       Update editable settings
POST /api/admin/decommission Reset node to setup wizard ({ confirm: "DECOMMISSION" })
```

### Logs & Web Server

```
GET  /api/logs               Filtered log entries (?categories=&levels=&limit=)
POST /api/logs/clear         Clear all log entries
GET  /api/webserver/cert     Current web server certificate info
POST /api/webserver/csr      Generate a new CSR for the web server
POST /api/webserver/install  Install a signed certificate (restarts server)
```

---

## Ports & Volumes

### Ports

| Port | Protocol | Purpose |
|---|---|---|
| `8443` | HTTPS | Web UI + all API endpoints |
| `8080` | HTTP | Public PKI distribution only (CRL, AIA, chain, health, sign-csr) |

### Volume

All CA data is stored on the `/ca` mount:

```
/ca/
├── config.json          Instance configuration
├── auth.json            User accounts and credentials
├── logs/server.log      Structured log file (JSON lines)
├── webserver/           Web server TLS cert and key
├── certs/               CA certificate
├── private/             Encrypted CA private key
├── chain/               Parent trust chain
├── crl/                 Certificate revocation lists
├── csr/                 Certificate signing requests
├── db/                  OpenSSL database (index, serial, crlnumber)
├── issued/              Issued certificates (by serial)
└── archive/             Archived configs from decommission
```

> In **standalone** mode, data is organized under `/ca/root/`, `/ca/intermediate/`, and `/ca/issuing/` subdirectories.

Private keys are encrypted with the passphrase from `secrets/ca-pass.txt` and never exist unencrypted on disk.
