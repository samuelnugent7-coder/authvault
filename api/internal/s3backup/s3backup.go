// Package s3backup exports the vault data to an S3 bucket.
// All backup files are encrypted with a per-vault AES-256-GCM backup key.
// Failed uploads are queued and retried with exponential backoff over 24 hours.
// After BackupMaxRetries consecutive failures an admin alert is logged.
package s3backup

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	appconfig "authvault/api/internal/config"
	"authvault/api/internal/crypto"
	"authvault/api/internal/db"
)

// Run exports TOTP entries and the password safe to S3.
// On failure the error is queued for retry rather than blocking.
func Run(ctx context.Context) error {
	cfg := appconfig.Get()
	if !cfg.S3Enabled {
		return fmt.Errorf("s3backup: S3 disabled in config")
	}
	if cfg.S3AccessKeyID == "" || cfg.S3SecretAccessKey == "" ||
		cfg.S3Region == "" || cfg.S3Bucket == "" {
		return fmt.Errorf("s3backup: S3 credentials not configured")
	}
	if !crypto.IsUnlocked() {
		return fmt.Errorf("s3backup: vault is locked; skipping backup")
	}

	backupKey, err := ensureBackupKey(cfg)
	if err != nil {
		return fmt.Errorf("s3backup: ensuring backup key: %w", err)
	}

	client := newClient(cfg)
	ts := time.Now().UTC().Format("2006-01-02T15-04-05Z")

	totp, err := db.AllTOTP()
	if err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: reading TOTP: %w", err))
	}
	totpJSON, err := json.MarshalIndent(totp, "", "  ")
	if err != nil {
		return fmt.Errorf("s3backup: marshalling TOTP: %w", err)
	}
	totpEnc, err := crypto.EncryptWithKey(totpJSON, backupKey)
	if err != nil {
		return fmt.Errorf("s3backup: encrypting TOTP: %w", err)
	}
	if err := upload(ctx, client, cfg.S3Bucket, fmt.Sprintf("totp/%s.json.enc", ts), []byte(totpEnc)); err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: uploading TOTP: %w", err))
	}
	if err := upload(ctx, client, cfg.S3Bucket, "latest/totp.json.enc", []byte(totpEnc)); err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: uploading latest TOTP: %w", err))
	}

	safe, err := db.GetFolderTree()
	if err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: reading safe: %w", err))
	}
	safeJSON, err := json.MarshalIndent(safe, "", "  ")
	if err != nil {
		return fmt.Errorf("s3backup: marshalling safe: %w", err)
	}
	safeEnc, err := crypto.EncryptWithKey(safeJSON, backupKey)
	if err != nil {
		return fmt.Errorf("s3backup: encrypting safe: %w", err)
	}
	if err := upload(ctx, client, cfg.S3Bucket, fmt.Sprintf("safe/%s.json.enc", ts), []byte(safeEnc)); err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: uploading safe: %w", err))
	}
	if err := upload(ctx, client, cfg.S3Bucket, "latest/safe.json.enc", []byte(safeEnc)); err != nil {
		return queueAndReturn(fmt.Errorf("s3backup: uploading latest safe: %w", err))
	}

	// Record success, clear any queued tasks for this type
	db.SetBackupState("last_s3_success", strconv.FormatInt(time.Now().Unix(), 10))
	log.Printf("[s3backup] encrypted backup complete - %d TOTP entries, %d folders -> s3://%s/%s",
		len(totp), len(safe), cfg.S3Bucket, ts)
	return nil
}

// queueAndReturn queues the given error for retry and returns it.
func queueAndReturn(err error) error {
	db.EnqueueBackup("s3_backup", err.Error())
	log.Printf("[s3backup] failure queued for retry: %v", err)
	return err
}

