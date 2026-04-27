package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"authvault/api/internal/config"
	"authvault/api/internal/crypto"
	"authvault/api/internal/db"
	"authvault/api/internal/handlers"
	"authvault/api/internal/middleware"
	"authvault/api/internal/s3backup"
)

func main() {
	// Locate config file next to the executable
	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)
	cfgPath := filepath.Join(exeDir, "config.json")

	// Allow override via env
	if p := os.Getenv("AUTHVAULT_CONFIG"); p != "" {
		cfgPath = p
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Generate client secret on first run
	if cfg.ClientSecret == "" {
		secret, err := crypto.RandomSecret(32)
		if err != nil {
			log.Fatalf("generating secret: %v", err)
		}
		config.Update(func(c *config.Config) {
			c.ClientSecret = secret
		})
		cfg = config.Get()
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println("  First run – client secret generated and saved.")
		fmt.Printf("  Client Secret: %s\n", secret)
		fmt.Println("  Copy this into your app Settings screen.")
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	}

	if cfg.DataDir == "" {
		config.Update(func(c *config.Config) { c.DataDir = exeDir })
		cfg = config.Get()
	}

	if err := os.MkdirAll(cfg.DataDir, 0700); err != nil {
		log.Fatalf("data dir: %v", err)
	}

	if err := db.Open(cfg.DataDir); err != nil {
		log.Fatalf("db: %v", err)
	}

	// Migrate existing single-password setups to the multi-user system.
	// If there are no users yet but a password hash exists, create 'admin'.
	cfg = config.Get()
	if cfg.PasswordHash != "" {
		if err := db.CreateAdminFromLegacy(cfg.ArgonSalt, cfg.PasswordHash); err != nil {
			log.Printf("admin migration warning: %v", err)
		}
		// Auto-unlock: PasswordHash IS the Argon2 key (base64 encoded), decode and activate it
		// so non-admin users can access the vault without waiting for admin to log in.
		if keyBytes, decErr := base64.StdEncoding.DecodeString(cfg.PasswordHash); decErr == nil && len(keyBytes) == 32 {
			crypto.SetActiveKey(keyBytes)
			log.Printf("vault auto-unlocked from stored key")
		}
	}

	// Prompt for initial master password via stdin if running interactively
	if cfg.PasswordHash == "" {
		fmt.Print("Set master password: ")
		reader := bufio.NewReader(os.Stdin)
		pw, _ := reader.ReadString('\n')
		pw = strings.TrimSpace(pw)
		if pw == "" {
			log.Fatal("master password cannot be empty")
		}
		saltHex, hashB64, err := crypto.HashPassword(pw)
		if err != nil {
			log.Fatalf("hashing password: %v", err)
		}
		config.Update(func(c *config.Config) {
			c.ArgonSalt = saltHex
			c.PasswordHash = hashB64
		})
		if err := db.CreateAdminFromLegacy(saltHex, hashB64); err != nil {
			log.Printf("admin user creation warning: %v", err)
		}
		fmt.Println("Master password set!")
	}

	// ── S3 Setup Wizard ─────────────────────────────────────────────────────
	cfg = config.Get()
	if !cfg.S3SetupDone {
		fmt.Println()
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println("  S3 Auto-Backup Setup")
		fmt.Println("  Backups are encrypted with a unique AES-256 key.")
		fmt.Println("  Supported: AWS S3, Backblaze B2, MinIO, and any")
		fmt.Println("  S3-compatible provider.")
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		reader := bufio.NewReader(os.Stdin)

		fmt.Print("Enable S3 auto-backup? (y/n): ")
		ans, _ := reader.ReadString('\n')
		ans = strings.TrimSpace(strings.ToLower(ans))

		if ans == "y" || ans == "yes" {
			prompt := func(label string) string {
				fmt.Printf("  %s: ", label)
				v, _ := reader.ReadString('\n')
				return strings.TrimSpace(v)
			}
			bucket := prompt("S3 Bucket name")
			region := prompt("Region (e.g. us-east-1)")
			endpoint := prompt("Custom endpoint URL (leave blank for AWS)")
			keyID := prompt("Access Key ID")
			secret := prompt("Secret Access Key")

			config.Update(func(c *config.Config) {
				c.S3Enabled         = true
				c.S3SetupDone       = true
				c.S3Bucket          = bucket
				c.S3Region          = region
				c.S3Endpoint        = endpoint
				c.S3AccessKeyID     = keyID
				c.S3SecretAccessKey = secret
			})
			fmt.Println("  S3 backup enabled ✓")
		} else {
			config.Update(func(c *config.Config) {
				c.S3SetupDone = true
				c.S3Enabled   = false
			})
			fmt.Println("  S3 backup disabled. You can enable it later via the Admin panel.")
		}
		fmt.Println()
		cfg = config.Get()
	}

	mux := http.NewServeMux()
	secret := cfg.ClientSecret

	// Wire up middleware fingerprint and revocation hooks (avoids circular imports)
	middleware.IsRevokedFn              = db.IsRevoked
	middleware.GetSessionFingerprintFn  = db.GetSessionFingerprint
	middleware.FlagSessionFingerprintFn = db.FlagSessionFingerprint
	middleware.LogFingerprintMismatchFn = func(uid int64, uname, ip, device, details string) {
		db.LogAudit(uid, uname, "fingerprint_mismatch", ip, device, details)
	}

	// Auth (no JWT required)
	mux.HandleFunc("/api/v1/auth/login", handlers.Login)
	mux.HandleFunc("/api/v1/auth/logout", middleware.JWT(secret, handlers.Logout))
	mux.HandleFunc("/api/v1/auth/status", handlers.Status)
	mux.HandleFunc("/api/v1/auth/me", middleware.JWT(secret, handlers.Me))

	// TOTP
	mux.HandleFunc("/api/v1/totp/import", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.ImportTOTP(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/totp/export", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet { handlers.ExportTOTP(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/totp/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/qr") && r.Method == http.MethodGet {
			handlers.GetTOTPQR(w, r)
			return
		}
		switch r.Method {
		case http.MethodPut:    handlers.UpdateTOTP(w, r)
		case http.MethodDelete: handlers.DeleteTOTP(w, r)
		default:                methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/totp", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.ListTOTP(w, r)
		case http.MethodPost: handlers.CreateTOTP(w, r)
		default:              methodNotAllowed(w)
		}
	}))

	// Safe – import/export
	mux.HandleFunc("/api/v1/safe/import", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.ImportSafe(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/safe/export", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet { handlers.ExportSafe(w, r) } else { methodNotAllowed(w) }
	}))

	// Safe – folders (must register before safe/records to avoid prefix conflicts)
	mux.HandleFunc("/api/v1/safe/folders/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/shares") {
			switch r.Method {
			case http.MethodGet:  handlers.FolderSharesHandler(w, r)
			case http.MethodPost: handlers.FolderSharesHandler(w, r)
			default:              methodNotAllowed(w)
			}
			return
		}
		if strings.Contains(r.URL.Path, "/shares/") && r.Method == http.MethodDelete {
			handlers.RemoveFolderShare(w, r)
			return
		}
		switch r.Method {
		case http.MethodPut:    handlers.UpdateFolder(w, r)
		case http.MethodDelete: handlers.DeleteFolder(w, r)
		default:                methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/safe/folders", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.CreateFolder(w, r) } else { methodNotAllowed(w) }
	}))

	// Safe – record versions (specific prefix must come before /safe/records/)
	mux.HandleFunc("/api/v1/safe/records/versions/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/restore") {
			if r.Method == http.MethodPost { handlers.RestoreRecordVersion(w, r) } else { methodNotAllowed(w) }
		} else {
			methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/safe/records/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/history") {
			if r.Method == http.MethodGet { handlers.GetPasswordHistory(w, r) } else { methodNotAllowed(w) }
			return
		}
		if strings.HasSuffix(r.URL.Path, "/versions") {
			if r.Method == http.MethodGet { handlers.GetRecordVersions(w, r) } else { methodNotAllowed(w) }
			return
		}
		if strings.HasSuffix(r.URL.Path, "/tags") {
			if r.Method == http.MethodPut { handlers.SetRecordTagsHandler(w, r) } else { methodNotAllowed(w) }
			return
		}
		switch r.Method {
		case http.MethodPut:    handlers.UpdateRecord(w, r)
		case http.MethodDelete: handlers.DeleteRecord(w, r)
		default:                methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/safe/records", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.CreateRecord(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/safe/items/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPut:    handlers.UpdateItem(w, r)
		case http.MethodDelete: handlers.DeleteItem(w, r)
		default:                methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/safe/items", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.CreateItem(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/safe", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet { handlers.GetSafe(w, r) } else { methodNotAllowed(w) }
	}))

	// Backup
	mux.HandleFunc("/api/v1/backup/check",  middleware.JWT(secret, handlers.BackupCheck))
	mux.HandleFunc("/api/v1/backup/upload",  middleware.JWT(secret, handlers.BackupUpload))
	mux.HandleFunc("/api/v1/backup/stats",   middleware.JWT(secret, handlers.BackupStats))
	mux.HandleFunc("/api/v1/backup/files",   middleware.JWT(secret, handlers.BackupFiles))
	mux.HandleFunc("/api/v1/backup/config",  middleware.JWT(secret, handlers.BackupConfig))
	mux.HandleFunc("/api/v1/backup/health",  middleware.JWT(secret, handlers.BackupHealth))

	// Snapshots
	mux.HandleFunc("/api/v1/snapshots", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.ListSnapshots(w, r)
		case http.MethodPost: handlers.TriggerSnapshot(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/snapshots/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/restore") && r.Method == http.MethodPost {
			handlers.RestoreSnapshot(w, r)
		} else if r.Method == http.MethodDelete {
			handlers.DeleteSnapshot(w, r)
		} else {
			methodNotAllowed(w)
		}
	}))

	// Audit Log
	mux.HandleFunc("/api/v1/audit", middleware.JWT(secret, handlers.ListAuditLogs))

	// Sessions
	mux.HandleFunc("/api/v1/sessions", middleware.JWT(secret, handlers.ListSessions))
	mux.HandleFunc("/api/v1/sessions/", middleware.JWT(secret, handlers.RevokeSession))

	// Password Health
	mux.HandleFunc("/api/v1/health/passwords", middleware.JWT(secret, handlers.PasswordHealth))

	// SSH Keys
	mux.HandleFunc("/api/v1/ssh", middleware.JWT(secret, handlers.SSHKeys))
	mux.HandleFunc("/api/v1/ssh/", middleware.JWT(secret, handlers.SSHKeyByID))

	// File Attachments
	mux.HandleFunc("/api/v1/attachments", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.ListAttachments(w, r)
		case http.MethodPost: handlers.UploadAttachment(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/attachments/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/data") {
			handlers.GetAttachmentDataHandler(w, r)
		} else if r.Method == http.MethodDelete {
			handlers.DeleteAttachmentHandler(w, r)
		} else {
			methodNotAllowed(w)
		}
	}))

	// S3 Config
	mux.HandleFunc("/api/v1/s3/config", middleware.JWT(secret, handlers.S3Config))

	// Admin – user management + expiry
	mux.HandleFunc("/api/v1/admin/users", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.ListAdminUsers(w, r)
		case http.MethodPost: handlers.CreateAdminUser(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/admin/users/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/permissions") {
			switch r.Method {
			case http.MethodGet: handlers.GetUserPermissions(w, r)
			case http.MethodPut: handlers.SetUserPermissions(w, r)
			default:             methodNotAllowed(w)
			}
			return
		}
		if strings.HasSuffix(r.URL.Path, "/expiry") {
			if r.Method == http.MethodPut { handlers.SetUserExpiry(w, r) } else { methodNotAllowed(w) }
			return
		}
		switch r.Method {
		case http.MethodGet:    handlers.GetAdminUser(w, r)
		case http.MethodPut:    handlers.UpdateAdminUser(w, r)
		case http.MethodDelete: handlers.DeleteAdminUser(w, r)
		default:                methodNotAllowed(w)
		}
	}))

	// Admin – duress + integrity
	mux.HandleFunc("/api/v1/admin/duress/folders/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut { handlers.SetDecoyFolder(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/admin/duress/folders", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet { handlers.ListDecoyFolders(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/admin/duress", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut { handlers.SetDuressPassword(w, r) } else { methodNotAllowed(w) }
	}))
	mux.HandleFunc("/api/v1/admin/integrity", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.IntegrityCheck(w, r) } else { methodNotAllowed(w) }
	}))

	// Password Generator
	mux.HandleFunc("/api/v1/generator", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.GeneratePassword(w, r) } else { methodNotAllowed(w) }
	}))

	// Recycle Bin
	mux.HandleFunc("/api/v1/recycle-bin", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:    handlers.ListRecycleBin(w, r)
		case http.MethodDelete: handlers.EmptyRecycleBin(w, r)
		default:                methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/recycle-bin/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/restore") {
			if r.Method == http.MethodPost { handlers.RestoreBinItem(w, r) } else { methodNotAllowed(w) }
		} else if r.Method == http.MethodDelete {
			handlers.DeleteBinItem(w, r)
		} else {
			methodNotAllowed(w)
		}
	}))

	// Secure Notes
	mux.HandleFunc("/api/v1/notes", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.SecureNotes(w, r)
		case http.MethodPost: handlers.SecureNotes(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/notes/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:    handlers.SecureNoteByID(w, r)
		case http.MethodPut:    handlers.SecureNoteByID(w, r)
		case http.MethodDelete: handlers.SecureNoteByID(w, r)
		default:                methodNotAllowed(w)
		}
	}))

	// Tags
	mux.HandleFunc("/api/v1/tags", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.TagsHandler(w, r)
		case http.MethodPost: handlers.TagsHandler(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/tags/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:    handlers.TagByID(w, r)
		case http.MethodPut:    handlers.TagByID(w, r)
		case http.MethodDelete: handlers.TagByID(w, r)
		default:                methodNotAllowed(w)
		}
	}))

	// Dashboard
	mux.HandleFunc("/api/v1/dashboard", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet { handlers.GetDashboard(w, r) } else { methodNotAllowed(w) }
	}))

	// Share Links (public endpoint has no JWT)
	mux.HandleFunc("/api/v1/share/", handlers.GetSharedRecord)
	mux.HandleFunc("/api/v1/share-links", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.ShareLinksHandler(w, r)
		case http.MethodPost: handlers.ShareLinksHandler(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/share-links/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete { handlers.DeleteShareLinkHandler(w, r) } else { methodNotAllowed(w) }
	}))

	// API Keys
	mux.HandleFunc("/api/v1/api-keys", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:  handlers.APIKeysHandler(w, r)
		case http.MethodPost: handlers.APIKeysHandler(w, r)
		default:              methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/api-keys/", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodDelete: handlers.APIKeyByID(w, r)
		case http.MethodPost:   handlers.APIKeyByID(w, r) // /revoke suffix
		default:                methodNotAllowed(w)
		}
	}))

	// Email Config
	mux.HandleFunc("/api/v1/email/config", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet: handlers.GetEmailConfig(w, r)
		case http.MethodPut: handlers.UpdateEmailConfig(w, r)
		default:             methodNotAllowed(w)
		}
	}))
	mux.HandleFunc("/api/v1/email/test", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.TestEmail(w, r) } else { methodNotAllowed(w) }
	}))

	// CSV Import
	mux.HandleFunc("/api/v1/import/csv", middleware.JWT(secret, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost { handlers.CSVImport(w, r) } else { methodNotAllowed(w) }
	}))

	// Graceful shutdown context — cancelled on SIGINT / SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Start the S3 auto-backup scheduler (no-op if bucket not configured).
	s3backup.StartScheduler(ctx)

	addr := "0.0.0.0:" + cfg.Port
	log.Printf("AuthVault API listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, middleware.Logging(corsMiddleware(mux))))
}

func methodNotAllowed(w http.ResponseWriter) {
	http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
