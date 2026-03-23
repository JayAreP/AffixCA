# Affix/CA

A modular, self-hosted **Public Key Infrastructure (PKI)** platform delivered as a single Docker container. Built on PowerShell 7 + PODE + OpenSSL.

Supports three-tier PKI (Root → Intermediate → Issuing CA) in either **standalone** or **distributed** mode. Includes a full web UI for setup, certificate issuance, revocation, CRL management, and trust chain distribution.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [First-Run Setup Wizard](#first-run-setup-wizard)
3. [Deploying Multiple Instances](#deploying-multiple-instances)
4. [Factory Reset](#factory-reset)
5. [Certificate Templates](#certificate-templates)
6. [API Reference](#api-reference)
7. [Ports & Volumes](#ports--volumes)

---

## Quick Start

```powershell
# Clone / navigate to the project directory
cd affixCA

# Build images, generate secrets, and start the stack
.\build.ps1
```

`build.ps1` does everything automatically:

1. Generates a random 255-character passphrase → `secrets/ca-pass.txt`
2. Copies `.env.example` → `.env` if it doesn't exist yet
3. Builds the base Docker image (PowerShell 7 + PODE + OpenSSL)
4. Builds the `affix-ca` application image
5. Starts the container via `docker-compose`

Once it completes, open **http://localhost:8080** (or whatever port is set in `.env`).

---

## First-Run Setup Wizard

The first time you visit the URL, the server has no `config.json` and automatically redirects to the setup wizard. Work through the 7 steps:

| Step | What you configure |
|---|---|
| 1 · Deployment Mode | **Standalone** (all three tiers in one container) or **Distributed** (one role per container) |
| 2 · Role | Root, Intermediate, or Issuing (distributed only) |
| 3 · Parent CA | URL of the parent CA to submit a CSR to (distributed non-root only) |
| 4 · Identity (DN) | Country, State, Locality, Organization, Common Name |
| 5 · Key Algorithm | RSA-2048, RSA-4096, ECDSA-P-256, ECDSA-P-384 |
| 6 · CRL Settings | CRL validity period in days |
| 7 · Templates | Which certificate types this issuing CA can issue |

After confirming, the ceremony runs (10–20 seconds), `config.json` is written to the persistent volume, and the dashboard loads.

### Recommended settings for a standalone deployment

- Mode: **Standalone full PKI**
- Key: **RSA-4096** (most compatible)
- Validity: **10957 days** (30 years) for root
- Templates: select all that apply to your environment

---

## Deploying Multiple Instances

Each container is a self-contained CA node. Instances communicate over HTTP — a child CA submits a CSR to its parent's `/api/sign-csr` endpoint during setup.

### Example: 3-tier distributed PKI (4 containers)

Create a `docker-compose.multi.yml` alongside the default one:

```yaml
services:
  root-ca:
    image: affix-ca:latest
    ports: ["8080:8080"]
    volumes: ["root-ca-data:/ca"]
    secrets: ["root_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/root_pass
    networks: ["pki"]
    restart: unless-stopped

  policy-ca:
    image: affix-ca:latest
    ports: ["8081:8080"]
    volumes: ["policy-ca-data:/ca"]
    secrets: ["policy_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/policy_pass
    depends_on: ["root-ca"]
    networks: ["pki"]
    restart: unless-stopped

  issuing-ca-1:
    image: affix-ca:latest
    ports: ["8082:8080"]
    volumes: ["issuing-1-data:/ca"]
    secrets: ["issuing_pass"]
    environment:
      CA_SECRET_FILE: /run/secrets/issuing_pass
    depends_on: ["policy-ca"]
    networks: ["pki"]
    restart: unless-stopped

  issuing-ca-2:
    image: affix-ca:latest
    ports: ["8083:8080"]
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
docker-compose -f docker-compose.multi.yml up -d
```

### Setup order (must follow this sequence)

**Step 1 — Root CA** → http://localhost:8080
- Mode: Distributed
- Role: Root
- Key: RSA-4096, 10957 days
- No parent URL

**Step 2 — Policy/Intermediate CA** → http://localhost:8081
- Mode: Distributed
- Role: Intermediate
- Parent URL: `http://root-ca:8080`
- Click "Test Connection" — must succeed before proceeding
- Key: RSA-4096 or ECDSA-P-384, 5475 days

**Step 3 — Issuing CA 1** → http://localhost:8082
- Mode: Distributed
- Role: Issuing
- Parent URL: `http://policy-ca:8081`
- Key: ECDSA-P-384, 3652 days
- Select templates

**Step 4 — Issuing CA 2** → http://localhost:8083
- Same as Issuing CA 1 — independent node, separate volume, same trust chain

### How instances connect

- During wizard setup, the child CA generates a key pair and CSR, POSTs it to `POST /api/sign-csr` on the parent, and stores the returned certificate locally.
- After init, no ongoing communication between tiers is required. Each issuing CA holds a copy of the full trust chain.
- The parent URL is stored in the child's `config.json` for reference but is not polled at runtime.
- Containers must be on the same Docker network (or reachable by hostname/IP) **only during the setup ceremony**.

### Scaling issuing CAs

You can run as many issuing CA instances as needed — add more services to the compose file with unique ports and volumes. Each one goes through the same setup ceremony pointing at the same policy CA. There is no shared state between issuing CAs; they operate independently.

Put a load balancer (Nginx, HAProxy, Traefik) in front of multiple issuing CAs to distribute certificate issuance requests.

### Root CA offline (air-gap) best practice

Once the intermediate CA is signed, the root CA can be stopped and kept offline:

```powershell
docker-compose stop root-ca
```

Bring it back only to sign a new intermediate CA or regenerate root CRLs.

---

## Factory Reset

### Wipe a single instance

Stop the container and remove its data volume:

```powershell
docker-compose down
docker volume rm affixca_<service-name>-data
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

### Health & Status

```
GET /api/health
→ { "status": "ok", "initialized": true|false }

GET /api/status
→ { "roles": [...], "standalone": true, "caName": "...", "stats": { "total": 42, "valid": 40, "revoked": 2 }, "tiers": {...} }
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

---

## Ports & Volumes

### Default port

| Setting | Default | Override |
|---|---|---|
| Web UI + API | `8080` | Set `CA_PORT=9000` in `.env` |

### Volume

All CA data is stored in the `/ca` mount inside the container:

```
/ca/
├── config.json          Instance configuration
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
| `secrets/ca-pass.txt` | Random 255-char passphrase used to encrypt all CA private keys. Generated by `build.ps1`. Never commit this file. |
