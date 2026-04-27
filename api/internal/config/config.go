package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Config struct {
	Port         string `json:"port"`
	DataDir      string `json:"data_dir"`
	ClientSecret string `json:"client_secret"`
	PasswordHash string `json:"password_hash,omitempty"` // Argon2id hash of master password
	ArgonSalt    string `json:"argon_salt,omitempty"`    // hex-encoded salt for key derivation

	// S3 auto-backup (every 12 h while unlocked)
	S3Enabled         bool   `json:"s3_enabled"`
	S3SetupDone       bool   `json:"s3_setup_done"` // true after wizard has run (even if disabled)
	S3AccessKeyID     string `json:"s3_access_key_id,omitempty"`
	S3SecretAccessKey string `json:"s3_secret_access_key,omitempty"`
	S3Region          string `json:"s3_region,omitempty"`
	S3Bucket          string `json:"s3_bucket,omitempty"`
	S3Endpoint        string `json:"s3_endpoint,omitempty"` // for non-AWS providers (e.g. MinIO, Backblaze)
	// AES-256-GCM key (hex) used to encrypt backup files before uploading.
	// Generated on first backup and stored here. Give users this key to decrypt.
	S3BackupKey       string `json:"s3_backup_key,omitempty"`

	// Snapshot retention — max number of snapshots to keep (default 30)
	SnapshotMaxCount int `json:"snapshot_max_count,omitempty"`

	// S3 backup retry — max consecutive failures before admin alert (default 5)
	BackupMaxRetries int `json:"backup_max_retries,omitempty"`

	// Duress / Decoy vault — second password returns sanitized view
	DuressPasswordHash string `json:"duress_password_hash,omitempty"`
	DuressArgonSalt    string `json:"duress_argon_salt,omitempty"`

	// Email alerts
	EmailEnabled  bool     `json:"email_enabled"`
	EmailProvider string   `json:"email_provider,omitempty"` // "smtp" | "ses"
	EmailSMTPHost string   `json:"email_smtp_host,omitempty"`
	EmailSMTPPort int      `json:"email_smtp_port,omitempty"`
	EmailSMTPUser string   `json:"email_smtp_user,omitempty"`
	EmailSMTPPass string   `json:"email_smtp_pass,omitempty"`
	EmailSMTPTLS  bool     `json:"email_smtp_tls"`
	EmailSESKeyID string   `json:"email_ses_key_id,omitempty"`
	EmailSESSecret string  `json:"email_ses_secret,omitempty"`
	EmailSESRegion string  `json:"email_ses_region,omitempty"`
	EmailFrom     string   `json:"email_from,omitempty"`
	EmailAlertTo  string   `json:"email_alert_to,omitempty"`
	EmailTriggers []string `json:"email_triggers,omitempty"`
}

var (
	instance *Config
	mu       sync.RWMutex
	cfgPath  string
)

func Load(path string) (*Config, error) {
	mu.Lock()
	defer mu.Unlock()
	cfgPath = path

	// Defaults
	cfg := &Config{
		Port:    "8443",
		DataDir: filepath.Dir(path),
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			instance = cfg
			return cfg, nil // first run
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}

	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	instance = cfg
	return cfg, nil
}

func Get() *Config {
	mu.RLock()
	defer mu.RUnlock()
	return instance
}

func Save() error {
	mu.Lock()
	defer mu.Unlock()
	data, err := json.MarshalIndent(instance, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(cfgPath, data, 0600)
}

func Update(fn func(*Config)) error {
	mu.Lock()
	defer mu.Unlock()
	fn(instance)
	data, err := json.MarshalIndent(instance, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(cfgPath, data, 0600)
}
