# AuthVault — Complete System Documentation

> **Stack:** Go 1.24 API · Flutter 3 Windows Desktop · Flutter 3 Android  
> **Location:** `L:\apps\auth\`  
> **API default port:** `8443` (HTTPS, self-signed cert)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Directory Structure](#2-directory-structure)
3. [Go API Server](#3-go-api-server)
   - [Startup & First-Run Wizard](#31-startup--first-run-wizard)
   - [Configuration (config.json)](#32-configuration-configjson)
   - [Database Schema](#33-database-schema)
   - [Encryption Model](#34-encryption-model)
   - [Full API Route Reference](#35-full-api-route-reference)
4. [Authentication & Sessions](#4-authentication--sessions)
5. [Permission System](#5-permission-system)
6. [Features](#6-features)
   - [TOTP Authenticator](#61-totp-authenticator)
   - [Password Safe](#62-password-safe)
   - [SSH Key Vault](#63-ssh-key-vault)
   - [File Attachments](#64-file-attachments)
   - [Password Health Scanner](#65-password-health-scanner)
   - [Audit Log](#66-audit-log)
   - [Session Management](#67-session-management)
   - [Backup System](#68-backup-system)
   - [Encrypted S3 Auto-Backup](#69-encrypted-s3-auto-backup)
7. [Windows Desktop App](#7-windows-desktop-app)
   - [Screens](#71-screens)
   - [Services & Architecture](#72-services--architecture)
   - [Offline Mode](#73-offline-mode)
8. [Android App](#8-android-app)
9. [Multi-User & Admin](#9-multi-user--admin)
10. [Build & Deployment](#10-build--deployment)
11. [Utilities](#11-utilities)
12. [Security Model Summary](#12-security-model-summary)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                        CLIENTS                           │
│                                                          │
│  ┌──────────────────────┐   ┌──────────────────────────┐ │
│  │  Windows Desktop App │   │    Android App           │ │
│  │  (Flutter 3)         │   │    (Flutter 3)           │ │
│  │  l:\apps\auth\desktop│   │    l:\apps\auth\app      │ │
│  └──────────┬───────────┘   └────────────┬─────────────┘ │
└─────────────┼────────────────────────────┼───────────────┘
              │  HTTPS + JWT               │  HTTPS + JWT
              ▼                            ▼
┌──────────────────────────────────────────────────────────┐
│               Go REST API  (authvault-api.exe)           │
│               l:\apps\auth\api                           │
│               Port: 8443 (TLS)                           │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐  │
│  │  Auth    │  │  TOTP    │  │  Safe    │  │  Admin  │  │
│  │ Handler  │  │ Handler  │  │ Handler  │  │ Handler │  │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐  │
│  │  SSH     │  │Attachment│  │  Health  │  │ Backup  │  │
│  │ Handler  │  │ Handler  │  │ Handler  │  │ Handler │  │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘  │
│  ┌──────────┐  ┌──────────┐                              │
│  │  Audit   │  │ Sessions │                              │
│  │ Handler  │  │ Handler  │                              │
│  └──────────┘  └──────────┘                              │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  SQLite  (vault.db)  — all data encrypted at rest   │ │
│  └─────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  S3 Auto-Backup  ( every 12 h, AES-256-GCM )        │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

All sensitive data is encrypted **inside the API** before being stored in SQLite.  
Clients never receive raw keys — they authenticate with JWT tokens.

---

## 2. Directory Structure

```
L:\apps\auth\
├── build\                          ← Compiled binaries + Windows app
│   ├── authvault-api.exe
│   ├── decrypt-backup.exe
│   ├── config.json                 ← Runtime config (auto-generated)
│   ├── vault.db                    ← SQLite database (auto-generated)
│   └── AuthVault-Windows\          ← Flutter Windows release
│       └── authvault_desktop.exe
│
├── api\                            ← Go backend
│   ├── main.go
│   ├── go.mod
│   ├── cmd\
│   │   ├── decrypt-backup\main.go  ← CLI decrypt utility
│   │   └── seed\main.go            ← Dev data seeder
│   └── internal\
│       ├── config\config.go        ← Config struct + load/save/update
│       ├── crypto\crypto.go        ← Argon2+AES-256-GCM vault crypto
│       ├── db\
│       │   ├── db.go               ← Open + migrate all tables
│       │   ├── users_db.go         ← Users + permissions CRUD
│       │   ├── audit_db.go         ← Audit log write/query
│       │   ├── sessions_db.go      ← Session create/revoke/clean
│       │   ├── ssh_db.go           ← SSH key CRUD (encrypted fields)
│       │   ├── attachments_db.go   ← File attachment CRUD (encrypted)
│       │   ├── backup_db.go        ← Local backup file tracking
│       │   └── (others per feature)
│       ├── handlers\               ← HTTP handler functions
│       │   ├── auth.go, admin.go, totp.go, safe.go
│       │   ├── ssh.go, attachments.go, health.go
│       │   ├── audit.go, sessions.go, backup.go
│       │   └── (helpers shared across handlers)
│       ├── middleware\
│       │   ├── jwt.go              ← JWT validation middleware
│       │   └── logging.go          ← Request logging middleware
│       ├── models\
│       │   ├── models.go           ← Core data types (TOTP, Safe, etc.)
│       │   ├── users.go            ← User + permission types
│       │   └── features.go         ← AuditLog, Session, SSHKey, Attachment, Health
│       └── s3backup\s3backup.go    ← S3 upload scheduler
│
├── desktop\                        ← Flutter Windows app
│   └── lib\
│       ├── main.dart               ← App entry, AppState, AppRouter
│       ├── config\app_config.dart  ← API base URL + client secret storage
│       ├── models\
│       │   ├── user_info.dart      ← UserInfo, UserPermissions, ResourcePerms
│       │   ├── safe_node.dart      ← SafeFolder, SafeRecord, SafeItem
│       │   ├── totp_entry.dart     ← TOTPEntry model
│       │   └── vault_config.dart   ← Vault connection config
│       ├── services\
│       │   ├── api_service.dart    ← All HTTP calls to the API
│       │   ├── vault_manager.dart  ← Token storage, multi-vault config
│       │   ├── sync_service.dart   ← Background offline sync queue
│       │   ├── cache_service.dart  ← Local offline cache (Hive)
│       │   ├── desktop_backup_service.dart ← Local PC backup
│       │   └── totp_calculator.dart        ← TOTP code generation (RFC 6238)
│       └── screens\
│           ├── main_screen.dart    ← Sidebar nav shell
│           ├── login_screen.dart
│           ├── settings_screen.dart
│           ├── admin_screen.dart
│           ├── audit_screen.dart
│           ├── sessions_screen.dart
│           ├── health_screen.dart
│           ├── ssh_screen.dart
│           ├── vault_manage_screen.dart
│           ├── totp\totp_screen.dart
│           ├── totp\add_totp_screen.dart
│           ├── safe\safe_screen.dart
│           ├── safe\record_view.dart
│           └── backup\backup_screen.dart
│
└── app\                            ← Flutter Android app
    └── lib\
        └── screens\ ...            ← Mirrors desktop screen set
