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

// defaultBackupIntervalHours is used when config.S3BackupIntervalHours is unset.
const defaultBackupIntervalHours = 12

// defaultRetentionDays — timestamped backup objects older than this are
// pruned from S3 after each successful run.  Set config.S3RetentionDays to
// override (0 = keep all).
const defaultRetentionDays = 30

// StartScheduler starts the scheduled S3 backup loop and the retry worker.
// The retry worker fires every 15 minutes and executes at most ONE Run(),
// then clears all queued items on success — this prevents the backup flood
// that occurred when each queued item triggered its own full Run().
func StartScheduler(ctx context.Context) {
	cfg := appconfig.Get()
	if !cfg.S3Enabled || cfg.S3Bucket == "" {
		log.Println("[s3backup] S3 backup disabled; scheduler not started")
		return
	}
	intervalHours := cfg.S3BackupIntervalHours
	if intervalHours <= 0 {
		intervalHours = defaultBackupIntervalHours
	}
	retentionDays := cfg.S3RetentionDays
	if retentionDays <= 0 {
		retentionDays = defaultRetentionDays
	}
	log.Printf("[s3backup] scheduler started (interval: %dh, retry: 15m, retention: %d days)",
		intervalHours, retentionDays)

	// Main backup loop
	go func() {
		select {
		case <-time.After(10 * time.Second):
		case <-ctx.Done():
			return
		}
		if err := Run(ctx); err != nil {
			log.Printf("[s3backup] initial run: %v", err)
		} else {
			pruneOldBackups(ctx, retentionDays)
		}
		ticker := time.NewTicker(time.Duration(intervalHours) * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := Run(ctx); err != nil {
					log.Printf("[s3backup] scheduled run: %v", err)
				} else {
					pruneOldBackups(ctx, retentionDays)
				}
			case <-ctx.Done():
				return
			}
		}
	}()

	// Retry queue worker — fires every 15 minutes.
	// Runs ONE backup attempt and clears all queued items on success so we
	// never create more than one extra S3 object per 15-minute window.
	go func() {
		ticker := time.NewTicker(15 * time.Minute)
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

// drainQueue fires a single Run() attempt and, on success, clears ALL ready
// queued tasks.  This avoids the N-tasks × Run() = N new S3 objects problem
// that caused 1300+ backups in two days.
func drainQueue(ctx context.Context) {
	tasks, err := db.PeekReadyTasks(100)
	if err != nil || len(tasks) == 0 {
		return
	}

	cfg := appconfig.Get()
	maxRetries := cfg.BackupMaxRetries
	if maxRetries <= 0 {
		maxRetries = 5
	}

	// Run exactly ONE backup attempt for the whole batch.
	runErr := Run(ctx)
	if runErr == nil {
		// Success — clear every queued task
		for _, task := range tasks {
			db.DeleteQueuedTask(task.ID)
			log.Printf("[s3backup] retry task=%d cleared after successful run", task.ID)
		}
		db.SetBackupState("last_s3_success", strconv.FormatInt(time.Now().Unix(), 10))
		return
	}

	// Failure — advance each task's backoff independently
	for _, task := range tasks {
		newAttempt := task.AttemptCount + 1
		nextDelay := db.BackoffSeconds(newAttempt)
		nextRetry := time.Now().Unix() + nextDelay
		db.UpdateQueuedTask(task.ID, nextRetry, runErr.Error(), newAttempt)
		log.Printf("[s3backup] retry task=%d attempt=%d next_in=%ds error=%v",
			task.ID, newAttempt, nextDelay, runErr)
		if newAttempt >= maxRetries {
			log.Printf("[s3backup] *** BACKUP ALERT ***: S3 backup failed %d times in a row. "+
				"Last error: %v. Check S3 credentials.", newAttempt, runErr)
		}
	}
}

// pruneOldBackups deletes timestamped S3 objects older than retentionDays from
// the totp/ and safe/ prefixes.  The latest/ objects are never deleted.
func pruneOldBackups(ctx context.Context, retentionDays int) {
	cfg := appconfig.Get()
	if retentionDays <= 0 {
		return
	}
	cutoff := time.Now().UTC().AddDate(0, 0, -retentionDays)
	client := newClient(cfg)

	for _, prefix := range []string{"totp/", "safe/"} {
		out, err := client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket: aws.String(cfg.S3Bucket),
			Prefix: aws.String(prefix),
		})
		if err != nil {
			log.Printf("[s3backup] prune list %s: %v", prefix, err)
			continue
		}
		var deleted int
		for _, obj := range out.Contents {
			if obj.LastModified != nil && obj.LastModified.Before(cutoff) {
				_, delErr := client.DeleteObject(ctx, &s3.DeleteObjectInput{
					Bucket: aws.String(cfg.S3Bucket),
					Key:    obj.Key,
				})
				if delErr == nil {
					deleted++
				}
			}
		}
		if deleted > 0 {
			log.Printf("[s3backup] pruned %d old objects from s3://%s/%s (older than %d days)",
				deleted, cfg.S3Bucket, prefix, retentionDays)
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