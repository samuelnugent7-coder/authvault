package db

import (
	"database/sql"
	"fmt"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

// MigrateSSH creates the ssh_keys table.
func MigrateSSH() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS ssh_keys (
		id               INTEGER PRIMARY KEY AUTOINCREMENT,
		name             TEXT NOT NULL,
		public_key_enc   TEXT NOT NULL DEFAULT '',
		private_key_enc  TEXT NOT NULL,
		comment_enc      TEXT NOT NULL DEFAULT '',
		created_at       INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	if err != nil {
		return fmt.Errorf("migrate ssh: %w", err)
	}
	return nil
}

func InsertSSHKey(k *models.SSHKey) (int64, error) {
	pubEnc, err := crypto.Encrypt(k.PublicKey)
	if err != nil {
		return 0, err
	}
	privEnc, err := crypto.Encrypt(k.PrivateKey)
	if err != nil {
		return 0, err
	}
	commentEnc, err := crypto.Encrypt(k.Comment)
	if err != nil {
		return 0, err
	}
	res, err := db.Exec(
		`INSERT INTO ssh_keys(name,public_key_enc,private_key_enc,comment_enc) VALUES(?,?,?,?)`,
		k.Name, pubEnc, privEnc, commentEnc,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func AllSSHKeys() ([]models.SSHKey, error) {
	rows, err := db.Query(`SELECT id,name,public_key_enc,private_key_enc,comment_enc,created_at FROM ssh_keys ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.SSHKey
	for rows.Next() {
		var k models.SSHKey
		var pubEnc, privEnc, commentEnc string
		if err := rows.Scan(&k.ID, &k.Name, &pubEnc, &privEnc, &commentEnc, &k.CreatedAt); err != nil {
			return nil, err
		}
		k.PublicKey, _ = crypto.Decrypt(pubEnc)
		k.PrivateKey, _ = crypto.Decrypt(privEnc)
		k.Comment, _ = crypto.Decrypt(commentEnc)
		list = append(list, k)
	}
	if list == nil {
		list = []models.SSHKey{}
	}
	return list, rows.Err()
}

func GetSSHKey(id int64) (*models.SSHKey, error) {
	var k models.SSHKey
	var pubEnc, privEnc, commentEnc string
	err := db.QueryRow(`SELECT id,name,public_key_enc,private_key_enc,comment_enc,created_at FROM ssh_keys WHERE id=?`, id).
		Scan(&k.ID, &k.Name, &pubEnc, &privEnc, &commentEnc, &k.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	k.PublicKey, _ = crypto.Decrypt(pubEnc)
	k.PrivateKey, _ = crypto.Decrypt(privEnc)
	k.Comment, _ = crypto.Decrypt(commentEnc)
	return &k, nil
}

func UpdateSSHKey(k *models.SSHKey) error {
	pubEnc, err := crypto.Encrypt(k.PublicKey)
	if err != nil {
		return err
	}
	privEnc, err := crypto.Encrypt(k.PrivateKey)
	if err != nil {
		return err
	}
	commentEnc, err := crypto.Encrypt(k.Comment)
	if err != nil {
		return err
	}
	_, err = db.Exec(
		`UPDATE ssh_keys SET name=?,public_key_enc=?,private_key_enc=?,comment_enc=?,updated_at=strftime('%s','now') WHERE id=?`,
		k.Name, pubEnc, privEnc, commentEnc, k.ID,
	)
	return err
}

func DeleteSSHKey(id int64) error {
	_, err := db.Exec(`DELETE FROM ssh_keys WHERE id=?`, id)
	return err
}