```

---

## 3. Go API Server

### 3.1 Startup & First-Run Wizard

The API is a single self-contained executable. On first run it:

1. **Generates a Client Secret** — a random 32-byte hex string written to `config.json`. This must be copied into the app's Settings screen to authorize API calls.
2. **Prompts for Master Password** (if none stored) — deriving an Argon2id key from it and storing the hash.
3. **Runs the S3 Setup Wizard** — prompts once to configure S3 auto-backup. Answers are saved; the wizard never runs again.
4. **Migrates legacy configs** — if a single-password setup is detected, an `admin` user is created automatically.
5. **Auto-unlocks the vault** — if a stored key is found, it is activated so clients can connect without waiting for admin login.

On subsequent runs, all steps are skipped and the API starts in under 1 second.

### 3.2 Configuration (config.json)

`config.json` lives next to the executable in `l:\apps\auth\build\`. Override via `AUTHVAULT_CONFIG` env var.

| Field | Type | Description |
|-------|------|-------------|
| `port` | string | Listen port (default `8443`) |
| `data_dir` | string | Directory for `vault.db` and backups |
| `client_secret` | string | JWT signing secret — must match app setting |
| `password_hash` | string | Argon2id hash of master password |
| `argon_salt` | string | Hex salt for key derivation |
| `s3_enabled` | bool | Enable S3 auto-backups |
| `s3_setup_done` | bool | Whether setup wizard has run |
| `s3_bucket` | string | S3 bucket name |
| `s3_region` | string | AWS region or provider region |
| `s3_endpoint` | string | Custom endpoint for non-AWS providers |
| `s3_access_key_id` | string | S3 access key |
| `s3_secret_access_key` | string | S3 secret key |
| `s3_backup_key` | string | AES-256 backup encryption key (hex, 64 chars) |

> **Security note:** `config.json` is written with mode `0600`. Never commit it. The `s3_backup_key` is the only key needed to decrypt backup files — store it separately.

### 3.3 Database Schema

All tables live in a single SQLite file (`vault.db`). Migrations run automatically on startup.

| Table | Purpose |
|-------|---------|
| `users` | User accounts with hashed passwords |
| `permissions` | Per-user, per-resource action grants |
| `totp_entries` | TOTP secrets (encrypted) |
| `safe_folders` | Hierarchical folder tree |
| `safe_records` | Password records (name, username, URL, notes, created_at) |
| `safe_items` | Encrypted field values per record |
| `ssh_keys` | SSH key pairs (public_key, private_key, comment — all encrypted) |
| `attachments` | Binary file attachments linked to records (encrypted blob) |
| `audit_logs` | Immutable event log |
| `sessions` | JWT session tracking with revocation support |
| `backup_files` | Metadata for locally stored backup snapshots |

### 3.4 Encryption Model

```
Master Password
     │
     ▼  Argon2id (memory=64MB, iterations=3, parallelism=2)
