package db

import (
	"database/sql"
	"fmt"

	"authvault/api/internal/models"
)

// MigrateSnapshots creates the snapshots metadata table.
func MigrateSnapshots() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS snapshots (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		type         TEXT NOT NULL DEFAULT 'full',
		base_id      INTEGER NOT NULL DEFAULT 0,
		file_name    TEXT NOT NULL,
		size_bytes   INTEGER NOT NULL DEFAULT 0,
		record_count INTEGER NOT NULL DEFAULT 0,
		s3_uploaded  INTEGER NOT NULL DEFAULT 0,
		created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	if err != nil {
		return fmt.Errorf("migrate snapshots: %w", err)
	}
	return nil
}

// InsertSnapshot records snapshot metadata and returns its ID.
func InsertSnapshot(s *models.Snapshot) (int64, error) {
	res, err := db.Exec(
		`INSERT INTO snapshots(type,base_id,file_name,size_bytes,record_count) VALUES(?,?,?,?,?)`,
		s.Type, s.BaseID, s.FileName, s.SizeBytes, s.RecordCount,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// GetSnapshots returns all snapshot metadata, newest first.
func GetSnapshots() ([]models.Snapshot, error) {
	rows, err := db.Query(
		`SELECT id,type,base_id,file_name,size_bytes,record_count,s3_uploaded,created_at FROM snapshots ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.Snapshot
	for rows.Next() {
		var s models.Snapshot
		var s3u int
		rows.Scan(&s.ID, &s.Type, &s.BaseID, &s.FileName, &s.SizeBytes, &s.RecordCount, &s3u, &s.CreatedAt)
		s.S3Uploaded = s3u == 1
		list = append(list, s)
	}
	if list == nil {
		list = []models.Snapshot{}
	}
	return list, rows.Err()
}

// GetSnapshot returns a single snapshot by ID.
func GetSnapshot(id int64) (*models.Snapshot, error) {
	var s models.Snapshot
	var s3u int
	err := db.QueryRow(
		`SELECT id,type,base_id,file_name,size_bytes,record_count,s3_uploaded,created_at FROM snapshots WHERE id=?`, id,
	).Scan(&s.ID, &s.Type, &s.BaseID, &s.FileName, &s.SizeBytes, &s.RecordCount, &s3u, &s.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.S3Uploaded = s3u == 1
	return &s, nil
}

// GetLastFullSnapshot returns the most recent full snapshot, or nil.
func GetLastFullSnapshot() (*models.Snapshot, error) {
	var s models.Snapshot
	var s3u int
	err := db.QueryRow(
		`SELECT id,type,base_id,file_name,size_bytes,record_count,s3_uploaded,created_at FROM snapshots WHERE type='full' ORDER BY created_at DESC LIMIT 1`,
	).Scan(&s.ID, &s.Type, &s.BaseID, &s.FileName, &s.SizeBytes, &s.RecordCount, &s3u, &s.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.S3Uploaded = s3u == 1
	return &s, nil
}

// MarkSnapshotS3Uploaded marks a snapshot as uploaded to S3.
func MarkSnapshotS3Uploaded(id int64) {
	db.Exec(`UPDATE snapshots SET s3_uploaded=1 WHERE id=?`, id)
}

// DeleteSnapshotRecord removes a snapshot metadata row.
func DeleteSnapshotRecord(id int64) error {
	_, err := db.Exec(`DELETE FROM snapshots WHERE id=?`, id)
	return err
}

// CountAndSizeSnapshots returns count and total bytes of stored snapshots.
func CountAndSizeSnapshots() (count int, totalBytes int64) {
	db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(size_bytes),0) FROM snapshots`).Scan(&count, &totalBytes)
	return
}

// GetIncrementalsSince returns all incremental snapshots with base_id == baseID ordered by created_at.
func GetIncrementalsSince(baseID int64) ([]models.Snapshot, error) {
	rows, err := db.Query(
		`SELECT id,type,base_id,file_name,size_bytes,record_count,s3_uploaded,created_at FROM snapshots WHERE type='incremental' AND base_id=? ORDER BY created_at ASC`,
		baseID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.Snapshot
	for rows.Next() {
		var s models.Snapshot
		var s3u int
		rows.Scan(&s.ID, &s.Type, &s.BaseID, &s.FileName, &s.SizeBytes, &s.RecordCount, &s3u, &s.CreatedAt)
		s.S3Uploaded = s3u == 1
		list = append(list, s)
	}
	return list, rows.Err()
}

// ── Raw data access for snapshot creation ────────────────────────────────────

// RawTOTP holds encrypted TOTP fields for snapshot purposes.
type RawTOTP struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Issuer    string `json:"issuer"`
	SecretEnc string `json:"secret_enc"`
	Duration  int    `json:"duration"`
	Length    int    `json:"length"`
	HashAlgo  int    `json:"hash_algo"`
	CreatedAt int64  `json:"created_at"`
	UpdatedAt int64  `json:"updated_at"`
}

// RawFolder holds safe folder fields for snapshot purposes.
type RawFolder struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	ParentID *int64 `json:"parent_id"`
	UpdatedAt int64 `json:"updated_at"`
}

// RawRecord holds encrypted safe record fields for snapshot purposes.
type RawRecord struct {
	ID        int64  `json:"id"`
	FolderID  int64  `json:"folder_id"`
	NameEnc   string `json:"name_enc"`
	LoginEnc  string `json:"login_enc"`
	PassEnc   string `json:"pass_enc"`
	CreatedAt int64  `json:"created_at"`
	UpdatedAt int64  `json:"updated_at"`
}

// RawItem holds encrypted safe item fields for snapshot purposes.
type RawItem struct {
	ID         int64  `json:"id"`
	RecordID   int64  `json:"record_id"`
	NameEnc    string `json:"name_enc"`
	ContentEnc string `json:"content_enc"`
	UpdatedAt  int64  `json:"updated_at"`
}

// RawSSHKey holds encrypted SSH key fields for snapshot purposes.
type RawSSHKey struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	PublicKeyEnc  string `json:"public_key_enc"`
	PrivateKeyEnc string `json:"private_key_enc"`
	CommentEnc    string `json:"comment_enc"`
	CreatedAt     int64  `json:"created_at"`
	UpdatedAt     int64  `json:"updated_at"`
}

