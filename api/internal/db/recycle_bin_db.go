package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

func MigrateRecycleBin() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS recycle_bin (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		item_type   TEXT    NOT NULL,
		original_id INTEGER NOT NULL,
		folder_id   INTEGER NOT NULL DEFAULT 0,
		name_enc    TEXT    NOT NULL,
		data_enc    TEXT    NOT NULL,
		deleted_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		deleted_by  TEXT    NOT NULL DEFAULT '',
		expires_at  INTEGER NOT NULL
	)`)
	return err
}

// SoftDeleteRecord moves a record (+ its items) into recycle bin.
func SoftDeleteRecord(r *models.SafeRecord, deletedBy string) error {
	// Snapshot current state as JSON, then encrypt
	data, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("marshal record: %w", err)
	}
	dataEnc, err := crypto.Encrypt(string(data))
	if err != nil {
		return err
	}
	nameEnc, err := crypto.Encrypt(r.Name)
	if err != nil {
		return err
	}
	exp := time.Now().Add(30 * 24 * time.Hour).Unix()
	_, err = db.Exec(
		`INSERT INTO recycle_bin(item_type,original_id,folder_id,name_enc,data_enc,deleted_by,expires_at)
		 VALUES('record',?,?,?,?,?,?)`,
		r.ID, r.FolderID, nameEnc, dataEnc, deletedBy, exp,
	)
	if err != nil {
		return err
	}
	// Delete the actual record (cascade deletes items + attachments)
	_, err = db.Exec(`DELETE FROM safe_records WHERE id=?`, r.ID)
	return err
}

// SoftDeleteNote moves a secure note into recycle bin.
func SoftDeleteNote(note *models.SecureNote, deletedBy string) error {
	data, err := json.Marshal(note)
	if err != nil {
		return err
	}
	dataEnc, err := crypto.Encrypt(string(data))
	if err != nil {
		return err
	}
	nameEnc, err := crypto.Encrypt(note.Title)
	if err != nil {
		return err
	}
	exp := time.Now().Add(30 * 24 * time.Hour).Unix()
	_, err = db.Exec(
		`INSERT INTO recycle_bin(item_type,original_id,folder_id,name_enc,data_enc,deleted_by,expires_at)
		 VALUES('note',?,0,?,?,?,?)`,
		note.ID, nameEnc, dataEnc, deletedBy, exp,
	)
	if err != nil {
		return err
	}
	_, err = db.Exec(`DELETE FROM secure_notes WHERE id=?`, note.ID)
	return err
}

// ListRecycleBin returns all non-expired recycle bin entries (names decrypted).
func ListRecycleBin() ([]models.RecycleBinEntry, error) {
	now := time.Now().Unix()
	rows, err := db.Query(
		`SELECT id,item_type,original_id,folder_id,name_enc,deleted_at,deleted_by,expires_at
		 FROM recycle_bin WHERE expires_at > ? ORDER BY deleted_at DESC`, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.RecycleBinEntry
	for rows.Next() {
		var e models.RecycleBinEntry
		var nameEnc string
		if err := rows.Scan(&e.ID, &e.ItemType, &e.OriginalID, &e.FolderID,
			&nameEnc, &e.DeletedAt, &e.DeletedBy, &e.ExpiresAt); err != nil {
			return nil, err
		}
		e.Name, _ = crypto.Decrypt(nameEnc)
		list = append(list, e)
	}
	return list, rows.Err()
}

// RestoreRecord restores a record from recycle bin back to its folder.
// Returns the restored record ID (may differ from original if folder was deleted).
func RestoreFromRecycleBin(binID int64, username string) (*models.RecycleBinEntry, error) {
	var e models.RecycleBinEntry
	var dataEnc, nameEnc string
	err := db.QueryRow(
		`SELECT id,item_type,original_id,folder_id,name_enc,data_enc,expires_at FROM recycle_bin WHERE id=?`, binID,
	).Scan(&e.ID, &e.ItemType, &e.OriginalID, &e.FolderID, &nameEnc, &dataEnc, &e.ExpiresAt)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("not found")
	}
	if err != nil {
		return nil, err
	}
	if time.Now().Unix() > e.ExpiresAt {
		return nil, fmt.Errorf("recycle bin entry has expired")
	}
	e.Name, _ = crypto.Decrypt(nameEnc)

	jsonStr, err := crypto.Decrypt(dataEnc)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}

	switch e.ItemType {
	case "record":
		var r models.SafeRecord
		if err := json.Unmarshal([]byte(jsonStr), &r); err != nil {
			return nil, err
		}
		// Check folder still exists; if not, place at root folder (create if needed)
		var folderExists int
		db.QueryRow(`SELECT COUNT(*) FROM safe_folders WHERE id=?`, r.FolderID).Scan(&folderExists)
		if folderExists == 0 {
			// Re-create parent folder
			res, _ := db.Exec(`INSERT INTO safe_folders(name) VALUES('Restored')`)
			r.FolderID, _ = res.LastInsertId()
		}
		r.ID = 0 // let DB assign new id
		newID, err := InsertRecord(&r)
		if err != nil {
			return nil, err
		}
		e.OriginalID = newID
	case "note":
		var n models.SecureNote
		if err := json.Unmarshal([]byte(jsonStr), &n); err != nil {
			return nil, err
		}
		n.ID = 0
		newID, err := InsertSecureNote(&n)
		if err != nil {
			return nil, err
		}
		e.OriginalID = newID
	case "totp":
		var t models.TOTPEntry
		if err := json.Unmarshal([]byte(jsonStr), &t); err != nil {
			return nil, err
		}
		t.ID = 0
		newID, err := InsertTOTP(&t)
		if err != nil {
			return nil, err
		}
		e.OriginalID = newID
	case "folder":
		var stub struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal([]byte(jsonStr), &stub); err != nil {
			return nil, err
		}
		res, err := db.Exec(`INSERT INTO safe_folders(name) VALUES(?)`, stub.Name)
		if err != nil {
			return nil, err
		}
		newID, _ := res.LastInsertId()
		e.OriginalID = newID
	}

	_, err = db.Exec(`DELETE FROM recycle_bin WHERE id=?`, binID)
	return &e, err
}

// PurgeExpiredBin removes entries older than 30 days.
func PurgeExpiredBin() error {
	_, err := db.Exec(`DELETE FROM recycle_bin WHERE expires_at <= ?`, time.Now().Unix())
	return err
}

// DeleteBinEntry permanently removes a single recycle bin entry.
func DeleteBinEntry(id int64) error {
	_, err := db.Exec(`DELETE FROM recycle_bin WHERE id=?`, id)
	return err
}

// RecycleBinCount returns number of non-expired entries.
func RecycleBinCount() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM recycle_bin WHERE expires_at > ?`, time.Now().Unix()).Scan(&n)
	return n
}

