# AuthVault

Self-hosted TOTP Authenticator + Password Safe, designed to run entirely on your Tailscale network.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Flutter App (APK + Windows EXE)                    │
│  ─ TOTP tab: live codes, QR scan (Android), copy   │
│  ─ Safe tab: folder tree, records, custom fields   │
│  ─ Settings: configurable API URL, import/export   │
└──────────────────────┬──────────────────────────────┘
                       │  HTTP + Bearer JWT (Tailscale)
┌──────────────────────▼──────────────────────────────┐
│  Go API Server  (authvault-api.exe / binary)        │
│  ─ Auth: Argon2id password hash + JWT HS256        │
│  ─ Storage: SQLite, all sensitive fields AES-256-GCM│
│  ─ Runs on any Tailscale device (Windows or Linux) │
└─────────────────────────────────────────────────────┘
```

## Security Model

| Layer | Mechanism |
|-------|-----------|
| Transport | Tailscale (WireGuard) — no TLS needed |
| API auth | JWT signed with HMAC-SHA256 client secret |
| Password verification | Argon2id (3 passes, 64 MB, 4 threads) |
| Data at rest | AES-256-GCM, key derived from master password |
| Session key | In-memory only, wiped on logout/restart |

> **The master password is never stored.** The API stores only an Argon2id hash. The AES key is derived on login and lives only in RAM.

---

## Quick Start

### 1 — Build the API

**Windows:**
```batch
cd api
go mod tidy
go build -ldflags="-s -w" -o ..\build\authvault-api.exe .
```

**Linux (for a NAS/server):**
```bash
cd api && go mod tidy
GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o ../build/authvault-api .
```

### 2 — First run (sets master password & generates client secret)

```
authvault-api.exe
```

On first launch it will:
1. Print a **client secret** — copy this into the app's Settings screen
2. Prompt you to **set a master password** via stdin
3. Save `config.json` next to the executable

`config.json` looks like:
```json
{
  "port": "8443",
  "data_dir": ".",
  "client_secret": "xxxxxxxxxxxxxxxxxxxx",
  "password_hash": "...",
  "argon_salt": "..."
}
```

Change `port` to whatever you like. The API always binds `0.0.0.0` — Tailscale controls who can reach it.

### 3 — Run as a Windows service (optional)

Use [NSSM](https://nssm.cc/):
```batch
nssm install AuthVaultAPI "C:\path\to\authvault-api.exe"
nssm set AuthVaultAPI AppDirectory "C:\path\to\"
nssm start AuthVaultAPI
```

### 4 — Build the Flutter app

**Requirements:** Flutter 3.22+, Android SDK (for APK), Visual Studio 2022 (for EXE)

```batch
cd app
flutter pub get

# Windows EXE
flutter build windows --release

# Android APK  
flutter build apk --release
```

Or run `build_windows.bat` for both in one step.

### 5 — Configure the app

1. Open the app → enter the **API Server URL** (your Tailscale IP + port, e.g. `http://100.x.x.x:8443`)
2. Enter your **master password** to unlock
3. Go to **Settings** → paste the **client secret** printed on first server run

---

## API Endpoints

All endpoints (except login/status) require `Authorization: Bearer <token>`.

### Auth
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/auth/login` | `{"password":"…"}` → `{"token":"…"}` |
| `POST` | `/api/v1/auth/logout` | Wipes session key from memory |
| `GET`  | `/api/v1/auth/status` | `{"unlocked": true/false}` |

### TOTP
| Method | Path | Description |
|--------|------|-------------|
| `GET`    | `/api/v1/totp` | List all entries (secrets decrypted) |
| `POST`   | `/api/v1/totp` | Add entry |
| `PUT`    | `/api/v1/totp/{id}` | Update entry |
| `DELETE` | `/api/v1/totp/{id}` | Delete entry |
| `POST`   | `/api/v1/totp/import` | Import `Accounts.json` format |
| `GET`    | `/api/v1/totp/export` | Export `Accounts.json` format |

### Password Safe
| Method | Path | Description |
|--------|------|-------------|
| `GET`    | `/api/v1/safe` | Full folder/record tree |
| `POST`   | `/api/v1/safe/folders` | Create folder |
| `PUT`    | `/api/v1/safe/folders/{id}` | Rename folder |
| `DELETE` | `/api/v1/safe/folders/{id}` | Delete folder (cascades) |
| `POST`   | `/api/v1/safe/records` | Create record |
| `PUT`    | `/api/v1/safe/records/{id}` | Update record |
| `DELETE` | `/api/v1/safe/records/{id}` | Delete record |
| `POST`   | `/api/v1/safe/items` | Add custom field |
| `PUT`    | `/api/v1/safe/items/{id}` | Update custom field |
| `DELETE` | `/api/v1/safe/items/{id}` | Delete custom field |
| `POST`   | `/api/v1/safe/import` | Import `safe.xml` (`?replace=true` to wipe first) |
| `GET`    | `/api/v1/safe/export` | Export `safe.xml` |

---

## Import your existing data

### TOTP (Accounts.json)
In the app: **Settings → Import TOTP** → select your `Accounts.json` file.

### Password Safe (safe.xml)
In the app: **Settings → Import Safe** → select your `safe.xml` file.  
Choose **Merge** to add alongside existing data, or **Replace** to wipe and replace.

---

## Changing the API server IP

Just edit the URL in the app's **Settings** screen. Nothing needs to change on the server — the JWT is signed with the client secret, not tied to an IP.

---

## Project Structure

```
apps/auth/
├── api/                    Go API server
│   ├── main.go
│   ├── go.mod
│   └── internal/
│       ├── config/         Config loading/saving
│       ├── crypto/         AES-256-GCM + Argon2id
│       ├── db/             SQLite operations
│       ├── handlers/       HTTP route handlers
│       ├── middleware/      JWT auth middleware
│       └── models/         Shared data types
├── app/                    Flutter app
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart
│       ├── config/         Secure local settings
│       ├── models/         TotpEntry, SafeFolder, etc.
│       ├── services/       ApiService, TotpCalculator
│       └── screens/
│           ├── login_screen.dart
│           ├── main_screen.dart
│           ├── settings_screen.dart
│           ├── totp/       TOTP list + add/scan
│           └── safe/       Folder tree + record editor
├── build_windows.bat       Build API + Windows EXE
├── build_apk.sh            Build API + Android APK
├── Accounts.json           Your TOTP data (import via app)
└── safe.xml                Your safe data (import via app)
```