// AllTOTPRaw returns all TOTP entries as raw encrypted rows.
func AllTOTPRaw(since int64) ([]RawTOTP, error) {
	q := `SELECT id,name,issuer,secret_enc,duration,length,hash_algo,created_at,COALESCE(updated_at,created_at) FROM totp_entries`
	args := []interface{}{}
	if since > 0 {
		q += ` WHERE COALESCE(updated_at,created_at) > ?`
		args = append(args, since)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RawTOTP
	for rows.Next() {
		var r RawTOTP
		rows.Scan(&r.ID, &r.Name, &r.Issuer, &r.SecretEnc, &r.Duration, &r.Length, &r.HashAlgo, &r.CreatedAt, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}

// AllFoldersRaw returns all folder rows.
func AllFoldersRaw(since int64) ([]RawFolder, error) {
	q := `SELECT id,name,parent_id,COALESCE(updated_at,0) FROM safe_folders`
	args := []interface{}{}
	if since > 0 {
		q += ` WHERE COALESCE(updated_at,0) > ?`
		args = append(args, since)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RawFolder
	for rows.Next() {
		var r RawFolder
		rows.Scan(&r.ID, &r.Name, &r.ParentID, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}

// AllRecordsRaw returns all safe_records as raw encrypted rows.
func AllRecordsRaw(since int64) ([]RawRecord, error) {
	q := `SELECT id,folder_id,name_enc,login_enc,pass_enc,COALESCE(created_at,0),COALESCE(updated_at,created_at) FROM safe_records`
	args := []interface{}{}
	if since > 0 {
		q += ` WHERE COALESCE(updated_at,created_at) > ?`
		args = append(args, since)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RawRecord
	for rows.Next() {
		var r RawRecord
		rows.Scan(&r.ID, &r.FolderID, &r.NameEnc, &r.LoginEnc, &r.PassEnc, &r.CreatedAt, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}

// AllItemsRaw returns all safe_items as raw encrypted rows.
func AllItemsRaw(since int64) ([]RawItem, error) {
	q := `SELECT id,record_id,name_enc,content_enc,COALESCE(updated_at,0) FROM safe_items`
	args := []interface{}{}
	if since > 0 {
		q += ` WHERE COALESCE(updated_at,0) > ?`
		args = append(args, since)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RawItem
	for rows.Next() {
		var r RawItem
		rows.Scan(&r.ID, &r.RecordID, &r.NameEnc, &r.ContentEnc, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}

// AllSSHKeysRaw returns all SSH key rows with encrypted fields.
func AllSSHKeysRaw(since int64) ([]RawSSHKey, error) {
	q := `SELECT id,name,public_key_enc,private_key_enc,comment_enc,created_at,COALESCE(updated_at,created_at) FROM ssh_keys`
	args := []interface{}{}
	if since > 0 {
		q += ` WHERE COALESCE(updated_at,created_at) > ?`
		args = append(args, since)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []RawSSHKey
	for rows.Next() {
		var r RawSSHKey
		rows.Scan(&r.ID, &r.Name, &r.PublicKeyEnc, &r.PrivateKeyEnc, &r.CommentEnc, &r.CreatedAt, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}

// ── Restore helpers ───────────────────────────────────────────────────────────

// RestoreFullSnapshot completely replaces all vault data from raw rows.
// Called inside a transaction (the caller begins/commits/rolls-back).
func RestoreFullSnapshot(
	totp []RawTOTP,
	folders []RawFolder,
	records []RawRecord,
	items []RawItem,
	sshKeys []RawSSHKey,
) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	tables := []string{"safe_items", "safe_records", "safe_folders", "totp_entries", "ssh_keys"}
	for _, t := range tables {
		if _, err := tx.Exec("DELETE FROM " + t); err != nil {
			return fmt.Errorf("clear %s: %w", t, err)
		}
	}

	for _, r := range totp {
		_, err := tx.Exec(
			`INSERT INTO totp_entries(id,name,issuer,secret_enc,duration,length,hash_algo,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)`,
			r.ID, r.Name, r.Issuer, r.SecretEnc, r.Duration, r.Length, r.HashAlgo, r.CreatedAt, r.UpdatedAt,
		)
		if err != nil {
			return fmt.Errorf("restore totp %d: %w", r.ID, err)
		}
	}
	for _, f := range folders {
		_, err := tx.Exec(`INSERT INTO safe_folders(id,name,parent_id,updated_at) VALUES(?,?,?,?)`, f.ID, f.Name, f.ParentID, f.UpdatedAt)
		if err != nil {
			return fmt.Errorf("restore folder %d: %w", f.ID, err)
		}
	}
	for _, rec := range records {
		_, err := tx.Exec(
			`INSERT INTO safe_records(id,folder_id,name_enc,login_enc,pass_enc,created_at,updated_at) VALUES(?,?,?,?,?,?,?)`,
			rec.ID, rec.FolderID, rec.NameEnc, rec.LoginEnc, rec.PassEnc, rec.CreatedAt, rec.UpdatedAt,
		)
		if err != nil {
			return fmt.Errorf("restore record %d: %w", rec.ID, err)
		}
	}
	for _, it := range items {
		_, err := tx.Exec(
			`INSERT INTO safe_items(id,record_id,name_enc,content_enc,updated_at) VALUES(?,?,?,?,?)`,
			it.ID, it.RecordID, it.NameEnc, it.ContentEnc, it.UpdatedAt,
		)
		if err != nil {
			return fmt.Errorf("restore item %d: %w", it.ID, err)
		}
	}
	for _, k := range sshKeys {
		_, err := tx.Exec(
			`INSERT INTO ssh_keys(id,name,public_key_enc,private_key_enc,comment_enc,created_at,updated_at) VALUES(?,?,?,?,?,?,?)`,
			k.ID, k.Name, k.PublicKeyEnc, k.PrivateKeyEnc, k.CommentEnc, k.CreatedAt, k.UpdatedAt,
		)
		if err != nil {
			return fmt.Errorf("restore ssh key %d: %w", k.ID, err)
		}
	}

	return tx.Commit()
}

// ApplyIncrementalSnapshot upserts changed rows from an incremental snapshot.
func ApplyIncrementalSnapshot(
	totp []RawTOTP,
	folders []RawFolder,
	records []RawRecord,
	items []RawItem,
	sshKeys []RawSSHKey,
) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, r := range totp {
		tx.Exec(
			`INSERT INTO totp_entries(id,name,issuer,secret_enc,duration,length,hash_algo,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET name=excluded.name,issuer=excluded.issuer,secret_enc=excluded.secret_enc,
			   duration=excluded.duration,length=excluded.length,hash_algo=excluded.hash_algo,updated_at=excluded.updated_at`,
			r.ID, r.Name, r.Issuer, r.SecretEnc, r.Duration, r.Length, r.HashAlgo, r.CreatedAt, r.UpdatedAt,
		)
	}
	for _, f := range folders {
		tx.Exec(
			`INSERT INTO safe_folders(id,name,parent_id,updated_at) VALUES(?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET name=excluded.name,parent_id=excluded.parent_id,updated_at=excluded.updated_at`,
			f.ID, f.Name, f.ParentID, f.UpdatedAt,
		)
	}
	for _, rec := range records {
		tx.Exec(
			`INSERT INTO safe_records(id,folder_id,name_enc,login_enc,pass_enc,created_at,updated_at) VALUES(?,?,?,?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET folder_id=excluded.folder_id,name_enc=excluded.name_enc,
			   login_enc=excluded.login_enc,pass_enc=excluded.pass_enc,updated_at=excluded.updated_at`,
			rec.ID, rec.FolderID, rec.NameEnc, rec.LoginEnc, rec.PassEnc, rec.CreatedAt, rec.UpdatedAt,
		)
	}
	for _, it := range items {
		tx.Exec(
			`INSERT INTO safe_items(id,record_id,name_enc,content_enc,updated_at) VALUES(?,?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET record_id=excluded.record_id,name_enc=excluded.name_enc,
			   content_enc=excluded.content_enc,updated_at=excluded.updated_at`,
			it.ID, it.RecordID, it.NameEnc, it.ContentEnc, it.UpdatedAt,
		)
	}
	for _, k := range sshKeys {
		tx.Exec(
			`INSERT INTO ssh_keys(id,name,public_key_enc,private_key_enc,comment_enc,created_at,updated_at) VALUES(?,?,?,?,?,?,?)
			 ON CONFLICT(id) DO UPDATE SET name=excluded.name,public_key_enc=excluded.public_key_enc,
			   private_key_enc=excluded.private_key_enc,comment_enc=excluded.comment_enc,updated_at=excluded.updated_at`,
			k.ID, k.Name, k.PublicKeyEnc, k.PrivateKeyEnc, k.CommentEnc, k.CreatedAt, k.UpdatedAt,
		)
	}

	return tx.Commit()
}