// SoftDeleteTOTP moves a TOTP entry into the recycle bin.
func SoftDeleteTOTP(e *models.TOTPEntry, deletedBy string) error {
	data, err := json.Marshal(e)
	if err != nil {
		return err
	}
	dataEnc, err := crypto.Encrypt(string(data))
	if err != nil {
		return err
	}
	nameEnc, err := crypto.Encrypt(e.Name)
	if err != nil {
		return err
	}
	exp := time.Now().Add(30 * 24 * time.Hour).Unix()
	_, err = db.Exec(
		`INSERT INTO recycle_bin(item_type,original_id,folder_id,name_enc,data_enc,deleted_by,expires_at)
		 VALUES('totp',?,0,?,?,?,?)`,
		e.ID, nameEnc, dataEnc, deletedBy, exp,
	)
	if err != nil {
		return err
	}
	_, err = db.Exec(`DELETE FROM totp_entries WHERE id=?`, e.ID)
	return err
}

// SoftDeleteFolder serialises the folder name and moves it to the recycle bin.
// Its child records should already be individually soft-deleted by the caller.
func SoftDeleteFolder(folderID int64, folderName, deletedBy string) error {
	stub := map[string]interface{}{"id": folderID, "name": folderName}
	data, _ := json.Marshal(stub)
	dataEnc, err := crypto.Encrypt(string(data))
	if err != nil {
		return err
	}
	nameEnc, err := crypto.Encrypt(folderName)
	if err != nil {
		return err
	}
	exp := time.Now().Add(30 * 24 * time.Hour).Unix()
	_, err = db.Exec(
		`INSERT INTO recycle_bin(item_type,original_id,folder_id,name_enc,data_enc,deleted_by,expires_at)
		 VALUES('folder',?,?,?,?,?,?)`,
		folderID, folderID, nameEnc, dataEnc, deletedBy, exp,
	)
	if err != nil {
		return err
	}
	_, err = db.Exec(`DELETE FROM safe_folders WHERE id=?`, folderID)
	return err
}
