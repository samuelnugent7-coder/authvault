package db

import (
	"encoding/json"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

func MigrateRecordVersions() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS record_versions (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		record_id    INTEGER NOT NULL,
		version_num  INTEGER NOT NULL DEFAULT 1,
		name_enc     TEXT    NOT NULL DEFAULT '',
		login_enc    TEXT    NOT NULL DEFAULT '',
		pass_enc     TEXT    NOT NULL DEFAULT '',
		items_enc    TEXT    NOT NULL DEFAULT '',
		changed_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		changed_by   TEXT    NOT NULL DEFAULT ''
	)`)
	return err
}

// CaptureRecordVersion snapshots the current record state before modification.
func CaptureRecordVersion(r *models.SafeRecord, changedBy string) error {
	var maxVer int
	db.QueryRow(`SELECT COALESCE(MAX(version_num),0) FROM record_versions WHERE record_id=?`, r.ID).Scan(&maxVer)

	nameEnc, _ := crypto.Encrypt(r.Name)
	loginEnc, _ := crypto.Encrypt(r.Login)
	passEnc, _ := crypto.Encrypt(r.Password)

	itemsJSON, _ := json.Marshal(r.Items)
	itemsEnc, _ := crypto.Encrypt(string(itemsJSON))

	_, err := db.Exec(
		`INSERT INTO record_versions(record_id,version_num,name_enc,login_enc,pass_enc,items_enc,changed_by)
		 VALUES(?,?,?,?,?,?,?)`,
		r.ID, maxVer+1, nameEnc, loginEnc, passEnc, itemsEnc, changedBy,
	)
	return err
}

// GetRecordVersions returns decrypted version history (newest first).
func GetRecordVersions(recordID int64) ([]models.RecordVersion, error) {
	rows, err := db.Query(
		`SELECT id,record_id,version_num,name_enc,login_enc,pass_enc,items_enc,changed_at,changed_by
		 FROM record_versions WHERE record_id=? ORDER BY version_num DESC`, recordID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.RecordVersion
	for rows.Next() {
		var v models.RecordVersion
		var ne, le, pe, ie string
		if err := rows.Scan(&v.ID, &v.RecordID, &v.VersionNum, &ne, &le, &pe, &ie, &v.ChangedAt, &v.ChangedBy); err != nil {
			return nil, err
		}
		v.Name, _ = crypto.Decrypt(ne)
		v.Login, _ = crypto.Decrypt(le)
		v.Password, _ = crypto.Decrypt(pe)
		v.ItemsJSON, _ = crypto.Decrypt(ie)
		list = append(list, v)
	}
	return list, rows.Err()
}

// RestoreRecordVersion re-applies a version snapshot to the live record.
func RestoreRecordVersion(versionID int64) (*models.SafeRecord, error) {
	var v models.RecordVersion
	var ne, le, pe, ie string
	err := db.QueryRow(
		`SELECT id,record_id,name_enc,login_enc,pass_enc,items_enc FROM record_versions WHERE id=?`, versionID,
	).Scan(&v.ID, &v.RecordID, &ne, &le, &pe, &ie)
	if err != nil {
		return nil, err
	}
	v.Name, _ = crypto.Decrypt(ne)
	v.Login, _ = crypto.Decrypt(le)
	v.Password, _ = crypto.Decrypt(pe)
	itemsStr, _ := crypto.Decrypt(ie)

	r := &models.SafeRecord{
		ID:       v.RecordID,
		Name:     v.Name,
		Login:    v.Login,
		Password: v.Password,
	}
	if itemsStr != "" {
		json.Unmarshal([]byte(itemsStr), &r.Items)
	}

	// Re-use UpdateRecord to persist
	if err := UpdateRecord(r); err != nil {
		return nil, err
	}
	return r, nil
}
