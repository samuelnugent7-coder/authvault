package db

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// BackupFile represents a record of a file backed up from a device.
type BackupFile struct {
	ID          int64  `json:"id"`
	DeviceID    string `json:"device_id"`
	FilePath    string `json:"file_path"`  // original path on device
	FileSize    int64  `json:"file_size"`
	Mtime       int64  `json:"mtime"`      // unix timestamp
	SHA256      string `json:"sha256"`
	BackedUpAt  int64  `json:"backed_up_at"`
	StoredName  string `json:"stored_name"` // path under backup dir
}

// CheckRequest is one entry in a bulk check call.
type CheckRequest struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	Mtime  int64  `json:"mtime"`
	SHA256 string `json:"sha256"`
}

func migrateBackup() error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS backup_files (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		device_id    TEXT    NOT NULL,
		file_path    TEXT    NOT NULL,
		file_size    INTEGER NOT NULL DEFAULT 0,
		mtime        INTEGER NOT NULL DEFAULT 0,
		sha256       TEXT    NOT NULL DEFAULT '',
		backed_up_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		stored_name  TEXT    NOT NULL DEFAULT '',
		UNIQUE(device_id, file_path)
	)`)
	if err != nil {
		return err
	}
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS backup_configs (
		device_id TEXT PRIMARY KEY,
		config_json TEXT NOT NULL DEFAULT '{}'
	)`)
	return err
}

// CheckResult is the output of NeedsUpload.
type CheckResult struct {
	NeedsUpload   []string
	NewCount      int // files not previously seen
	ChangedCount  int // files that changed (size/mtime/hash)
	UnchangedCount int // files already backed up and identical on disk
}

// NeedsUpload checks a batch of files and returns the paths that are new or changed.
// Uses a single bulk SELECT instead of N individual queries.
// backupRoot is the directory where stored files live; if a DB record exists but
// the file has been deleted from disk it is treated as missing and re-queued.
func NeedsUpload(deviceID string, files []CheckRequest, backupRoot string) (CheckResult, error) {
	var res CheckResult
	if len(files) == 0 {
		return res, nil
	}

	// Build an in-memory map of what the server already has for this device.
	// One query for all paths in this batch.
	pathSet := make([]interface{}, 0, len(files)+1)
	pathSet = append(pathSet, deviceID)
	placeholders := make([]byte, 0, len(files)*2)
	for i, f := range files {
		if i > 0 {
			placeholders = append(placeholders, ',')
		}
		placeholders = append(placeholders, '?')
		pathSet = append(pathSet, f.Path)
	}

	query := fmt.Sprintf(
		`SELECT file_path, file_size, mtime, sha256, stored_name FROM backup_files WHERE device_id=? AND file_path IN (%s)`,
		string(placeholders),
	)
	rows, err := db.Query(query, pathSet...)
	if err != nil {
		return CheckResult{}, err
	}
	type stored struct {
		size, mtime int64
		sha256      string
		storedName  string
	}
	existing := make(map[string]stored, len(files))
	for rows.Next() {
		var path string
		var s stored
		if err := rows.Scan(&path, &s.size, &s.mtime, &s.sha256, &s.storedName); err != nil {
			rows.Close()
			return CheckResult{}, err
		}
		existing[path] = s
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return CheckResult{}, err
	}

	var needed []string
	for _, f := range files {
		s, found := existing[f.Path]
		if !found {
			needed = append(needed, f.Path)
			res.NewCount++
			continue
		}
		// Re-upload if size, mtime or (when provided) hash changed.
		if s.size != f.Size || s.mtime != f.Mtime || (f.SHA256 != "" && s.sha256 != f.SHA256) {
			needed = append(needed, f.Path)
			res.ChangedCount++
			continue
		}
		// Even if metadata matches, re-upload if the file was deleted from disk.
		if backupRoot != "" && s.storedName != "" {
			diskPath := filepath.Join(backupRoot, s.storedName)
			if _, err := os.Stat(diskPath); os.IsNotExist(err) {
				needed = append(needed, f.Path)
				res.ChangedCount++ // treat missing-on-disk as changed
				continue
			}
		}
		res.UnchangedCount++
	}
	res.NeedsUpload = needed
	return res, nil
}

