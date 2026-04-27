package db

import (
	"database/sql"
	"fmt"
	"path/filepath"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"

	_ "modernc.org/sqlite"
)

var db *sql.DB

// Open initialises the SQLite database at the given data directory.
func Open(dataDir string) error {
	path := filepath.Join(dataDir, "vault.db")
	var err error
	db, err = sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(on)")
	if err != nil {
		return fmt.Errorf("opening db: %w", err)
	}
	return migrate()
}

func migrate() error {
	if err := EnsureBackupMigration(); err != nil {
		return err
	}
	if err := MigrateUsers(); err != nil {
		return err
	}
	if err := MigrateAudit(); err != nil {
		return err
	}
	if err := MigrateSessions(); err != nil {
		return err
	}
	if err := MigrateSSH(); err != nil {
		return err
	}
	if err := MigrateSnapshots(); err != nil {
		return err
	}
	if err := MigrateBackupQueue(); err != nil {
		return err
	}
	if err := MigrateRecycleBin(); err != nil {
		return err
	}
	if err := MigratePasswordHistory(); err != nil {
		return err
	}
	if err := MigrateSecureNotes(); err != nil {
		return err
	}
	if err := MigrateTags(); err != nil {
		return err
	}
	if err := MigrateFolderShares(); err != nil {
		return err
	}
	if err := MigrateAPIKeys(); err != nil {
		return err
	}
	if err := MigrateShareLinks(); err != nil {
		return err
	}
	if err := MigrateRecordVersions(); err != nil {
		return err
	}
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS totp_entries (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			name       TEXT NOT NULL,
			issuer     TEXT NOT NULL DEFAULT '',
			secret_enc TEXT NOT NULL,
			duration   INTEGER NOT NULL DEFAULT 30,
			length     INTEGER NOT NULL DEFAULT 6,
			hash_algo  INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
		)`,
		`CREATE TABLE IF NOT EXISTS safe_folders (
			id        INTEGER PRIMARY KEY AUTOINCREMENT,
			name      TEXT NOT NULL,
			parent_id INTEGER REFERENCES safe_folders(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS safe_records (
			id        INTEGER PRIMARY KEY AUTOINCREMENT,
			folder_id INTEGER NOT NULL REFERENCES safe_folders(id) ON DELETE CASCADE,
			name_enc  TEXT NOT NULL,
			login_enc TEXT NOT NULL DEFAULT '',
			pass_enc  TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS safe_items (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			record_id  INTEGER NOT NULL REFERENCES safe_records(id) ON DELETE CASCADE,
			name_enc   TEXT NOT NULL,
			content_enc TEXT NOT NULL DEFAULT ''
		)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	if err := MigrateAttachments(); err != nil {
		return err
	}
	// Add created_at to safe_records if it doesn't exist (idempotent)
	db.Exec(`ALTER TABLE safe_records ADD COLUMN created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	// Add updated_at columns for incremental snapshot tracking (idempotent)
	db.Exec(`ALTER TABLE totp_entries  ADD COLUMN updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	db.Exec(`ALTER TABLE safe_folders  ADD COLUMN updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	db.Exec(`ALTER TABLE safe_records  ADD COLUMN updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	db.Exec(`ALTER TABLE safe_items    ADD COLUMN updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	db.Exec(`ALTER TABLE ssh_keys      ADD COLUMN updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))`)
	// Time-limited users
	db.Exec(`ALTER TABLE users ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0`)
	// Custom field types
	db.Exec(`ALTER TABLE safe_items ADD COLUMN field_type TEXT NOT NULL DEFAULT 'text'`)
	// Decoy folder flag
	db.Exec(`ALTER TABLE safe_folders ADD COLUMN is_decoy INTEGER NOT NULL DEFAULT 0`)
	return nil
}

// ---- TOTP ----

func InsertTOTP(e *models.TOTPEntry) (int64, error) {
	enc, err := crypto.Encrypt(e.Secret)
	if err != nil {
		return 0, err
	}
	res, err := db.Exec(
		`INSERT INTO totp_entries(name,issuer,secret_enc,duration,length,hash_algo) VALUES(?,?,?,?,?,?)`,
		e.Name, e.Issuer, enc, e.Duration, e.Length, e.HashAlgo,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func AllTOTP() ([]models.TOTPEntry, error) {
	rows, err := db.Query(`SELECT id,name,issuer,secret_enc,duration,length,hash_algo,created_at FROM totp_entries ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.TOTPEntry
	for rows.Next() {
		var e models.TOTPEntry
		var enc string
		if err := rows.Scan(&e.ID, &e.Name, &e.Issuer, &enc, &e.Duration, &e.Length, &e.HashAlgo, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.Secret, err = crypto.Decrypt(enc)
		if err != nil {
			return nil, fmt.Errorf("decrypt totp %d: %w", e.ID, err)
		}
		list = append(list, e)
	}
	return list, rows.Err()
}

func GetTOTP(id int64) (*models.TOTPEntry, error) {
	var e models.TOTPEntry
	var enc string
	err := db.QueryRow(`SELECT id,name,issuer,secret_enc,duration,length,hash_algo,created_at FROM totp_entries WHERE id=?`, id).
		Scan(&e.ID, &e.Name, &e.Issuer, &enc, &e.Duration, &e.Length, &e.HashAlgo, &e.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	e.Secret, err = crypto.Decrypt(enc)
	return &e, err
}

func UpdateTOTP(e *models.TOTPEntry) error {
	enc, err := crypto.Encrypt(e.Secret)
	if err != nil {
		return err
	}
	_, err = db.Exec(
		`UPDATE totp_entries SET name=?,issuer=?,secret_enc=?,duration=?,length=?,hash_algo=?,updated_at=strftime('%s','now') WHERE id=?`,
		e.Name, e.Issuer, enc, e.Duration, e.Length, e.HashAlgo, e.ID,
	)
	return err
}

func DeleteTOTP(id int64) error {
	_, err := db.Exec(`DELETE FROM totp_entries WHERE id=?`, id)
	return err
}

// ---- SAFE FOLDERS ----

func InsertFolder(name string, parentID *int64) (int64, error) {
	res, err := db.Exec(`INSERT INTO safe_folders(name,parent_id) VALUES(?,?)`, name, parentID)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func UpdateFolder(id int64, name string) error {
	_, err := db.Exec(`UPDATE safe_folders SET name=?,updated_at=strftime('%s','now') WHERE id=?`, name, id)
	return err
}

func DeleteFolder(id int64) error {
	_, err := db.Exec(`DELETE FROM safe_folders WHERE id=?`, id)
	return err
}

// GetFolderTree returns the full nested folder/record tree.
func GetFolderTree() ([]models.SafeFolder, error) {
	rows, err := db.Query(`SELECT id,name,parent_id FROM safe_folders ORDER BY parent_id, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	type rawFolder struct {
		id       int64
		name     string
		parentID *int64
	}
	var raws []rawFolder
	for rows.Next() {
		var f rawFolder
		if err := rows.Scan(&f.id, &f.name, &f.parentID); err != nil {
			return nil, err
		}
		raws = append(raws, f)
	}
	rows.Close()

	// Load all records
	allRecords, err := AllRecords()
	if err != nil {
		return nil, err
	}
	recordsByFolder := map[int64][]models.SafeRecord{}
	for _, r := range allRecords {
		recordsByFolder[r.FolderID] = append(recordsByFolder[r.FolderID], r)
	}

	// Build map of id → SafeFolder
	folderMap := map[int64]*models.SafeFolder{}
	for _, raw := range raws {
		f := &models.SafeFolder{
			ID:       raw.id,
			Name:     raw.name,
			ParentID: raw.parentID,
			Records:  recordsByFolder[raw.id],
		}
		folderMap[raw.id] = f
	}

	// Nest children
	var roots []models.SafeFolder
	for _, raw := range raws {
		f := folderMap[raw.id]
		if raw.parentID == nil {
			roots = append(roots, *f)
		} else {
			parent := folderMap[*raw.parentID]
			parent.Children = append(parent.Children, *f)
		}
	}
	return roots, nil
}

// ---- SAFE RECORDS ----

func InsertRecord(r *models.SafeRecord) (int64, error) {
	nameEnc, err := crypto.Encrypt(r.Name)
	if err != nil { return 0, err }
	loginEnc, err := crypto.Encrypt(r.Login)
	if err != nil { return 0, err }
	passEnc, err := crypto.Encrypt(r.Password)
	if err != nil { return 0, err }

	res, err := db.Exec(`INSERT INTO safe_records(folder_id,name_enc,login_enc,pass_enc) VALUES(?,?,?,?)`,
		r.FolderID, nameEnc, loginEnc, passEnc)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}

	for _, item := range r.Items {
		item.RecordID = id
		if _, err := InsertItem(&item); err != nil {
			return 0, err
		}
	}
	return id, nil
}

func UpdateRecord(r *models.SafeRecord) error {
	nameEnc, err := crypto.Encrypt(r.Name)
	if err != nil { return err }
	loginEnc, err := crypto.Encrypt(r.Login)
	if err != nil { return err }
	passEnc, err := crypto.Encrypt(r.Password)
	if err != nil { return err }
	_, err = db.Exec(`UPDATE safe_records SET folder_id=?,name_enc=?,login_enc=?,pass_enc=?,updated_at=strftime('%s','now') WHERE id=?`,
		r.FolderID, nameEnc, loginEnc, passEnc, r.ID)
	if err != nil { return err }

	// Replace all custom items: delete existing, re-insert from request.
	if _, err := db.Exec(`DELETE FROM safe_items WHERE record_id=?`, r.ID); err != nil {
		return err
	}
	for _, item := range r.Items {
		item.RecordID = r.ID
		if _, err := InsertItem(&item); err != nil {
			return err
		}
	}
	return nil
}

func DeleteRecord(id int64) error {
	_, err := db.Exec(`DELETE FROM safe_records WHERE id=?`, id)
	return err
}

// GetRecord fetches a single record by ID with all items.
func GetRecord(id int64) (*models.SafeRecord, error) {
	var r models.SafeRecord
	var ne, le, pe string
	err := db.QueryRow(
		`SELECT id,folder_id,name_enc,login_enc,pass_enc,COALESCE(created_at,0) FROM safe_records WHERE id=?`, id,
	).Scan(&r.ID, &r.FolderID, &ne, &le, &pe, &r.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.Name, _ = crypto.Decrypt(ne)
	r.Login, _ = crypto.Decrypt(le)
	r.Password, _ = crypto.Decrypt(pe)
	items, _ := itemsForRecord(id)
	r.Items = items
	return &r, nil
}

func itemsForRecord(recordID int64) ([]models.SafeItem, error) {
	rows, err := db.Query(`SELECT id,record_id,name_enc,content_enc FROM safe_items WHERE record_id=? ORDER BY id`, recordID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.SafeItem
	for rows.Next() {
		var i models.SafeItem
		var ne, ce string
		rows.Scan(&i.ID, &i.RecordID, &ne, &ce)
		i.Name, _ = crypto.Decrypt(ne)
		i.Content, _ = crypto.Decrypt(ce)
		list = append(list, i)
	}
	return list, rows.Err()
}

// CountRecords returns total number of safe records.
func CountRecords() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM safe_records`).Scan(&n)
	return n
}

// CountTOTP returns total TOTP entries.
func CountTOTP() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM totp_entries`).Scan(&n)
	return n
}

// CountSSH returns total SSH keys.
func CountSSH() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM ssh_keys`).Scan(&n)
	return n
}

// ---- DECOY FOLDERS ----

// SetFolderDecoy marks/unmarks a folder as decoy (shown on duress login).
func SetFolderDecoy(id int64, isDecoy bool) error {
	v := 0
	if isDecoy {
		v = 1
	}
	_, err := db.Exec(`UPDATE safe_folders SET is_decoy=? WHERE id=?`, v, id)
	return err
}

// GetDecoyFolders returns all folders marked as decoy.
func GetDecoyFolders() ([]map[string]interface{}, error) {
	rows, err := db.Query(`SELECT id,name FROM safe_folders WHERE is_decoy=1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		var id int64
		var name string
		rows.Scan(&id, &name)
		list = append(list, map[string]interface{}{"id": id, "name": name})
	}
	return list, rows.Err()
}

// ActiveSessionsCount returns non-revoked sessions.
func ActiveSessionsCount() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM sessions WHERE revoked=0 AND last_seen > ?`, 0).Scan(&n)
	return n
}

// DBPath returns the path to vault.db (for size reporting).
func DBPath() string {
	var p string
	db.QueryRow(`PRAGMA database_list`).Scan(new(int), new(string), &p)
	return p
}

func AllRecords() ([]models.SafeRecord, error) {
	rows, err := db.Query(`SELECT id,folder_id,name_enc,login_enc,pass_enc,COALESCE(created_at,0) FROM safe_records ORDER BY folder_id,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.SafeRecord
	for rows.Next() {
		var r models.SafeRecord
		var ne, le, pe string
		if err := rows.Scan(&r.ID, &r.FolderID, &ne, &le, &pe, &r.CreatedAt); err != nil {
			return nil, err
		}
		r.Name, _ = crypto.Decrypt(ne)
		r.Login, _ = crypto.Decrypt(le)
		r.Password, _ = crypto.Decrypt(pe)
		list = append(list, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Attach items
	items, err := AllItems()
	if err != nil {
		return nil, err
	}
	itemsByRecord := map[int64][]models.SafeItem{}
	for _, i := range items {
		itemsByRecord[i.RecordID] = append(itemsByRecord[i.RecordID], i)
	}
	for idx := range list {
		list[idx].Items = itemsByRecord[list[idx].ID]
	}
	return list, nil
}

// ---- SAFE ITEMS ----

func InsertItem(item *models.SafeItem) (int64, error) {
	nameEnc, err := crypto.Encrypt(item.Name)
	if err != nil { return 0, err }
	contentEnc, err := crypto.Encrypt(item.Content)
	if err != nil { return 0, err }
	res, err := db.Exec(`INSERT INTO safe_items(record_id,name_enc,content_enc) VALUES(?,?,?)`,
		item.RecordID, nameEnc, contentEnc)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func UpdateItem(item *models.SafeItem) error {
	nameEnc, err := crypto.Encrypt(item.Name)
	if err != nil { return err }
	contentEnc, err := crypto.Encrypt(item.Content)
	if err != nil { return err }
	_, err = db.Exec(`UPDATE safe_items SET name_enc=?,content_enc=?,updated_at=strftime('%s','now') WHERE id=?`,
		nameEnc, contentEnc, item.ID)
	return err
}

func DeleteItem(id int64) error {
	_, err := db.Exec(`DELETE FROM safe_items WHERE id=?`, id)
	return err
}

func AllItems() ([]models.SafeItem, error) {
	rows, err := db.Query(`SELECT id,record_id,name_enc,content_enc FROM safe_items ORDER BY record_id,id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.SafeItem
	for rows.Next() {
		var i models.SafeItem
		var ne, ce string
		if err := rows.Scan(&i.ID, &i.RecordID, &ne, &ce); err != nil {
			return nil, err
		}
		i.Name, _ = crypto.Decrypt(ne)
		i.Content, _ = crypto.Decrypt(ce)
		list = append(list, i)
	}
	return list, rows.Err()
}

// ---- BULK IMPORT HELPERS ----

func ClearAll() error {
	_, err := db.Exec(`DELETE FROM safe_folders`)
	return err
}

// FindOrCreateFolder looks up a folder by name (under parentID) or creates it.
func FindOrCreateFolder(name string, parentID *int64) (int64, error) {
	var id int64
	var err error
	if parentID == nil {
		err = db.QueryRow(`SELECT id FROM safe_folders WHERE name=? AND parent_id IS NULL`, name).Scan(&id)
	} else {
		err = db.QueryRow(`SELECT id FROM safe_folders WHERE name=? AND parent_id=?`, name, *parentID).Scan(&id)
	}
	if err == nil {
		return id, nil
	}
	return InsertFolder(name, parentID)
}
