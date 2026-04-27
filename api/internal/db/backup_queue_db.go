package db

import (
	"database/sql"
	"time"
)

// MigrateBackupQueue creates the S3 backup retry queue table and last-success tracker.
func MigrateBackupQueue() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS backup_queue (
		id            INTEGER PRIMARY KEY AUTOINCREMENT,
		task_type     TEXT NOT NULL DEFAULT 's3_backup',
		payload       TEXT NOT NULL DEFAULT '',
		attempt_count INTEGER NOT NULL DEFAULT 0,
		next_retry_at INTEGER NOT NULL DEFAULT 0,
		last_error    TEXT NOT NULL DEFAULT '',
		created_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
	)`)
	if err != nil {
		return err
	}
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS backup_state (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL DEFAULT ''
	)`)
	return err
}

// EnqueueBackup adds a failed backup task to the retry queue.
func EnqueueBackup(taskType, payload string) int64 {
	res, _ := db.Exec(
		`INSERT INTO backup_queue(task_type,payload,next_retry_at) VALUES(?,?,?)`,
		taskType, payload, time.Now().Unix(),
	)
	id, _ := res.LastInsertId()
	return id
}

// QueuedTask represents a pending retry task.
type QueuedTask struct {
	ID           int64
	TaskType     string
	Payload      string
	AttemptCount int
	NextRetryAt  int64
	LastError    string
}

// PeekReadyTasks returns tasks whose next_retry_at <= now, up to limit.
func PeekReadyTasks(limit int) ([]QueuedTask, error) {
	rows, err := db.Query(
		`SELECT id,task_type,payload,attempt_count,next_retry_at,last_error FROM backup_queue WHERE next_retry_at <= ? ORDER BY next_retry_at ASC LIMIT ?`,
		time.Now().Unix(), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []QueuedTask
	for rows.Next() {
		var t QueuedTask
		rows.Scan(&t.ID, &t.TaskType, &t.Payload, &t.AttemptCount, &t.NextRetryAt, &t.LastError)
		list = append(list, t)
	}
	return list, rows.Err()
}

// backoffSeconds returns exponential backoff delay for the given attempt count.
// Sequence: 10s, 30s, 2m, 10m, 30m, 1h, 2h, 4h, 8h, 24h (cap)
var backoffTable = []int64{10, 30, 120, 600, 1800, 3600, 7200, 14400, 28800, 86400}

func BackoffSeconds(attempt int) int64 {
	if attempt < 0 {
		attempt = 0
	}
	if attempt >= len(backoffTable) {
		return backoffTable[len(backoffTable)-1]
	}
	return backoffTable[attempt]
}

// UpdateQueuedTask updates attempt count, next retry time, and last error.
func UpdateQueuedTask(id int64, nextRetryAt int64, lastError string, attempt int) {
	db.Exec(
		`UPDATE backup_queue SET attempt_count=?,next_retry_at=?,last_error=? WHERE id=?`,
		attempt, nextRetryAt, lastError, id,
	)
}

// DeleteQueuedTask removes a successfully processed task.
func DeleteQueuedTask(id int64) {
	db.Exec(`DELETE FROM backup_queue WHERE id=?`, id)
}

// GetQueueDepth returns the number of tasks in the retry queue.
func GetQueueDepth() int {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM backup_queue`).Scan(&n)
	return n
}

// GetMaxAttemptCount returns the highest attempt_count in the queue (proxy for total failures).
func GetMaxAttemptCount() int {
	var n int
	db.QueryRow(`SELECT COALESCE(MAX(attempt_count),0) FROM backup_queue`).Scan(&n)
	return n
}

// GetNextRetryAt returns the earliest next_retry_at in the queue (0 if empty).
func GetNextRetryAt() int64 {
	var n sql.NullInt64
	db.QueryRow(`SELECT MIN(next_retry_at) FROM backup_queue`).Scan(&n)
	if n.Valid {
		return n.Int64
	}
	return 0
}

// GetLastQueueError returns the last_error from the most recently updated queue entry.
func GetLastQueueError() string {
	var s string
	db.QueryRow(`SELECT last_error FROM backup_queue ORDER BY attempt_count DESC LIMIT 1`).Scan(&s)
	return s
}

// SetBackupState stores a key/value backup state entry (e.g. "last_success").
func SetBackupState(key, value string) {
	db.Exec(`INSERT INTO backup_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, value)
}

// GetBackupState retrieves a backup state value by key.
func GetBackupState(key string) string {
	var v string
	db.QueryRow(`SELECT value FROM backup_state WHERE key=?`, key).Scan(&v)
	return v
}
