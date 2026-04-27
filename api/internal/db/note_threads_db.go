package db

import (
	"database/sql"
	"time"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

// MigrateNoteThreads creates note_messages and note_permissions tables,
// and adds owner_id / owner_username columns to secure_notes if they don't exist.
func MigrateNoteThreads() error {
	stmts := []string{
		// Thread messages — each is an encrypted post in the note
		`CREATE TABLE IF NOT EXISTS note_messages (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			note_id         INTEGER NOT NULL REFERENCES secure_notes(id) ON DELETE CASCADE,
			author_id       INTEGER NOT NULL DEFAULT 0,
			author_username TEXT    NOT NULL DEFAULT '',
			content_enc     TEXT    NOT NULL,
			created_at      INTEGER NOT NULL DEFAULT (strftime('%s','now')),
			edited_at       INTEGER NOT NULL DEFAULT 0
		)`,
		// Per-note access grants (owner controls who can view / edit)
		`CREATE TABLE IF NOT EXISTS note_permissions (
			note_id    INTEGER NOT NULL REFERENCES secure_notes(id) ON DELETE CASCADE,
			user_id    INTEGER NOT NULL,
			username   TEXT    NOT NULL DEFAULT '',
			role       TEXT    NOT NULL DEFAULT 'viewer', -- 'viewer' | 'editor'
			granted_by TEXT    NOT NULL DEFAULT '',
			granted_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
			PRIMARY KEY (note_id, user_id)
		)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			return err
		}
	}
	// Add owner columns to secure_notes (safe to run on existing DBs)
	db.Exec(`ALTER TABLE secure_notes ADD COLUMN owner_id       INTEGER NOT NULL DEFAULT 0`)
	db.Exec(`ALTER TABLE secure_notes ADD COLUMN owner_username TEXT    NOT NULL DEFAULT ''`)
	return nil
}

// ── Note messages ────────────────────────────────────────────────────────────

// PostNoteMessage appends an encrypted message to a note thread.
func PostNoteMessage(noteID, authorID int64, authorUsername, content string) (*models.NoteMessage, error) {
	enc, err := crypto.Encrypt(content)
	if err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	res, err := db.Exec(
		`INSERT INTO note_messages(note_id,author_id,author_username,content_enc,created_at)
		 VALUES(?,?,?,?,?)`,
		noteID, authorID, authorUsername, enc, now,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &models.NoteMessage{
		ID:             id,
		NoteID:         noteID,
		AuthorID:       authorID,
		AuthorUsername: authorUsername,
		Content:        content,
		CreatedAt:      now,
	}, nil
}

// EditNoteMessage updates the content of a message (author-only).
func EditNoteMessage(msgID, authorID int64, newContent string) error {
	enc, err := crypto.Encrypt(newContent)
	if err != nil {
		return err
	}
	_, err = db.Exec(
		`UPDATE note_messages SET content_enc=?, edited_at=? WHERE id=? AND author_id=?`,
		enc, time.Now().Unix(), msgID, authorID,
	)
	return err
}

// DeleteNoteMessage removes a message (author or note owner can delete).
func DeleteNoteMessage(msgID int64) error {
	_, err := db.Exec(`DELETE FROM note_messages WHERE id=?`, msgID)
	return err
}

// GetNoteMessages returns all messages for a note in chronological order.
func GetNoteMessages(noteID int64) ([]models.NoteMessage, error) {
	rows, err := db.Query(
		`SELECT id,note_id,author_id,author_username,content_enc,created_at,edited_at
		 FROM note_messages WHERE note_id=? ORDER BY created_at ASC`, noteID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.NoteMessage
	for rows.Next() {
		var m models.NoteMessage
		var enc string
		if err := rows.Scan(&m.ID, &m.NoteID, &m.AuthorID, &m.AuthorUsername, &enc, &m.CreatedAt, &m.EditedAt); err != nil {
			return nil, err
		}
		m.Content, _ = crypto.Decrypt(enc)
		list = append(list, m)
	}
	return list, rows.Err()
}

// ── Note permissions ─────────────────────────────────────────────────────────

// SetNotePermissions replaces all permission grants for a note.
// The owner always has implicit full access and is NOT stored here.
func SetNotePermissions(noteID int64, perms []models.NotePermission, grantedBy string) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM note_permissions WHERE note_id=?`, noteID); err != nil {
		return err
	}
	now := time.Now().Unix()
	for _, p := range perms {
		if p.Role != "viewer" && p.Role != "editor" {
			p.Role = "viewer"
		}
		if _, err := tx.Exec(
			`INSERT OR REPLACE INTO note_permissions(note_id,user_id,username,role,granted_by,granted_at)
			 VALUES(?,?,?,?,?,?)`,
			noteID, p.UserID, p.Username, p.Role, grantedBy, now,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// GetNotePermissions returns all explicit grants for a note.
func GetNotePermissions(noteID int64) ([]models.NotePermission, error) {
	rows, err := db.Query(
		`SELECT note_id,user_id,username,role,granted_by,granted_at
		 FROM note_permissions WHERE note_id=? ORDER BY granted_at DESC`, noteID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.NotePermission
	for rows.Next() {
		var p models.NotePermission
		rows.Scan(&p.NoteID, &p.UserID, &p.Username, &p.Role, &p.GrantedBy, &p.GrantedAt)
		list = append(list, p)
	}
	return list, rows.Err()
}

// GetNotePermissionForUser returns the role of a specific user on a note,
// or "" if they have no explicit grant.
func GetNotePermissionForUser(noteID, userID int64) string {
	var role string
	err := db.QueryRow(
		`SELECT role FROM note_permissions WHERE note_id=? AND user_id=?`, noteID, userID,
	).Scan(&role)
	if err == sql.ErrNoRows {
		return ""
	}
	return role
}

// CanViewNote returns true if userID is the owner or has a viewer/editor grant.
func CanViewNote(noteID, ownerID, userID int64, isAdmin bool) bool {
	if isAdmin || userID == ownerID {
		return true
	}
	role := GetNotePermissionForUser(noteID, userID)
	return role == "viewer" || role == "editor"
}

// CanEditNote returns true if userID is the owner, has an editor grant, or is admin.
func CanEditNote(noteID, ownerID, userID int64, isAdmin bool) bool {
	if isAdmin || userID == ownerID {
		return true
	}
	return GetNotePermissionForUser(noteID, userID) == "editor"
}

// GetNoteOwner returns the owner_id of a note.
func GetNoteOwner(noteID int64) (ownerID int64, ownerUsername string) {
	db.QueryRow(`SELECT owner_id, owner_username FROM secure_notes WHERE id=?`, noteID).
		Scan(&ownerID, &ownerUsername)
	return
}