// RecordUpload upserts a backup_files record after successful storage.
func RecordUpload(deviceID, filePath, storedName, sha256 string, size, mtime int64) error {
	_, err := db.Exec(`
		INSERT INTO backup_files(device_id, file_path, file_size, mtime, sha256, stored_name)
		VALUES(?,?,?,?,?,?)
		ON CONFLICT(device_id, file_path) DO UPDATE SET
			file_size=excluded.file_size,
			mtime=excluded.mtime,
			sha256=excluded.sha256,
			stored_name=excluded.stored_name,
			backed_up_at=strftime('%s','now')
	`, deviceID, filePath, size, mtime, sha256, storedName)
	return err
}

// ListBackupFiles returns all backup records for a device, sorted by path.
func ListBackupFiles(deviceID string) ([]BackupFile, error) {
	rows, err := db.Query(
		`SELECT id,device_id,file_path,file_size,mtime,sha256,backed_up_at,stored_name
		 FROM backup_files WHERE device_id=? ORDER BY file_path`,
		deviceID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []BackupFile
	for rows.Next() {
		var f BackupFile
		if err := rows.Scan(&f.ID, &f.DeviceID, &f.FilePath, &f.FileSize, &f.Mtime, &f.SHA256, &f.BackedUpAt, &f.StoredName); err != nil {
			return nil, err
		}
		list = append(list, f)
	}
	return list, rows.Err()
}

// BackupStats returns total file count and total bytes for a device.
func BackupStats(deviceID string) (count int64, totalBytes int64, lastRun int64, err error) {
	err = db.QueryRow(
		`SELECT COUNT(*), COALESCE(SUM(file_size),0), COALESCE(MAX(backed_up_at),0) FROM backup_files WHERE device_id=?`,
		deviceID,
	).Scan(&count, &totalBytes, &lastRun)
	return
}

// AllDevices returns distinct device IDs that have backed up files.
func AllDevices() ([]string, error) {
	rows, err := db.Query(`SELECT DISTINCT device_id FROM backup_files ORDER BY device_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, nil
}

// EnsureBackupMigration calls the backup table migration.
// Called from the main migrate() function.
func EnsureBackupMigration() error {
	if err := migrateBackup(); err != nil {
		return fmt.Errorf("backup migrate: %w", err)
	}
	return nil
}
// BackupDeviceConfig is the per-device backup configuration.
type BackupDeviceConfig struct {
	IncludePaths     []string `json:"include_paths"`
	ExcludePatterns  []string `json:"exclude_patterns"`
	ScheduleHours    int      `json:"schedule_hours"`   // 0 = manual only
	ScheduleTime     string   `json:"schedule_time"`    // "HH:MM" local time, e.g. "02:00"
	Enabled          bool     `json:"enabled"`
	LastRunAt        int64    `json:"last_run_at"`
	LastUploadCount  int      `json:"last_upload_count"`
	LastNewCount     int      `json:"last_new_count"`
	LastChangedCount int      `json:"last_changed_count"`
	LastSkipCount    int      `json:"last_skip_count"`
	LastErrorCount   int      `json:"last_error_count"`
	LastTotalBytes   int64    `json:"last_total_bytes"`
}

// GetBackupConfig loads the stored config for a device, returning defaults if none.
func GetBackupConfig(deviceID string) (BackupDeviceConfig, error) {
	var cfg BackupDeviceConfig
	var raw string
	err := db.QueryRow(`SELECT config_json FROM backup_configs WHERE device_id=?`, deviceID).Scan(&raw)
	if err != nil {
		// No row yet — return defaults
		cfg.Enabled = true
		cfg.ScheduleHours = 12
		cfg.ScheduleTime = "02:00"
		return cfg, nil
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

// SetBackupConfig persists the config for a device.
func SetBackupConfig(deviceID string, cfg BackupDeviceConfig) error {
	b, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	_, err = db.Exec(`
		INSERT INTO backup_configs(device_id, config_json) VALUES(?,?)
		ON CONFLICT(device_id) DO UPDATE SET config_json=excluded.config_json
	`, deviceID, string(b))
	return err
}

// UpdateBackupRunStats updates the last-run stats inside the stored config.
func UpdateBackupRunStats(deviceID string, uploaded, newCount, changed, skipped, errors int, bytes int64) error {
	cfg, err := GetBackupConfig(deviceID)
	if err != nil {
		return err
	}
	cfg.LastRunAt = time.Now().Unix()
	cfg.LastUploadCount = uploaded
	cfg.LastNewCount = newCount
	cfg.LastChangedCount = changed
	cfg.LastSkipCount = skipped
	cfg.LastErrorCount = errors
	cfg.LastTotalBytes = bytes
	return SetBackupConfig(deviceID, cfg)
}