Derived Key (32 bytes)
     │
     ▼  AES-256-GCM
All sensitive DB fields:
  • TOTP secrets
  • Safe record field values
  • SSH public keys, private keys, comments
  • File attachment data
  • (Vault is "locked" when no key is in memory)
```

**Vault lock/unlock cycle:**
- **Admin login** → derives key from password → `crypto.SetActiveKey(key)` → vault unlocked
- **Non-admin login** → only allowed if vault is already unlocked by admin
- **Server restart** → auto-unlock if `password_hash` is a valid 32-byte key (legacy path)
- **S3 backups** → encrypted with a separate `S3BackupKey` (independent of vault key)

### 3.5 Full API Route Reference

All routes require `Authorization: Bearer <JWT>` except login and status.

#### Auth

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `POST` | `/api/v1/auth/login` | — | Login with username + password. Returns JWT + full permission set |
| `POST` | `/api/v1/auth/logout` | JWT | Logs out; touches session last-seen; records audit event |
| `GET`  | `/api/v1/auth/status` | — | Returns `{"unlocked": bool}` |
| `GET`  | `/api/v1/auth/me` | JWT | Returns current user info + permissions |

#### TOTP

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/totp` | `totp.read` | List all TOTP entries |
| `POST` | `/api/v1/totp` | `totp.write` | Create TOTP entry |
| `PUT`  | `/api/v1/totp/:id` | `totp.write` | Update TOTP entry |
| `DELETE` | `/api/v1/totp/:id` | `totp.delete` | Delete TOTP entry |
| `GET`  | `/api/v1/totp/export` | `totp.export` | Export all entries as JSON |
| `POST` | `/api/v1/totp/import` | `totp.import` | Import entries from JSON |

