package db

import (
	"crypto/sha256"
	"database/sql"
	"fmt"

	"authvault/api/internal/models"
)

// MigrateSessions creates the sessions table.
func MigrateSessions() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS sessions (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		username    TEXT NOT NULL,
		token_hash  TEXT NOT NULL UNIQUE,
		device      TEXT NOT NULL DEFAULT '',
		ip          TEXT NOT NULL DEFAULT '',
		created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		last_seen   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		revoked     INTEGER NOT NULL DEFAULT 0
	)`)
	if err != nil {
		return fmt.Errorf("migrate sessions: %w", err)
	}
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)`)
	if err != nil {
		return err
	}
	// Add fingerprint columns idempotently
	db.Exec(`ALTER TABLE sessions ADD COLUMN fp_hash    TEXT NOT NULL DEFAULT ''`)
	db.Exec(`ALTER TABLE sessions ADD COLUMN fp_flagged INTEGER NOT NULL DEFAULT 0`)
	return nil
}

// hashToken returns a hex SHA-256 hash of a JWT string.
func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return fmt.Sprintf("%x", h)
}

// CreateSession records a new login session. Returns the session ID.
func CreateSession(userID int64, username, token, device, ip, fpHash string) int64 {
	res, err := db.Exec(
		`INSERT INTO sessions(user_id, username, token_hash, device, ip, fp_hash) VALUES(?,?,?,?,?,?)`,
		userID, username, hashToken(token), device, ip, fpHash,
	)
	if err != nil {
		return 0
	}
	id, _ := res.LastInsertId()
	return id
}

// TouchSession updates the last_seen timestamp for a token.
func TouchSession(token string) {
	db.Exec(`UPDATE sessions SET last_seen=strftime('%s','now') WHERE token_hash=?`, hashToken(token))
}

// IsRevoked returns true if the token has been explicitly revoked.
func IsRevoked(token string) bool {
	var revoked int
	err := db.QueryRow(`SELECT revoked FROM sessions WHERE token_hash=?`, hashToken(token)).Scan(&revoked)
	if err == sql.ErrNoRows {
		return false // unknown token = not revoked (backwards compat)
	}
	if err != nil {
		return false
	}
	return revoked == 1
}

// GetSessions lists sessions for a user (or all sessions for admins).
func GetSessions(userID int64, isAdmin bool) ([]models.Session, error) {
	var (
		rows interface {
			Next() bool
			Scan(...any) error
			Close() error
			Err() error
		}
		err error
	)
	if isAdmin {
		rows, err = db.Query(
			`SELECT id,user_id,username,device,ip,created_at,last_seen,revoked,fp_flagged FROM sessions ORDER BY last_seen DESC LIMIT 200`,
		)
	} else {
		rows, err = db.Query(
			`SELECT id,user_id,username,device,ip,created_at,last_seen,revoked,fp_flagged FROM sessions WHERE user_id=? ORDER BY last_seen DESC LIMIT 50`,
			userID,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.Session
	for rows.Next() {
		var s models.Session
		var revoked, fpFlagged int
		rows.Scan(&s.ID, &s.UserID, &s.Username, &s.Device, &s.IP, &s.CreatedAt, &s.LastSeen, &revoked, &fpFlagged)
		s.Revoked    = revoked == 1
		s.FpFlagged  = fpFlagged == 1
		list = append(list, s)
	}
	if list == nil {
		list = []models.Session{}
	}
	return list, rows.Err()
}

// RevokeSession marks a session revoked by ID. Returns whether it was permitted.
func RevokeSession(sessionID, callerUserID int64, isAdmin bool) error {
	// Verify ownership
	var ownerID int64
	err := db.QueryRow(`SELECT user_id FROM sessions WHERE id=?`, sessionID).Scan(&ownerID)
	if err == sql.ErrNoRows {
		return fmt.Errorf("session not found")
	}
	if err != nil {
		return err
	}
	if !isAdmin && ownerID != callerUserID {
		return fmt.Errorf("permission denied")
	}
	_, err = db.Exec(`UPDATE sessions SET revoked=1 WHERE id=?`, sessionID)
	return err
}

// RevokeAllUserSessions revokes all non-revoked sessions for a user (admin action).
func RevokeAllUserSessions(userID int64) error {
	_, err := db.Exec(`UPDATE sessions SET revoked=1 WHERE user_id=?`, userID)
	return err
}

// CleanSessions deletes sessions older than 30 days.
func CleanSessions() {
	db.Exec(`DELETE FROM sessions WHERE created_at < strftime('%s','now') - 2592000`)
}

// GetSessionFingerprint returns the stored fp_hash for a token (empty string if not found).
func GetSessionFingerprint(token string) string {
	var fp string
	db.QueryRow(`SELECT fp_hash FROM sessions WHERE token_hash=?`, hashToken(token)).Scan(&fp)
	return fp
}

// FlagSessionFingerprint marks a session as fingerprint-flagged.
func FlagSessionFingerprint(token string) {
	db.Exec(`UPDATE sessions SET fp_flagged=1 WHERE token_hash=?`, hashToken(token))
}
