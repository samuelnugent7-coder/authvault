package db

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"

	"authvault/api/internal/models"
)

func MigrateShareLinks() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS share_links (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		token      TEXT    NOT NULL UNIQUE,
		record_id  INTEGER NOT NULL,
		one_time   INTEGER NOT NULL DEFAULT 1,
		expires_at INTEGER NOT NULL,
		used_at    INTEGER NOT NULL DEFAULT 0,
		created_by TEXT    NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	return err
}

// CreateShareLink generates a one-time encrypted share link token.
func CreateShareLink(recordID int64, oneTime bool, ttlSeconds int64, createdBy string) (*models.ShareLink, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return nil, fmt.Errorf("rand: %w", err)
	}
	token := hex.EncodeToString(raw)
	exp := time.Now().Unix() + ttlSeconds
	oneTimeInt := 0
	if oneTime {
		oneTimeInt = 1
	}
	res, err := db.Exec(
		`INSERT INTO share_links(token,record_id,one_time,expires_at,created_by) VALUES(?,?,?,?,?)`,
		token, recordID, oneTimeInt, exp, createdBy,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &models.ShareLink{
		ID:        id,
		Token:     token,
		RecordID:  recordID,
		OneTime:   oneTime,
		ExpiresAt: exp,
		CreatedBy: createdBy,
		CreatedAt: time.Now().Unix(),
	}, nil
}

// ConsumeShareLink validates and optionally marks a share link as used.
func ConsumeShareLink(token string) (*models.ShareLink, error) {
	var sl models.ShareLink
	var oneTimeInt, usedAt int
	err := db.QueryRow(
		`SELECT id,token,record_id,one_time,expires_at,used_at,created_by,created_at
		 FROM share_links WHERE token=?`, token,
	).Scan(&sl.ID, &sl.Token, &sl.RecordID, &oneTimeInt, &sl.ExpiresAt, &usedAt, &sl.CreatedBy, &sl.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sl.OneTime = oneTimeInt == 1
	sl.UsedAt = int64(usedAt)

	if sl.OneTime && sl.UsedAt > 0 {
		return nil, nil // already used
	}
	if time.Now().Unix() > sl.ExpiresAt {
		return nil, nil // expired
	}
	if sl.OneTime {
		db.Exec(`UPDATE share_links SET used_at=? WHERE id=?`, time.Now().Unix(), sl.ID)
	}
	return &sl, nil
}

func ListShareLinks(createdBy string) ([]models.ShareLink, error) {
	rows, err := db.Query(
		`SELECT id,record_id,one_time,expires_at,used_at,created_by,created_at
		 FROM share_links WHERE created_by=? ORDER BY created_at DESC`, createdBy)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.ShareLink
	for rows.Next() {
		var sl models.ShareLink
		var ot, ua int
		rows.Scan(&sl.ID, &sl.RecordID, &ot, &sl.ExpiresAt, &ua, &sl.CreatedBy, &sl.CreatedAt)
		sl.OneTime = ot == 1
		sl.UsedAt = int64(ua)
		list = append(list, sl)
	}
	return list, rows.Err()
}

func DeleteShareLink(id int64, createdBy string) error {
	_, err := db.Exec(`DELETE FROM share_links WHERE id=? AND created_by=?`, id, createdBy)
	return err
}
