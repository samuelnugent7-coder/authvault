package db

import (
	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

func MigratePasswordHistory() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS password_history (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		record_id   INTEGER NOT NULL REFERENCES safe_records(id) ON DELETE CASCADE,
		old_pass_enc TEXT NOT NULL,
		changed_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		changed_by  TEXT    NOT NULL DEFAULT ''
	)`)
	return err
}

// RecordPasswordHistory saves a password value to history before it changes.
func RecordPasswordHistory(recordID int64, oldPlainPass, changedBy string) error {
	if oldPlainPass == "" {
		return nil
	}
	enc, err := crypto.Encrypt(oldPlainPass)
	if err != nil {
		return err
	}
	_, err = db.Exec(
		`INSERT INTO password_history(record_id,old_pass_enc,changed_by) VALUES(?,?,?)`,
		recordID, enc, changedBy,
	)
	return err
}

// GetPasswordHistory returns decrypted history for a record (newest first).
func GetPasswordHistory(recordID int64) ([]models.PasswordHistoryEntry, error) {
	rows, err := db.Query(
		`SELECT id,record_id,old_pass_enc,changed_at,changed_by
		 FROM password_history WHERE record_id=? ORDER BY changed_at DESC`, recordID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.PasswordHistoryEntry
	for rows.Next() {
		var e models.PasswordHistoryEntry
		var enc string
		if err := rows.Scan(&e.ID, &e.RecordID, &enc, &e.ChangedAt, &e.ChangedBy); err != nil {
			return nil, err
		}
		e.OldPass, _ = crypto.Decrypt(enc)
		list = append(list, e)
	}
	return list, rows.Err()
}
