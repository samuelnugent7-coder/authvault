# AuthVault

> Self-hosted password manager + TOTP authenticator. Zero cloud, zero subscriptions — runs on your own machine, accessible anywhere via [Tailscale](https://tailscale.com/).

<p align="center">
  <a href="https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest">
    <img src="https://img.shields.io/github/v/release/Nugent-Brothers-Enterprises/authvault?style=flat-square&label=latest" />
  </a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Android%20%7C%20Linux-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/encryption-AES--256--GCM-green?style=flat-square" />
</p>

---

## Download

| Platform | File | Notes |
|----------|------|-------|
| **Windows** (API server) | [authvault-api.exe](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/authvault-api.exe) | Runs the backend |
| **Windows** (Desktop app) | [AuthVault-Windows.zip](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/AuthVault-Windows.zip) | Flutter GUI |
| **Android** | [AuthVault-Android.apk](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/AuthVault-Android.apk) | Sideload or install direct |
| **Linux** (API server) | [authvault-api-linux](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/authvault-api-linux) | amd64 binary |

---

## Quick Install

### Linux (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/Nugent-Brothers-Enterprises/authvault/main/install.sh | bash
```

This downloads the latest binary, installs it to `/opt/authvault`, and sets up a **systemd service** that auto-starts on boot.

Options:
```bash
bash install.sh --dir /usr/local/authvault --port 9443 --no-service
```

### Windows (PowerShell, run as Administrator)

```powershell
irm https://raw.githubusercontent.com/Nugent-Brothers-Enterprises/authvault/main/install.ps1 | iex
```

This installs the API to `C:\Program Files\AuthVault`, registers a Windows Service, and adds it to PATH. Supports [NSSM](https://nssm.cc/) if installed.

---

## Getting Started

### Step 1 — Run the API server

**First launch only** (sets up config, prints your client secret):

```bash
# Linux
cd /opt/authvault && ./authvault-api

# Windows
cd "C:\Program Files\AuthVault" && .\authvault-api.exe
```

On first run it will:
1. Generate `config.json` in the same folder
2. Print your **client secret** — copy this, you need it for the app
3. Create `vault.db` (SQLite, AES-256-GCM encrypted)

### Step 2 — Install the app

- **Windows:** Unzip [AuthVault-Windows.zip](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/AuthVault-Windows.zip) and run `authvault_desktop.exe`
- **Android:** Install [AuthVault-Android.apk](https://github.com/Nugent-Brothers-Enterprises/authvault/releases/latest/download/AuthVault-Android.apk)

### Step 3 — Connect the app

1. Open app ? tap **gear icon** (Settings)
2. Set **API Server URL** ? `http://<server-ip>:8443`
3. Paste your **client secret**
4. Enter your **master password** and login

> Use [Tailscale](https://tailscale.com/) to reach your home server from anywhere without port forwarding.

---

## Running as a Service

### Linux

```bash
sudo systemctl start authvault
sudo journalctl -u authvault -f
```

### Windows (NSSM)

```batch
nssm install AuthVaultAPI "C:\Program Files\AuthVault\authvault-api.exe"
nssm start AuthVaultAPI
```

---

## Security Model

| Layer | Mechanism |
|-------|-----------|
| Transport | Tailscale WireGuard — no open ports needed |
| API auth | JWT signed with HMAC-SHA256 secret |
| Password verification | Argon2id (3 passes, 64 MB, 4 threads) |
| Data at rest | AES-256-GCM, key derived from master password |
| Session key | RAM only — wiped on logout/restart |

> **The master password is never stored.** Only an Argon2id hash is saved.

---

## Features

| Category | Feature |
|----------|---------|
| Auth | TOTP / 2FA codes, QR export |
| Passwords | Folder tree, custom fields, password history |
| Security | Recycle bin, record versions, duress/decoy vault |
| Security | Data integrity check, session management |
| Import | CSV (1Password / Bitwarden / LastPass), Accounts.json, safe.xml |
| Notes | Encrypted secure notes |
| Organisation | Tags with colour coding, shared folders |
| Sharing | Time-limited share links, API keys |
| Backup | Encrypted S3 backup, local snapshot system |
| Alerts | Email alerts (SMTP / AWS SES) |
| Admin | User management, expiry, audit log |
| SSH | SSH key vault |
| Dashboard | Vault health overview |
| Generator | Configurable password generator |

---

## API Keys

API keys let you access AuthVault from scripts, home-automation tools, or any HTTP client — no session, no cookie, just a static secret.

### Create a key

**In the app:** Settings ? API Keys ? **+** ? give it a name and optional expiry.

**Or via curl / any HTTP client:**
```bash
# First get a JWT by logging in
TOKEN=$(curl -sk -X POST https://<host>:8443/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"your-master-password","client_secret":"..."}' \
  | jq -r .token)

# Create the key
curl -sk -X POST https://<host>:8443/api/v1/api-keys \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"home-automation","expires_at":0}'
# returns: {"key_full":"av_abc123..."}  ? save this, shown ONCE
```

### Use a key

Prefix the key with `Bearer ` in the `Authorization` header — it works on **every endpoint** that normally requires a JWT:

```bash
API_KEY="av_abc123..."

# List TOTP entries
curl -sk https://<host>:8443/api/v1/totp \
  -H "Authorization: Bearer $API_KEY"

# Read the password safe
curl -sk https://<host>:8443/api/v1/safe/folders \
  -H "Authorization: Bearer $API_KEY"

# Add a TOTP entry
curl -sk -X POST https://<host>:8443/api/v1/totp \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"name":"GitHub","secret":"JBSWY3DPEHPK3PXP","issuer":"github.com"}'

# Create a password record
curl -sk -X POST https://<host>:8443/api/v1/safe/records \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"folder_id":1,"name":"My Site","username":"me@example.com","password":"s3cr3t"}'

# Generate a password
curl -sk "https://<host>:8443/api/v1/generator?length=24&symbols=true" \
  -H "Authorization: Bearer $API_KEY"
```

### Manage keys

```bash
# List your keys
curl -sk https://<host>:8443/api/v1/api-keys \
  -H "Authorization: Bearer $TOKEN"

# Revoke a key
curl -sk -X POST https://<host>:8443/api/v1/api-keys/3/revoke \
  -H "Authorization: Bearer $TOKEN"

# Delete a key permanently
curl -sk -X DELETE https://<host>:8443/api/v1/api-keys/3 \
  -H "Authorization: Bearer $TOKEN"
```

> **Security tip:** API keys are stored as SHA-256 hashes — the full key is shown **once** at creation. Treat it like a password.

---

## S3 Backup

The scheduler runs a full encrypted backup every **12 hours** (configurable via `s3_backup_interval_hours` in `config.json`).  
Failed backups retry every **15 minutes** — not every 60 seconds.  
Backups older than **30 days** are automatically pruned (`s3_retention_days` to override).

---



**Requirements:** Go 1.22+, Flutter 3.22+, Android SDK, Visual Studio 2022 (Windows EXE)

```bash
git clone https://github.com/Nugent-Brothers-Enterprises/authvault.git
cd authvault/api
# Linux
go build -ldflags="-s -w" -o ../build/authvault-api .
# Windows
go build -ldflags="-s -w" -o ..\build\authvault-api.exe .

# Flutter Windows
cd ../desktop && flutter build windows --release
# Flutter Android
cd ../app && flutter build apk --release
```

---

## License

MIT
