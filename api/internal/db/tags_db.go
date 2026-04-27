package db

import (
	"database/sql"

	"authvault/api/internal/models"
)

func MigrateTags() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS tags (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			name       TEXT    NOT NULL UNIQUE COLLATE NOCASE,
			color      TEXT    NOT NULL DEFAULT '#607d8b',
			created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
		)`,
		`CREATE TABLE IF NOT EXISTS record_tags (
			record_id INTEGER NOT NULL REFERENCES safe_records(id) ON DELETE CASCADE,
			tag_id    INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
			PRIMARY KEY (record_id, tag_id)
		)`,
		`CREATE TABLE IF NOT EXISTS note_tags (
			note_id INTEGER NOT NULL REFERENCES secure_notes(id) ON DELETE CASCADE,
			tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
			PRIMARY KEY (note_id, tag_id)
		)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			return err
		}
	}
	return nil
}

func AllTags() ([]models.Tag, error) {
	rows, err := db.Query(`SELECT id,name,color,created_at FROM tags ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []models.Tag
	for rows.Next() {
		var t models.Tag
		rows.Scan(&t.ID, &t.Name, &t.Color, &t.CreatedAt)
		list = append(list, t)
	}
	return list, rows.Err()
}

func CreateTag(name, color string) (int64, error) {
	res, err := db.Exec(`INSERT INTO tags(name,color) VALUES(?,?)`, name, color)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func UpdateTag(id int64, name, color string) error {
	_, err := db.Exec(`UPDATE tags SET name=?,color=? WHERE id=?`, name, color, id)
	return err
}

func DeleteTag(id int64) error {
	_, err := db.Exec(`DELETE FROM tags WHERE id=?`, id)
	return err
}

func GetTag(id int64) (*models.Tag, error) {
	var t models.Tag
	err := db.QueryRow(`SELECT id,name,color,created_at FROM tags WHERE id=?`, id).
		Scan(&t.ID, &t.Name, &t.Color, &t.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &t, err
}

// SetRecordTags replaces the tag set for a record.
func SetRecordTags(recordID int64, tagIDs []int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM record_tags WHERE record_id=?`, recordID); err != nil {
		return err
	}
	for _, tid := range tagIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO record_tags(record_id,tag_id) VALUES(?,?)`, recordID, tid); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SetNoteTags replaces the tag set for a note.
func SetNoteTags(noteID int64, tagIDs []int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM note_tags WHERE note_id=?`, noteID); err != nil {
		return err
	}
	for _, tid := range tagIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO note_tags(note_id,tag_id) VALUES(?,?)`, noteID, tid); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// GetRecordTagIDs returns the tag IDs for a record.
func GetRecordTagIDs(recordID int64) []int64 {
	rows, _ := db.Query(`SELECT tag_id FROM record_tags WHERE record_id=?`, recordID)
	if rows == nil {
		return nil
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		rows.Scan(&id)
		ids = append(ids, id)
	}
	return ids
}

// GetRecordsByTag returns record IDs that have a given tag.
func GetRecordsByTag(tagID int64) []int64 {
	rows, _ := db.Query(`SELECT record_id FROM record_tags WHERE tag_id=?`, tagID)
	if rows == nil {
		return nil
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		rows.Scan(&id)
		ids = append(ids, id)
	}
	return ids
}

// TagsCount returns total number of tags.
func TagsCount() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM tags`).Scan(&n)
	return n
}
