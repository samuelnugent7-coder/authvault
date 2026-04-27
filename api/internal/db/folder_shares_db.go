package db

import (
	"authvault/api/internal/models"
)

func MigrateFolderShares() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS folder_shares (
		folder_id  INTEGER NOT NULL REFERENCES safe_folders(id) ON DELETE CASCADE,
		user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		can_write  INTEGER NOT NULL DEFAULT 0,
		granted_by TEXT    NOT NULL DEFAULT '',
		granted_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		PRIMARY KEY (folder_id, user_id)
	)`)
	return err
}

func AddFolderShare(folderID, userID int64, canWrite bool, grantedBy string) error {
	_, err := db.Exec(
		`INSERT OR REPLACE INTO folder_shares(folder_id,user_id,can_write,granted_by) VALUES(?,?,?,?)`,
		folderID, userID, canWrite, grantedBy,
	)
	return err
}

func RemoveFolderShare(folderID, userID int64) error {
	_, err := db.Exec(`DELETE FROM folder_shares WHERE folder_id=? AND user_id=?`, folderID, userID)
	return err
}

func GetFolderShares(folderID int64) ([]models.FolderShare, error) {
	rows, err := db.Query(
		`SELECT fs.folder_id,fs.user_id,u.username,fs.can_write,fs.granted_by,fs.granted_at
		 FROM folder_shares fs JOIN users u ON u.id=fs.user_id WHERE fs.folder_id=?`, folderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.FolderShare
	for rows.Next() {
		var s models.FolderShare
		var cw int
		rows.Scan(&s.FolderID, &s.UserID, &s.Username, &cw, &s.GrantedBy, &s.GrantedAt)
		s.CanWrite = cw == 1
		list = append(list, s)
	}
	return list, rows.Err()
}

// IsSharedWithUser returns whether folder is shared with user and write access.
func IsSharedWithUser(folderID, userID int64) (shared bool, canWrite bool) {
	var cw int
	err := db.QueryRow(`SELECT can_write FROM folder_shares WHERE folder_id=? AND user_id=?`, folderID, userID).Scan(&cw)
	if err != nil {
		return false, false
	}
	return true, cw == 1
}

// SharedFoldersCount returns number of shared folder relationships.
func SharedFoldersCount() int {
	var n int
	db.QueryRow(`SELECT COUNT(DISTINCT folder_id) FROM folder_shares`).Scan(&n)
	return n
}