#### Password Safe

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/safe` | `safe.read` | Get full folder tree with records |
| `POST` | `/api/v1/safe/folders` | `safe.write` | Create folder |
| `PUT`  | `/api/v1/safe/folders/:id` | `safe.write` | Rename/move folder |
| `DELETE` | `/api/v1/safe/folders/:id` | `safe.delete` | Delete folder (cascades) |
| `POST` | `/api/v1/safe/records` | `safe.write` | Create password record |
| `PUT`  | `/api/v1/safe/records/:id` | `safe.write` | Update record metadata |
| `DELETE` | `/api/v1/safe/records/:id` | `safe.delete` | Delete record |
| `POST` | `/api/v1/safe/items` | `safe.write` | Add encrypted field to record |
| `PUT`  | `/api/v1/safe/items/:id` | `safe.write` | Update encrypted field |
| `DELETE` | `/api/v1/safe/items/:id` | `safe.delete` | Delete field |
| `GET`  | `/api/v1/safe/export` | `safe.export` | Export safe as JSON |
| `POST` | `/api/v1/safe/import` | `safe.import` | Import safe from JSON |

#### SSH Keys

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/ssh` | `ssh.read` | List all SSH keys |
| `POST` | `/api/v1/ssh` | `ssh.write` | Store new SSH key pair |
| `GET`  | `/api/v1/ssh/:id` | `ssh.read` | Get single key (with private key) |
| `PUT`  | `/api/v1/ssh/:id` | `ssh.write` | Update SSH key |
| `DELETE` | `/api/v1/ssh/:id` | `ssh.delete` | Delete SSH key |

#### File Attachments

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/attachments?record_id=X` | `safe.read` | List attachments for record |
| `POST` | `/api/v1/attachments` | `safe.write` | Upload attachment (base64, max 10 MB) |
| `GET`  | `/api/v1/attachments/:id/data` | `safe.read` | Download decrypted attachment |
| `DELETE` | `/api/v1/attachments/:id` | `safe.delete` | Delete attachment |

#### Password Health

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/health/passwords?hibp=true` | `safe.read` | Scan passwords for issues |

#### Audit Log

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/audit?limit=N` | `audit.read` | Admins see all events; users see their own |

#### Sessions

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/sessions` | JWT | List current user's sessions |
| `DELETE` | `/api/v1/sessions/:id` | JWT | Revoke a specific session |

#### Backup

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/backup/check` | `backup.read` | Check last backup status |
| `POST` | `/api/v1/backup/upload` | `backup.write` | Upload a local backup file |
| `GET`  | `/api/v1/backup/stats` | `backup.read` | Backup statistics |
| `GET`  | `/api/v1/backup/files` | `backup.read` | List backup files |
| `GET/PUT` | `/api/v1/backup/config` | `backup.read/write` | Backup configuration |

#### S3 Config

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/s3/config` | JWT | View S3 config (secret redacted for non-admin) |
| `PUT`  | `/api/v1/s3/config` | Admin | Update S3 settings |

#### Admin — User Management

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| `GET`  | `/api/v1/admin/users` | Admin | List all users |
| `POST` | `/api/v1/admin/users` | Admin | Create user |
| `PUT`  | `/api/v1/admin/users/:id` | Admin | Update user (password / admin flag) |
| `DELETE` | `/api/v1/admin/users/:id` | Admin | Delete user |
| `GET`  | `/api/v1/admin/users/:id/permissions` | Admin | Get user permissions |
| `PUT`  | `/api/v1/admin/users/:id/permissions` | Admin | Set user permissions |

---

## 4. Authentication & Sessions

### Login Flow

```
Client                          API
  │                              │
  │── POST /auth/login ─────────►│
  │   { username, password }     │
  │                              │── 1. Verify password (Argon2id)
  │                              │── 2. Admin: derive + activate vault key
  │                              │── 3. Check if IP is new → audit "new_ip_detected"
  │                              │── 4. Record session (SHA-256 of JWT stored)
  │                              │── 5. Log "login" audit event
  │◄── { token, username,  ─────│
  │     is_admin, perms }        │
```

- **JWT** expires in 12 hours. Claims: `uid`, `username`, `admin`, `exp`, `iat`
- **Non-admin users** can only log in if an admin has already unlocked the vault
- **Login failures** are logged to audit with reason (`unknown user` / `wrong password`)
- **New IP detection** — if the IP has never been seen for that user, a `new_ip_detected` audit event is recorded

### Session Tracking

Every login creates a `sessions` record:
- Token stored as `SHA-256(JWT)` — the raw token is never persisted
- `last_seen` updated on logout
- Sessions can be revoked individually (marks `revoked=true`)
- Revoked tokens are rejected by JWT middleware

---

