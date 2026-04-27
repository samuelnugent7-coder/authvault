// Package snapshot implements zstd-compressed, AES-256-GCM-encrypted
// point-in-time snapshots of the AuthVault database.
//
// Each snapshot file is stored as:
//   <dataDir>/snapshots/<timestamp>-<type>.snap
//
// File format:
//   [12-byte nonce][ciphertext-of-zstd-compressed-JSON]
//
// The vault key (from crypto.GetActiveKey) is used for encryption.
// This means snapshots can only be created/restored while the vault is unlocked.
package snapshot

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"authvault/api/internal/crypto"
	"authvault/api/internal/db"
	"authvault/api/internal/models"

	"github.com/klauspost/compress/zstd"
)

// SnapshotData is the JSON payload stored inside a snapshot file.
type SnapshotData struct {
	Version   int           `json:"version"`
	Type      string        `json:"type"`    // "full" or "incremental"
	Since     int64         `json:"since"`   // unix ts; 0 for full
	BaseID    int64         `json:"base_id"` // 0 for full
	CreatedAt int64         `json:"created_at"`
	TOTP      []db.RawTOTP  `json:"totp"`
	Folders   []db.RawFolder `json:"folders"`
	Records   []db.RawRecord `json:"records"`
	Items     []db.RawItem   `json:"items"`
	SSHKeys   []db.RawSSHKey `json:"ssh_keys"`
}

// snapshotsDir ensures the snapshots directory exists and returns its path.
func snapshotsDir(dataDir string) (string, error) {
	dir := filepath.Join(dataDir, "snapshots")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	return dir, nil
}

// CreateFull creates a full snapshot of all vault data.
// Returns the populated Snapshot metadata (not yet persisted to DB — caller should call db.InsertSnapshot).
func CreateFull(dataDir string) (*models.Snapshot, string, error) {
	if !crypto.IsUnlocked() {
		return nil, "", fmt.Errorf("snapshot: vault is locked")
	}

	totp, err := db.AllTOTPRaw(0)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read totp: %w", err)
	}
	folders, err := db.AllFoldersRaw(0)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read folders: %w", err)
	}
	records, err := db.AllRecordsRaw(0)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read records: %w", err)
	}
	items, err := db.AllItemsRaw(0)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read items: %w", err)
	}
	sshKeys, err := db.AllSSHKeysRaw(0)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read ssh: %w", err)
	}

	data := &SnapshotData{
		Version:   1,
		Type:      "full",
		CreatedAt: time.Now().Unix(),
		TOTP:      totp,
		Folders:   folders,
		Records:   records,
		Items:     items,
		SSHKeys:   sshKeys,
	}

	recordCount := len(totp) + len(folders) + len(records) + len(items) + len(sshKeys)
	filePath, sizeBytes, err := writeToDisk(dataDir, "full", data)
	if err != nil {
		return nil, "", err
	}

	snap := &models.Snapshot{
		Type:        "full",
		FileName:    filepath.Base(filePath),
		SizeBytes:   sizeBytes,
		RecordCount: recordCount,
	}
	return snap, filePath, nil
}

// CreateIncremental creates an incremental snapshot containing only rows
// changed since the given base full snapshot's created_at timestamp.
func CreateIncremental(dataDir string, base *models.Snapshot) (*models.Snapshot, string, error) {
	if !crypto.IsUnlocked() {
		return nil, "", fmt.Errorf("snapshot: vault is locked")
	}

	since := base.CreatedAt

	totp, err := db.AllTOTPRaw(since)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read totp since %d: %w", since, err)
	}
	folders, err := db.AllFoldersRaw(since)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read folders since %d: %w", since, err)
	}
	records, err := db.AllRecordsRaw(since)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read records since %d: %w", since, err)
	}
	items, err := db.AllItemsRaw(since)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read items since %d: %w", since, err)
	}
	sshKeys, err := db.AllSSHKeysRaw(since)
	if err != nil {
		return nil, "", fmt.Errorf("snapshot: read ssh since %d: %w", since, err)
	}

	data := &SnapshotData{
		Version:   1,
		Type:      "incremental",
		Since:     since,
		BaseID:    base.ID,
		CreatedAt: time.Now().Unix(),
		TOTP:      totp,
		Folders:   folders,
		Records:   records,
		Items:     items,
		SSHKeys:   sshKeys,
	}

	recordCount := len(totp) + len(folders) + len(records) + len(items) + len(sshKeys)
	filePath, sizeBytes, err := writeToDisk(dataDir, "incr", data)
	if err != nil {
		return nil, "", err
	}

	snap := &models.Snapshot{
		Type:        "incremental",
		BaseID:      base.ID,
		FileName:    filepath.Base(filePath),
		SizeBytes:   sizeBytes,
		RecordCount: recordCount,
	}
	return snap, filePath, nil
}

