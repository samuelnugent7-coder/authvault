package db

import (
	"database/sql"
	"fmt"

	"authvault/api/internal/crypto"
	"authvault/api/internal/models"
)

// MigrateUsers ensures the users and user_permissions tables exist.
func MigrateUsers() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
			password_hash TEXT NOT NULL,
			argon_salt    TEXT NOT NULL,
			is_admin      INTEGER NOT NULL DEFAULT 0,
			created_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
		)`,
		`CREATE TABLE IF NOT EXISTS user_permissions (
			user_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			resource TEXT NOT NULL,
			action   TEXT NOT NULL,
			allowed  INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (user_id, resource, action)
		)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			return fmt.Errorf("migrate users: %w", err)
		}
	}
	return nil
}

// CreateAdminFromLegacy seeds the admin user from the old config password hash.
// Call this on startup when users table is empty but legacy cfg has a hash.
func CreateAdminFromLegacy(legacySalt, legacyHash string) error {
	count := 0
	db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count)
	if count > 0 {
		return nil // already migrated
	}
	_, err := db.Exec(
		`INSERT INTO users(username, password_hash, argon_salt, is_admin) VALUES(?,?,?,1)`,
		"admin", legacyHash, legacySalt,
	)
	return err
}

// GetUserByUsername looks up a user by their username (case-insensitive).
func GetUserByUsername(username string) (*models.User, error) {
	u := &models.User{}
	err := db.QueryRow(
		`SELECT id,username,password_hash,argon_salt,is_admin,created_at,COALESCE(expires_at,0) FROM users WHERE username=? COLLATE NOCASE`,
		username,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.ArgonSalt, &u.IsAdmin, &u.CreatedAt, &u.ExpiresAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

// GetUserByID returns a user by primary key.
func GetUserByID(id int64) (*models.User, error) {
	u := &models.User{}
	err := db.QueryRow(
		`SELECT id,username,password_hash,argon_salt,is_admin,created_at,COALESCE(expires_at,0) FROM users WHERE id=?`, id,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.ArgonSalt, &u.IsAdmin, &u.CreatedAt, &u.ExpiresAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

// ListUsers returns all users.
func ListUsers() ([]models.User, error) {
	rows, err := db.Query(`SELECT id,username,is_admin,created_at,COALESCE(expires_at,0) FROM users ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.User
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.Username, &u.IsAdmin, &u.CreatedAt, &u.ExpiresAt); err != nil {
			return nil, err
		}
		list = append(list, u)
	}
	return list, rows.Err()
}

// SetUserExpiry sets or clears an account expiry timestamp.
func SetUserExpiry(userID int64, expiresAt int64) error {
	_, err := db.Exec(`UPDATE users SET expires_at=? WHERE id=?`, expiresAt, userID)
	return err
}

// CreateUser creates a new user with a hashed password.
func CreateUser(username, password string, isAdmin bool) (*models.User, error) {
	salt, hash, err := crypto.HashPassword(password)
	if err != nil {
		return nil, err
	}
	admin := 0
	if isAdmin {
		admin = 1
	}
	res, err := db.Exec(
		`INSERT INTO users(username, password_hash, argon_salt, is_admin) VALUES(?,?,?,?)`,
		username, hash, salt, admin,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return GetUserByID(id)
}

// UpdateUser changes a user's password and/or admin flag.
// Pass empty password to leave it unchanged.
func UpdateUser(id int64, password string, isAdmin bool) error {
	admin := 0
	if isAdmin {
		admin = 1
	}
	if password != "" {
		salt, hash, err := crypto.HashPassword(password)
		if err != nil {
			return err
		}
		_, err = db.Exec(
			`UPDATE users SET password_hash=?, argon_salt=?, is_admin=? WHERE id=?`,
			hash, salt, admin, id,
		)
		return err
	}
	_, err := db.Exec(`UPDATE users SET is_admin=? WHERE id=?`, admin, id)
	return err
}

// DeleteUser removes a user (cascades permissions).
func DeleteUser(id int64) error {
	_, err := db.Exec(`DELETE FROM users WHERE id=?`, id)
	return err
}

// GetPermissions returns the full permission set for a user.
// Admin users implicitly have all permissions regardless of DB rows.
func GetPermissions(userID int64, isAdmin bool) models.UserPermissions {
	if isAdmin {
		full := models.ResourcePerms{Read: true, Write: true, Delete: true, Export: true, Import: true}
		return models.UserPermissions{
			Totp:   full,
			Safe:   full,
			Backup: full,
			SSH:    full,
		}
	}
	// Build map from DB rows
	type key struct{ resource, action string }
	allowed := map[key]bool{}
	rows, err := db.Query(
		`SELECT resource, action, allowed FROM user_permissions WHERE user_id=?`, userID,
	)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var res, act string
			var ok int
			if rows.Scan(&res, &act, &ok) == nil {
				allowed[key{res, act}] = ok == 1
			}
		}
	}
	get := func(res, act string) bool {
		v, exists := allowed[key{res, act}]
		if !exists {
			return true // no explicit rule → default allow
		}
		return v
	}
	rp := func(res string) models.ResourcePerms {
		return models.ResourcePerms{
			Read:   get(res, "read"),
			Write:  get(res, "write"),
			Delete: get(res, "delete"),
			Export: get(res, "export"),
			Import: get(res, "import"),
		}
	}

	// Collect granular folder and totp perms from any keys matching
	// "safe:folder:<id>" and "totp:<id>"
	folderPerms := map[string]models.ResourcePerms{}
	totpPerms := map[string]models.ResourcePerms{}
	seen := map[string]bool{}
	for k := range allowed {
		res := k.resource
		if seen[res] {
			continue
		}
		seen[res] = true
		if len(res) > 12 && res[:12] == "safe:folder:" {
			fid := res[12:]
			folderPerms[fid] = rp(res)
		} else if len(res) > 5 && res[:5] == "totp:" {
			tid := res[5:]
			if tid != "" {
				totpPerms[tid] = rp(res)
			}
		}
	}

	p := models.UserPermissions{
		Totp:   rp("totp"),
		Safe:   rp("safe"),
		Backup: rp("backup"),
		SSH:    rp("ssh"),
	}
	if len(folderPerms) > 0 {
		p.FolderPerms = folderPerms
	}
	if len(totpPerms) > 0 {
		p.TotpPerms = totpPerms
	}
	return p
}

// SetPermissions replaces all permissions for a user with the given set.
func SetPermissions(userID int64, perms models.UserPermissions) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint
	if _, err := tx.Exec(`DELETE FROM user_permissions WHERE user_id=?`, userID); err != nil {
		return err
	}
	type row struct{ res, act string; ok bool }
	rows := []row{
		{"totp", "read", perms.Totp.Read},
		{"totp", "write", perms.Totp.Write},
		{"totp", "delete", perms.Totp.Delete},
		{"totp", "export", perms.Totp.Export},
		{"totp", "import", perms.Totp.Import},
		{"safe", "read", perms.Safe.Read},
		{"safe", "write", perms.Safe.Write},
		{"safe", "delete", perms.Safe.Delete},
		{"safe", "export", perms.Safe.Export},
		{"safe", "import", perms.Safe.Import},
		{"backup", "read", perms.Backup.Read},
		{"backup", "write", perms.Backup.Write},
		{"backup", "delete", perms.Backup.Delete},
		{"backup", "export", perms.Backup.Export},
		{"backup", "import", perms.Backup.Import},
		{"ssh", "read", perms.SSH.Read},
		{"ssh", "write", perms.SSH.Write},
		{"ssh", "delete", perms.SSH.Delete},
		{"ssh", "export", perms.SSH.Export},
		{"ssh", "import", perms.SSH.Import},
	}
	// Granular folder perms
	for fid, fp := range perms.FolderPerms {
		res := "safe:folder:" + fid
		rows = append(rows,
			row{res, "read", fp.Read},
			row{res, "write", fp.Write},
			row{res, "delete", fp.Delete},
		)
	}
	// Granular totp perms
	for tid, tp := range perms.TotpPerms {
		res := "totp:" + tid
		rows = append(rows,
			row{res, "read", tp.Read},
			row{res, "write", tp.Write},
			row{res, "delete", tp.Delete},
		)
	}
	for _, r := range rows {
		// Only store explicit denials. Allowed=true is the default (no row = allow),
		// so writing allowed=1 rows is redundant and bloats the table.
		if r.ok {
			continue
		}
		if _, err := tx.Exec(
			`INSERT OR REPLACE INTO user_permissions(user_id,resource,action,allowed) VALUES(?,?,?,?)`,
			userID, r.res, r.act, 0,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// HasPermission checks whether a user has a specific resource+action.
// Admin users always return true.
// Non-admin users default to ALLOW unless an explicit allowed=0 row exists.
func HasPermission(userID int64, isAdmin bool, resource, action string) bool {
	if isAdmin {
		return true
	}
	// If no row exists at all, default to allow (inherit no restriction).
	// Only deny when an explicit allowed=0 row is present.
	var exists, allowed int
	db.QueryRow(
		`SELECT COUNT(*), IFNULL(MAX(allowed),1) FROM user_permissions WHERE user_id=? AND resource=? AND action=?`,
		userID, resource, action,
	).Scan(&exists, &allowed)
	if exists == 0 {
		return true // no explicit rule → allow
	}
	return allowed == 1
}

// IsExplicitlyDenied returns true only when an explicit allowed=0 row exists for
// the given resource+action. Returns false when no row found (inherit parent).
func IsExplicitlyDenied(userID int64, resource, action string) bool {
	var exists, allowed int
	db.QueryRow(
		`SELECT COUNT(*), IFNULL(MAX(allowed),1) FROM user_permissions WHERE user_id=? AND resource=? AND action=?`,
		userID, resource, action,
	).Scan(&exists, &allowed)
	return exists > 0 && allowed == 0
}

