package db

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"

	"authvault/api/internal/models"
)

func MigrateAPIKeys() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS api_keys (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		name         TEXT    NOT NULL,
		key_prefix   TEXT    NOT NULL,
		key_hash     TEXT    NOT NULL UNIQUE,
		created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		last_used_at INTEGER NOT NULL DEFAULT 0,
		expires_at   INTEGER NOT NULL DEFAULT 0,
		revoked      INTEGER NOT NULL DEFAULT 0
	)`)
	return err
}

// GenerateAPIKey creates a new API key, stores its hash, returns the full key (shown once).
func GenerateAPIKey(userID int64, name string, expiresAt int64) (*models.APIKey, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, fmt.Errorf("rand: %w", err)
	}
	fullKey := "av_" + hex.EncodeToString(raw)
	prefix := fullKey[:11] // "av_" + first 8 hex chars
	hash := sha256.Sum256([]byte(fullKey))
	hashHex := hex.EncodeToString(hash[:])

	res, err := db.Exec(
		`INSERT INTO api_keys(user_id,name,key_prefix,key_hash,expires_at) VALUES(?,?,?,?,?)`,
		userID, name, prefix, hashHex, expiresAt,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &models.APIKey{
		ID:        id,
		UserID:    userID,
		Name:      name,
		KeyPrefix: prefix,
		KeyFull:   fullKey,
		CreatedAt: time.Now().Unix(),
		ExpiresAt: expiresAt,
	}, nil
}

// ValidateAPIKey checks a raw key, returns user_id + key record if valid.
func ValidateAPIKey(rawKey string) (int64, *models.APIKey, error) {
	hash := sha256.Sum256([]byte(rawKey))
	hashHex := hex.EncodeToString(hash[:])
	var k models.APIKey
	var revoked int
	err := db.QueryRow(
		`SELECT id,user_id,name,key_prefix,created_at,last_used_at,expires_at,revoked
		 FROM api_keys WHERE key_hash=?`, hashHex,
	).Scan(&k.ID, &k.UserID, &k.Name, &k.KeyPrefix, &k.CreatedAt, &k.LastUsedAt, &k.ExpiresAt, &revoked)
	if err == sql.ErrNoRows {
		return 0, nil, nil
	}
	if err != nil {
		return 0, nil, err
	}
	k.Revoked = revoked == 1
	if k.Revoked {
		return 0, nil, nil
	}
	if k.ExpiresAt > 0 && time.Now().Unix() > k.ExpiresAt {
		return 0, nil, nil
	}
	// Update last_used_at
	db.Exec(`UPDATE api_keys SET last_used_at=? WHERE id=?`, time.Now().Unix(), k.ID)
	return k.UserID, &k, nil
}

func ListAPIKeys(userID int64) ([]models.APIKey, error) {
	rows, err := db.Query(
		`SELECT id,user_id,name,key_prefix,created_at,last_used_at,expires_at,revoked
		 FROM api_keys WHERE user_id=? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.APIKey
	for rows.Next() {
		var k models.APIKey
		var revoked int
		rows.Scan(&k.ID, &k.UserID, &k.Name, &k.KeyPrefix, &k.CreatedAt, &k.LastUsedAt, &k.ExpiresAt, &revoked)
		k.Revoked = revoked == 1
		list = append(list, k)
	}
	return list, rows.Err()
}

func RevokeAPIKey(id, userID int64) error {
	_, err := db.Exec(`UPDATE api_keys SET revoked=1 WHERE id=? AND user_id=?`, id, userID)
	return err
}

func DeleteAPIKey(id, userID int64) error {
	_, err := db.Exec(`DELETE FROM api_keys WHERE id=? AND user_id=?`, id, userID)
	return err
}

func APIKeysCount(userID int64) int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM api_keys WHERE user_id=? AND revoked=0`, userID).Scan(&n)
	return n
}