// RestoreFromID restores the vault to the state captured in the given snapshot.
// For incremental snapshots it first restores the base full snapshot, then
// replays all incrementals up to and including the target snapshot ID.
func RestoreFromID(dataDir string, targetID int64) error {
	if !crypto.IsUnlocked() {
		return fmt.Errorf("snapshot: vault is locked")
	}

	target, err := db.GetSnapshot(targetID)
	if err != nil || target == nil {
		return fmt.Errorf("snapshot: target %d not found", targetID)
	}

	switch target.Type {
	case "full":
		data, err := readFromDisk(dataDir, target.FileName)
		if err != nil {
			return err
		}
		return db.RestoreFullSnapshot(data.TOTP, data.Folders, data.Records, data.Items, data.SSHKeys)

	case "incremental":
		// Restore the base full snapshot first
		base, err := db.GetSnapshot(target.BaseID)
		if err != nil || base == nil {
			return fmt.Errorf("snapshot: base full snapshot %d not found", target.BaseID)
		}
		baseData, err := readFromDisk(dataDir, base.FileName)
		if err != nil {
			return fmt.Errorf("snapshot: reading base: %w", err)
		}
		if err := db.RestoreFullSnapshot(baseData.TOTP, baseData.Folders, baseData.Records, baseData.Items, baseData.SSHKeys); err != nil {
			return fmt.Errorf("snapshot: restore base: %w", err)
		}

		// Apply each incremental in chronological order up to target
		incrementals, err := db.GetIncrementalsSince(base.ID)
		if err != nil {
			return err
		}
		for _, inc := range incrementals {
			incData, err := readFromDisk(dataDir, inc.FileName)
			if err != nil {
				return fmt.Errorf("snapshot: reading incremental %d: %w", inc.ID, err)
			}
			if err := db.ApplyIncrementalSnapshot(incData.TOTP, incData.Folders, incData.Records, incData.Items, incData.SSHKeys); err != nil {
				return fmt.Errorf("snapshot: applying incremental %d: %w", inc.ID, err)
			}
			if inc.ID == targetID {
				break
			}
		}
		return nil

	default:
		return fmt.Errorf("snapshot: unknown type %q", target.Type)
	}
}

// DeleteFile removes a snapshot file from disk (does not touch the DB record).
func DeleteFile(dataDir, fileName string) error {
	return os.Remove(filepath.Join(dataDir, "snapshots", fileName))
}

// ReadDataForS3 reads and returns the raw encrypted bytes of a snapshot file for S3 upload.
func ReadDataForS3(dataDir, fileName string) ([]byte, error) {
	return os.ReadFile(filepath.Join(dataDir, "snapshots", fileName))
}

// ── Internal helpers ──────────────────────────────────────────────────────────

func writeToDisk(dataDir, typeSuffix string, data *SnapshotData) (string, int64, error) {
	dir, err := snapshotsDir(dataDir)
	if err != nil {
		return "", 0, err
	}

	raw, err := json.Marshal(data)
	if err != nil {
		return "", 0, fmt.Errorf("snapshot: marshal: %w", err)
	}

	compressed, err := compressZstd(raw)
	if err != nil {
		return "", 0, fmt.Errorf("snapshot: compress: %w", err)
	}

	key := crypto.GetActiveKey()
	if key == nil {
		return "", 0, fmt.Errorf("snapshot: no active vault key")
	}
	encrypted, err := encryptGCM(compressed, key)
	if err != nil {
		return "", 0, fmt.Errorf("snapshot: encrypt: %w", err)
	}

	ts := time.Now().UTC().Format("2006-01-02T15-04-05Z")
	fileName := fmt.Sprintf("%s-%s.snap", ts, typeSuffix)
	filePath := filepath.Join(dir, fileName)

	if err := os.WriteFile(filePath, encrypted, 0600); err != nil {
		return "", 0, fmt.Errorf("snapshot: write file: %w", err)
	}

	return filePath, int64(len(encrypted)), nil
}

func readFromDisk(dataDir, fileName string) (*SnapshotData, error) {
	filePath := filepath.Join(dataDir, "snapshots", fileName)
	encrypted, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("snapshot: read file %s: %w", fileName, err)
	}

	key := crypto.GetActiveKey()
	if key == nil {
		return nil, fmt.Errorf("snapshot: no active vault key")
	}

	compressed, err := decryptGCM(encrypted, key)
	if err != nil {
		return nil, fmt.Errorf("snapshot: decrypt %s: %w", fileName, err)
	}

	raw, err := decompressZstd(compressed)
	if err != nil {
		return nil, fmt.Errorf("snapshot: decompress %s: %w", fileName, err)
	}

	var data SnapshotData
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, fmt.Errorf("snapshot: unmarshal %s: %w", fileName, err)
	}
	return &data, nil
}

// compressZstd compresses data using zstd (best-speed level).
func compressZstd(data []byte) ([]byte, error) {
	enc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		return nil, err
	}
	return enc.EncodeAll(data, nil), nil
}

// decompressZstd decompresses zstd data.
func decompressZstd(data []byte) ([]byte, error) {
	dec, err := zstd.NewReader(nil)
	if err != nil {
		return nil, err
	}
	defer dec.Close()
	return dec.DecodeAll(data, nil)
}

// encryptGCM encrypts plaintext with AES-256-GCM using the given 32-byte key.
// Output format: [12-byte nonce][ciphertext+tag]
func encryptGCM(plaintext, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	return append(nonce, ciphertext...), nil
}

// decryptGCM decrypts AES-256-GCM encrypted data.
// Input format: [12-byte nonce][ciphertext+tag]
func decryptGCM(data, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(data) < ns {
		return nil, fmt.Errorf("snapshot: ciphertext too short")
	}
	return gcm.Open(nil, data[:ns], data[ns:], nil)
}