## 5. Permission System

### How Permissions Work

- **Admin users** always have full access to everything — permissions are bypassed
- **Non-admin users** default to **allow** for everything unless an explicit deny row exists
- Admin sets explicit denials in the Admin screen; no row = full access

### Permission Resources & Actions

| Resource | Actions Available |
|----------|-------------------|
| `totp` | `read`, `write`, `delete`, `export`, `import` |
| `safe` | `read`, `write`, `delete`, `export`, `import` |
| `backup` | `read`, `write`, `delete` |
| `ssh` | `read`, `write`, `delete` |

### Granular Overrides

Beyond section-level permissions, admin can set **per-folder** and **per-TOTP-entry** overrides:

```json
{
  "safe": { "read": true, "write": true, "delete": true, "export": true, "import": true },
  "folder_perms": {
    "12": { "read": false, "write": false, "delete": false }
  },
  "totp_perms": {
    "5": { "read": false }
  }
}
```

- Per-folder `read: false` → user cannot see records in that folder
- Per-folder `write: false` → user can view but not edit
- Folder overrides **take precedence** over section-level permissions

### Audit Events

| Event | Trigger |
|-------|---------|
| `login` | Successful login |
| `login_failed` | Bad username or password |
| `logout` | Explicit logout |
| `new_ip_detected` | Login from a previously unseen IP address |
| `session_revoked` | Session manually revoked |
| `vault_unlock` | Admin unlocks vault |
| `backup_upload` | Backup file uploaded |
| `backup_restore` | Backup restore triggered |
| `user_created` | Admin creates a user |
| `user_deleted` | Admin deletes a user |
| `permissions_changed` | Admin changes a user's permissions |

---

## 6. Features

### 6.1 TOTP Authenticator

- Stores TOTP secrets encrypted in SQLite (AES-256-GCM)
- Generates RFC 6238 time-based one-time passwords locally in the app
- 6 or 8 digit codes, 30-second windows
- Auto-copies code to clipboard on tap
- Animated countdown ring shows time remaining
- Import from JSON (AuthVault format) or individual URI (`otpauth://`)
- Export to JSON for migration / backup
- Per-entry permission overrides (block specific entries from specific users)

### 6.2 Password Safe

- Hierarchical **folder tree** — unlimited nesting depth
- Each **record** has: name, username, URL, notes, `created_at` timestamp
- Each record has **items** — named encrypted fields (Password, PIN, API Key, etc.)
- Field values are encrypted individually with AES-256-GCM
- **Full-text search** across folder/record names
- Export entire safe to JSON (requires `safe.export` permission)
- Import from JSON (requires `safe.import` permission)
- Per-folder read/write blocking for non-admin users
- Records support **file attachments** (see §6.4)

### 6.3 SSH Key Vault

- Store SSH key pairs with a name, comment, public key, and optional private key
- All three text fields (public key, private key, comment) are stored encrypted
- One-click **copy public key** to clipboard
- Full CRUD — add, edit, delete
- Requires `ssh.read/write/delete` permissions

### 6.4 File Attachments

- Attach files to any password safe record
- Files are base64-encoded then AES-256-GCM encrypted before storage
- Maximum single file size: **10 MB**
- Stored in `attachments` table — no use of the filesystem
- Download returns decrypted raw bytes with original MIME type
- Permissions follow `safe.read/write/delete`

### 6.5 Password Health Scanner

Scans all password records you have access to and reports:

| Issue | Detection Method |
|-------|-----------------|
| **Weak** | Strength score < 40/100 (based on length + character variety) |
| **Reused** | Same decrypted password appears in 2+ records |
| **Old** | Record `created_at` is older than 90 days |
| **Breached** | Found in HaveIBeenPwned database (k-anonymity API — only first 5 SHA-1 chars sent) |

- HIBP check is **opt-in** per scan (toggle in UI)
- Returns a report: total scanned, counts per issue type, list of affected records
- HaveIBeenPwned check requires internet access; all other checks are fully offline

### 6.6 Audit Log

