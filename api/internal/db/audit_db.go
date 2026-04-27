package db

import (
	"fmt"

	"authvault/api/internal/models"
)

// MigrateAudit creates the audit_logs table.
func MigrateAudit() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS audit_logs (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id    INTEGER NOT NULL DEFAULT 0,
		username   TEXT NOT NULL DEFAULT '',
		event      TEXT NOT NULL,
		ip         TEXT NOT NULL DEFAULT '',
		device     TEXT NOT NULL DEFAULT '',
		details    TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	if err != nil {
		return fmt.Errorf("migrate audit: %w", err)
	}
	_, err = db.Exec(`CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_logs(user_id)`)
	return err
}

// LogAudit writes an audit event (fire-and-forget, errors are swallowed).
func LogAudit(userID int64, username, event, ip, device, details string) {
	db.Exec(
		`INSERT INTO audit_logs(user_id,username,event,ip,device,details) VALUES(?,?,?,?,?,?)`,
		userID, username, event, ip, device, details,
	)
}

// QueryRowForAudit counts how many prior logins from a given IP exist for the user.
func QueryRowForAudit(userID int64, ip string, dest *int) {
	db.QueryRow(
		`SELECT COUNT(*) FROM audit_logs WHERE user_id=? AND ip=? AND event='login'`,
		userID, ip,
	).Scan(dest)
}
func GetAuditLogs(userID int64, isAdmin bool, limit int) ([]models.AuditLog, error) {
	var rows interface{ Next() bool; Scan(...any) error; Close() error; Err() error }
	var err error
	if isAdmin {
		rows, err = db.Query(
			`SELECT id,user_id,username,event,ip,device,details,created_at FROM audit_logs ORDER BY id DESC LIMIT ?`,
			limit,
		)
	} else {
		rows, err = db.Query(
			`SELECT id,user_id,username,event,ip,device,details,created_at FROM audit_logs WHERE user_id=? ORDER BY id DESC LIMIT ?`,
			userID, limit,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.AuditLog
	for rows.Next() {
		var a models.AuditLog
		rows.Scan(&a.ID, &a.UserID, &a.Username, &a.Event, &a.IP, &a.Device, &a.Details, &a.CreatedAt)
		list = append(list, a)
	}
	if list == nil {
		list = []models.AuditLog{}
	}
	return list, rows.Err()
}
