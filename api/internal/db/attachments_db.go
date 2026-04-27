package db

import (
	"database/sql"
	"encoding/base64"
	"fmt"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

// MigrateAttachments creates the attachments table.
func MigrateAttachments() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS attachments (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		record_id   INTEGER NOT NULL REFERENCES safe_records(id) ON DELETE CASCADE,
		name        TEXT NOT NULL,
		mime_type   TEXT NOT NULL DEFAULT 'application/octet-stream',
		size_bytes  INTEGER NOT NULL DEFAULT 0,
		data_enc    TEXT NOT NULL,
		created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	if err != nil {
		return fmt.Errorf("migrate attachments: %w", err)
	}
	return nil
}

// InsertAttachment stores an encrypted attachment. data must be raw bytes (base64 decoded from request).
func InsertAttachment(a *models.Attachment, rawData []byte) (int64, error) {
	enc, err := crypto.EncryptWithKey(rawData, nil) // uses active key via encrypt helper
	if err != nil {
		return 0, err
	}
	_ = enc
	// Use the standard Encrypt over the base64 repr to keep it simple
	dataEnc, err := crypto.Encrypt(base64.StdEncoding.EncodeToString(rawData))
	if err != nil {
		return 0, err
	}
	res, err := db.Exec(
		`INSERT INTO attachments(record_id,name,mime_type,size_bytes,data_enc) VALUES(?,?,?,?,?)`,
		a.RecordID, a.Name, a.MimeType, len(rawData), dataEnc,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// GetAttachmentsByRecord returns attachment metadata (no data) for a record.
func GetAttachmentsByRecord(recordID int64) ([]models.Attachment, error) {
	rows, err := db.Query(
		`SELECT id,record_id,name,mime_type,size_bytes,created_at FROM attachments WHERE record_id=? ORDER BY id`,
		recordID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.Attachment
	for rows.Next() {
		var a models.Attachment
		rows.Scan(&a.ID, &a.RecordID, &a.Name, &a.MimeType, &a.SizeBytes, &a.CreatedAt)
		list = append(list, a)
	}
	if list == nil {
		list = []models.Attachment{}
	}
	return list, rows.Err()
}

// GetAttachmentData returns a single attachment with decrypted data as base64.
func GetAttachmentData(id int64) (*models.Attachment, []byte, error) {
	var a models.Attachment
	var dataEnc string
	err := db.QueryRow(
		`SELECT id,record_id,name,mime_type,size_bytes,data_enc,created_at FROM attachments WHERE id=?`, id,
	).Scan(&a.ID, &a.RecordID, &a.Name, &a.MimeType, &a.SizeBytes, &dataEnc, &a.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	// Decrypt: the stored value is Encrypt(base64(rawBytes))
	b64plain, err := crypto.Decrypt(dataEnc)
	if err != nil {
		return nil, nil, fmt.Errorf("decrypt attachment %d: %w", id, err)
	}
	rawData, err := base64.StdEncoding.DecodeString(b64plain)
	if err != nil {
		return nil, nil, fmt.Errorf("decode attachment %d: %w", id, err)
	}
	return &a, rawData, nil
}

// DeleteAttachment removes an attachment by ID.
func DeleteAttachment(id int64) error {
	_, err := db.Exec(`DELETE FROM attachments WHERE id=?`, id)
	return err
}