- Every security-relevant event is written to `audit_logs` with:
  - User ID + username
  - Event type (see §5 table)
  - IP address (supports `X-Forwarded-For`, `X-Real-IP`, direct `RemoteAddr`)
  - User-Agent / device string
  - Optional details string
- **Admins** can see all events for all users
- **Non-admin users** can only see their own events
- Configurable limit (50 / 100 / 250 / 500 entries)
- Color-coded by severity: green (normal), orange (new IP), red (failures / revocations)

### 6.7 Session Management

- Every login creates a tracked session
- Sessions screen shows: device (User-Agent), IP address, last-seen time, revoked status
- **Revoke** any individual session — its JWT immediately becomes invalid
- Useful for "I logged in from a device I don't recognise" security response
- Sessions are cleaned up automatically (expired tokens pruned)

### 6.8 Backup System

Two independent backup mechanisms exist:

#### Local Desktop Backup
- Triggered manually or automatically from the Backup screen
- Backs up `vault.db` to a user-specified local path
- Tracks backup history with timestamps
- Restore replaces the live database

#### File Upload Backup
- `POST /api/v1/backup/upload` — client uploads an encrypted backup file to the server
- Server stores it in `data_dir` alongside `vault.db`
- Backup file list and stats available via API

### 6.9 Encrypted S3 Auto-Backup

Runs as a background goroutine, fires every **12 hours** while the vault is unlocked.

**What gets backed up:**
- All TOTP entries (JSON)
- Full password safe folder tree (JSON)

**Encryption:**
- Each backup file is encrypted with **AES-256-GCM** using a dedicated `S3BackupKey`
- Key is auto-generated on first backup run and saved to `config.json`
- The key is printed prominently to the server console — **save it immediately**
- Key is completely independent of the vault master password

**S3 object layout:**
```
s3://<bucket>/
├── totp/
│   └── 2025-04-27T12-00-00Z.json.enc    ← timestamped snapshot
├── safe/
│   └── 2025-04-27T12-00-00Z.json.enc
└── latest/
    ├── totp.json.enc                     ← always the most recent
    └── safe.json.enc
```

**Supported providers:** AWS S3, Backblaze B2, MinIO, any S3-compatible service (set `s3_endpoint`)

**Setup options:**
1. **Interactive wizard** — runs once on first server startup
2. **Admin API** — `PUT /api/v1/s3/config` (admin only)
3. **Direct config.json edit** — then restart server

**Decrypt a backup without the app:** use `decrypt-backup.exe` (see §11).

---

## 7. Windows Desktop App

