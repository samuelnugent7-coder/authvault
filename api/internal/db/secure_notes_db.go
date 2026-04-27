package db

import (
	"database/sql"
	"fmt"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

func MigrateSecureNotes() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS secure_notes (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		title_enc   TEXT    NOT NULL,
		content_enc TEXT    NOT NULL DEFAULT '',
		created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		updated_at  INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	return err
}

func InsertSecureNote(n *models.SecureNote) (int64, error) {
	titleEnc, err := crypto.Encrypt(n.Title)
	if err != nil {
		return 0, err
	}
	contentEnc, err := crypto.Encrypt(n.Content)
	if err != nil {
		return 0, err
	}
	res, err := db.Exec(
		`INSERT INTO secure_notes(title_enc,content_enc,owner_id,owner_username) VALUES(?,?,?,?)`,
		titleEnc, contentEnc, n.OwnerID, n.OwnerUsername,
	)
	if err != nil {
		// Fallback for DBs without owner columns yet (run before migration)
		res, err = db.Exec(
			`INSERT INTO secure_notes(title_enc,content_enc) VALUES(?,?)`,
			titleEnc, contentEnc,
		)
	}
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func UpdateSecureNote(n *models.SecureNote) error {
	titleEnc, err := crypto.Encrypt(n.Title)
	if err != nil {
		return err
	}
	contentEnc, err := crypto.Encrypt(n.Content)
	if err != nil {
		return err
	}
	_, err = db.Exec(
		`UPDATE secure_notes SET title_enc=?,content_enc=?,updated_at=strftime('%s','now') WHERE id=?`,
		titleEnc, contentEnc, n.ID,
	)
	return err
}

func DeleteSecureNote(id int64) error {
	_, err := db.Exec(`DELETE FROM secure_notes WHERE id=?`, id)
	return err
}

func GetSecureNote(id int64) (*models.SecureNote, error) {
	var n models.SecureNote
	var te, ce string
	err := db.QueryRow(`SELECT id,title_enc,content_enc,owner_id,owner_username,created_at,updated_at FROM secure_notes WHERE id=?`, id).
		Scan(&n.ID, &te, &ce, &n.OwnerID, &n.OwnerUsername, &n.CreatedAt, &n.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		// fallback for old schema
		err = db.QueryRow(`SELECT id,title_enc,content_enc,created_at,updated_at FROM secure_notes WHERE id=?`, id).
			Scan(&n.ID, &te, &ce, &n.CreatedAt, &n.UpdatedAt)
		if err != nil {
			return nil, err
		}
	}
	n.Title, _ = crypto.Decrypt(te)
	n.Content, _ = crypto.Decrypt(ce)
	return &n, nil
}

func AllSecureNotes() ([]models.SecureNote, error) {
	rows, err := db.Query(`SELECT id,title_enc,content_enc,COALESCE(owner_id,0),COALESCE(owner_username,''),created_at,updated_at FROM secure_notes ORDER BY updated_at DESC`)
	if err != nil {
		// Fallback if owner columns missing
		rows, err = db.Query(`SELECT id,title_enc,content_enc,0,'',created_at,updated_at FROM secure_notes ORDER BY updated_at DESC`)
		if err != nil {
			return nil, err
		}
	}
	defer rows.Close()
	var list []models.SecureNote
	for rows.Next() {
		var n models.SecureNote
		var te, ce string
		if err := rows.Scan(&n.ID, &te, &ce, &n.OwnerID, &n.OwnerUsername, &n.CreatedAt, &n.UpdatedAt); err != nil {
			return nil, err
		}
		n.Title, _ = crypto.Decrypt(te)
		n.Content, _ = crypto.Decrypt(ce)
		list = append(list, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Attach tags
	for i := range list {
		list[i].Tags, _ = GetNoteTagNames(list[i].ID)
	}
	return list, nil
}

// SecureNotesCount returns total note count (for dashboard).
func SecureNotesCount() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM secure_notes`).Scan(&n)
	return n
}

// GetNoteTagNames returns tag names assigned to a note.
func GetNoteTagNames(noteID int64) ([]string, error) {
	rows, err := db.Query(
		`SELECT t.name FROM tags t
		 JOIN note_tags nt ON nt.tag_id=t.id WHERE nt.note_id=?`, noteID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var s string
		rows.Scan(&s)
		names = append(names, s)
	}
	return names, rows.Err()
}

// AllSecureNotesRaw returns encrypted row data for snapshot engine.
type RawNote struct {
	ID         int64
	TitleEnc   string
	ContentEnc string
	UpdatedAt  int64
}

func AllSecureNotesRaw(since int64) ([]RawNote, error) {
	var q string
	var args []interface{}
	if since > 0 {
		q = `SELECT id,title_enc,content_enc,updated_at FROM secure_notes WHERE updated_at>?`
		args = append(args, since)
	} else {
		q = `SELECT id,title_enc,content_enc,updated_at FROM secure_notes`
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("raw notes: %w", err)
	}
	defer rows.Close()
	var list []RawNote
	for rows.Next() {
		var r RawNote
		rows.Scan(&r.ID, &r.TitleEnc, &r.ContentEnc, &r.UpdatedAt)
		list = append(list, r)
	}
	return list, rows.Err()
}