func ensureBackupKey(cfg *appconfig.Config) ([]byte, error) {
	if cfg.S3BackupKey != "" {
		key, err := hex.DecodeString(cfg.S3BackupKey)
		if err != nil || len(key) != 32 {
			return nil, fmt.Errorf("invalid S3BackupKey in config (expected 64 hex chars)")
		}
		return key, nil
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	keyHex := hex.EncodeToString(key)
	if err := appconfig.Update(func(c *appconfig.Config) { c.S3BackupKey = keyHex }); err != nil {
		return nil, err
	}
	log.Printf("NEW BACKUP ENCRYPTION KEY: %s  -- SAVE THIS KEY TO RESTORE BACKUPS", keyHex)
	return key, nil
}

// StartScheduler starts the 12-hour S3 backup loop and the retry worker.
func StartScheduler(ctx context.Context) {
	cfg := appconfig.Get()
	if !cfg.S3Enabled || cfg.S3Bucket == "" {
		log.Println("[s3backup] S3 backup disabled; scheduler not started")
		return
	}
	log.Println("[s3backup] scheduler started (interval: 12h encrypted with retry queue)")

	// Main backup loop
	go func() {
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return
		}
		if err := Run(ctx); err != nil {
			log.Printf("[s3backup] initial run: %v", err)
		}
		ticker := time.NewTicker(12 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := Run(ctx); err != nil {
					log.Printf("[s3backup] scheduled run: %v", err)
				}
			case <-ctx.Done():
				return
			}
		}
	}()

	// Retry queue worker � checks every 60 seconds
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				drainQueue(ctx)
			case <-ctx.Done():
				return
			}
		}
	}()
}

// drainQueue retries all queued backup tasks whose next_retry_at <= now.
func drainQueue(ctx context.Context) {
	tasks, err := db.PeekReadyTasks(10)
	if err != nil || len(tasks) == 0 {
		return
	}

	cfg := appconfig.Get()
	maxRetries := cfg.BackupMaxRetries
	if maxRetries <= 0 {
		maxRetries = 5
	}

	for _, task := range tasks {
		if runErr := Run(ctx); runErr == nil {
			db.DeleteQueuedTask(task.ID)
			db.SetBackupState("last_s3_success", strconv.FormatInt(time.Now().Unix(), 10))
			log.Printf("[s3backup] retry task=%d succeeded after %d attempt(s)", task.ID, task.AttemptCount+1)
		} else {
			newAttempt := task.AttemptCount + 1
			nextDelay := db.BackoffSeconds(newAttempt)
			nextRetry := time.Now().Unix() + nextDelay
			db.UpdateQueuedTask(task.ID, nextRetry, runErr.Error(), newAttempt)
			log.Printf("[s3backup] retry task=%d attempt=%d next_in=%ds error=%v",
				task.ID, newAttempt, nextDelay, runErr)

			if newAttempt >= maxRetries {
				log.Printf("[s3backup] *** BACKUP ALERT ***: S3 backup has failed %d consecutive times. "+
					"Last error: %v. Please verify S3 credentials and connectivity.", newAttempt, runErr)
			}
		}
	}
}

func newClient(cfg *appconfig.Config) *s3.Client {
	creds := credentials.NewStaticCredentialsProvider(cfg.S3AccessKeyID, cfg.S3SecretAccessKey, "")
	awsCfg := aws.Config{Region: cfg.S3Region, Credentials: creds}
	opts := []func(*s3.Options){}
	if cfg.S3Endpoint != "" {
		ep := cfg.S3Endpoint
		opts = append(opts, func(o *s3.Options) {
			o.BaseEndpoint = &ep
			o.UsePathStyle = true
		})
	}
	return s3.NewFromConfig(awsCfg, opts...)
}

func upload(ctx context.Context, client *s3.Client, bucket, key string, data []byte) error {
	_, err := client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(data),
		ContentType: aws.String("application/octet-stream"),
	})
	if err != nil {
		msg := err.Error()
		if idx := strings.Index(msg, "\n"); idx > 0 {
			msg = msg[:idx]
		}
		return fmt.Errorf("PutObject %q: %s", key, msg)
	}
	return nil
}