Built with Flutter 3, targeting Windows x64. Released as a folder at `build\AuthVault-Windows\`.

### 7.1 Screens

| Screen | Nav Label | Who Sees It | Description |
|--------|-----------|-------------|-------------|
| Login | — | Everyone | Username + password. Connects to configured API. |
| Authenticator | Authenticator | Everyone | TOTP list with live countdown codes |
| Password Safe | Password Safe | `safe.read` | Folder tree + record viewer / editor |
| Settings | Settings | Everyone | API URL, client secret, theme, connection test |
| Backup | Backup | `backup.read` | Local and S3 backup management |
| Password Health | Password Health | `safe.read` | Run scans for weak/reused/old/breached passwords |
| SSH Keys | SSH Keys | `ssh.read` | Manage stored SSH key pairs |
| Sessions | Sessions | JWT | View and revoke active login sessions |
| Audit Log | Audit Log | Admin only | Full event audit trail |
| Admin | Admin | Admin only | User management + permission editor |
| Vault Manager | — | Everyone | Add/remove/switch between multiple vault connections |

#### Login Screen
- Supports multiple saved vault connections (host + client secret)
- Remembers last used vault
- Shows vault locked/unlocked status before login attempt

#### Authenticator Screen
- Live-updating TOTP codes with countdown ring
- Search/filter entries
- Add via QR / manual URI / manual form
- Supports 6-digit and 8-digit codes
- Copy to clipboard on tap

#### Password Safe Screen
- Collapsible folder tree on left, record list on right, field viewer on right panel
- Inline edit for all fields
- Attach files to records (upload/download/delete)
- Search bar filters across all folders simultaneously
- Right-click context menus for folder/record operations
- Drag-and-drop folder reorganization

#### Admin Screen
- **User list** — create, delete, reset password, toggle admin flag
- **Permission editor** — per-user checkboxes for:
  - TOTP: Read / Write / Delete / **Export** / **Import**
  - Safe: Read / Write / Delete / **Export** / **Import**
  - Backup: Read / Write / Delete
  - SSH: Read / Write / Delete
- **Per-folder overrides** — block read or write for individual folders
- **Per-TOTP overrides** — block read for individual TOTP entries

#### Settings Screen
- API Base URL (e.g. `https://192.168.1.10:8443`)
- Client Secret (must match server's `config.json`)
- Accept self-signed TLS certificates toggle
- Theme: light / dark / system
- Connection test button
- Multi-vault: add/remove/rename vault connections

### 7.2 Services & Architecture

```
main.dart (AppState + AppRouter)
    │
    ├── VaultManager       ← stores token, selects active vault config
    ├── ApiService         ← all HTTP calls (uses VaultManager for token/URL)
    ├── CacheService       ← Hive-based local offline cache
    ├── SyncService        ← pending write queue for offline mode
    └── DesktopBackupService ← local file backup triggers
```

**VaultManager** manages multiple vault connection profiles. Each profile stores:
- API base URL
- Client secret
- Cached username

**ApiService** wraps every endpoint with:
- Automatic `Authorization: Bearer <token>` injection
- Self-signed TLS certificate acceptance
- Structured error throwing (`ApiException(statusCode, message)`)

### 7.3 Offline Mode

- When the API is unreachable, the app reads from **CacheService** (Hive)
- Writes (create/update/delete) are queued in **SyncService**
- A badge on the Settings nav item shows pending sync count
- On reconnection, the sync queue drains automatically
- Cache is populated on every successful API fetch

---

## 8. Android App

Located at `l:\apps\auth\app\`. Built with Flutter 3, targeting Android.

- **Same feature set** as the Windows desktop app
- Connects to the same Go API over HTTPS
- Uses the same `ApiService`, `VaultManager`, `CacheService`, `SyncService` pattern
- APK output: `app/build/app/outputs/flutter-apk/app-release.apk`

---

## 9. Multi-User & Admin

AuthVault supports multiple user accounts with fine-grained access control.

### User Types

| Type | Description |
|------|-------------|
| **Admin** | Full access to everything. Can manage users, permissions, see all audit logs. |
| **Non-admin** | Access controlled per-resource. Cannot use admin endpoints. Can see own audit events and manage own sessions. |

### User Lifecycle

1. Admin creates user via Admin screen (or `POST /api/v1/admin/users`)
2. User logs in — vault must already be unlocked by an admin
3. Admin adjusts permissions in real-time (effective on next API call)
4. Admin can delete user — all their permission rows are removed
5. Admin can force-reset any user's password

### Default Permission Behaviour

| Scenario | Result |
|----------|--------|
| No permission row exists for user+resource+action | **Allowed** (default allow) |
| Row exists with `allowed=true` | Allowed |
| Row exists with `allowed=false` | **Denied** |
| Admin user | Always allowed (check bypassed) |

---

## 10. Build & Deployment

### Requirements

| Tool | Version | Notes |
|------|---------|-------|
| Go | 1.24+ | `C:\Program Files\Go\bin\go.exe` |
| Flutter | 3.x | `C:\tools\flutter\` |
| Windows SDK | 10+ | Required for Windows Flutter build |

### Build Commands

```powershell
# ── API ──────────────────────────────────────────────────────
Set-Location l:\apps\auth\api
& "C:\Program Files\Go\bin\go.exe" build -o ..\build\authvault-api.exe .

# ── Decrypt utility ──────────────────────────────────────────
& "C:\Program Files\Go\bin\go.exe" build -o ..\build\decrypt-backup.exe .\cmd\decrypt-backup\

# ── Windows Desktop ──────────────────────────────────────────
Set-Location l:\apps\auth\desktop
C:\tools\flutter\bin\flutter.bat clean
C:\tools\flutter\bin\flutter.bat build windows --release

# Copy output to build\
Remove-Item "l:\apps\auth\build\AuthVault-Windows" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "l:\apps\auth\desktop\build\windows\x64\runner\Release" `
          "l:\apps\auth\build\AuthVault-Windows" -Recurse -Force

# ── Android APK ──────────────────────────────────────────────
Set-Location l:\apps\auth\app
C:\tools\flutter\bin\flutter.bat build apk --release
```

### Deployment Layout (`build\`)

```
build\
├── authvault-api.exe          ← Run this first
├── decrypt-backup.exe         ← Offline backup decryption utility
├── config.json                ← Auto-created on first run
├── vault.db                   ← Auto-created on first run
└── AuthVault-Windows\
    ├── authvault_desktop.exe  ← Double-click to launch
    ├── flutter_windows.dll
    ├── window_manager_plugin.dll
    └── data\                  ← Flutter assets
```

### Running

```powershell
# 1. Start the API (run from build\ directory so config.json is found)
Set-Location l:\apps\auth\build
.\authvault-api.exe

# 2. On first run: answer the master password and S3 wizard prompts
# 3. Note the Client Secret printed to console
# 4. Launch the desktop app, go to Settings, enter:
#    - API URL: https://localhost:8443
#    - Client Secret: <paste from console>
# 5. Test connection, then log in as admin
```

### Environment Variables

| Variable | Default | Usage |
|----------|---------|-------|
| `AUTHVAULT_CONFIG` | `<exe_dir>/config.json` | Override config file path |

---

## 11. Utilities

### decrypt-backup.exe

A standalone command-line tool for decrypting S3 backup files **without** running the API.

```
Usage:
  decrypt-backup.exe -key <64-hex-chars> <encrypted-file.json.enc>

Example:
  decrypt-backup.exe -key a3f1...c9d2 safe-2025-04-27T12-00-00Z.json.enc

Output:
  Writes safe-2025-04-27T12-00-00Z.json (decrypted plaintext)
```

The key is the `s3_backup_key` value from `config.json`. It is also printed to the server console when first generated.

**Important:** Keep this key in a separate secure location. Without it, encrypted backups cannot be recovered even if you have the master password.

### cmd/seed

Located at `api/cmd/seed/main.go`. A development utility that populates the database with sample TOTP entries and safe records.

```powershell
& "C:\Program Files\Go\bin\go.exe" run .\cmd\seed\
```

---

## 12. Security Model Summary

| Aspect | Implementation |
|--------|---------------|
| **Transport** | HTTPS with TLS (self-signed; clients opt-in to accept) |
| **Authentication** | Argon2id password hashing (memory=64MB, iter=3, par=2) |
| **Session tokens** | HS256 JWT, 12-hour expiry, server-side revocation list |
| **Data at rest** | AES-256-GCM, per-field encryption in SQLite |
| **Key derivation** | Argon2id from master password → 32-byte AES key |
| **Vault locking** | Key lives only in process memory; server restart re-requires admin login |
| **Backup encryption** | Independent AES-256-GCM key (`s3_backup_key`), separate from vault key |
| **HIBP check** | k-anonymity: only first 5 chars of SHA-1 hash sent over the network |
| **IP tracking** | Login IP logged; "new IP" alert on first use of each address |
| **Permission model** | Default-allow with explicit deny rows; granular per-folder/per-entry |
| **Config file** | Written mode `0600`. Contains credentials — do not expose or commit |
| **Token storage** | Sessions stored as `SHA-256(JWT)` — raw tokens never persisted |
| **Multi-user isolation** | Non-admin users cannot access admin endpoints or other users' audit logs |

### Threat Model Notes

- **Physical server access** — database is encrypted; attacker still needs the vault key to read records. Key is in process memory only.
- **Stolen config.json** — contains `client_secret` and S3 credentials. Rotate client secret + S3 keys if exposed; does not compromise vault data.
- **Stolen vault.db** — all sensitive fields AES-256-GCM encrypted. Cannot be read without deriving the key via Argon2id from the master password.
- **Stolen backup files** — encrypted with `s3_backup_key`. Keep this key separately from the backup storage location.
- **Compromised non-admin account** — limited to their granted permissions. Cannot escalate to admin via the API.
