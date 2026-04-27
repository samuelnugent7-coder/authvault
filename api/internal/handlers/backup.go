package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"authvault/api/internal/config"
	dbpkg "authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

const maxUploadSize = 512 << 20 // 512 MB per file

// POST /api/v1/backup/check
// Body: {"device_id":"...","files":[{"path":"...","size":0,"mtime":0,"sha256":"..."}]}
// Returns: {"needs_upload":["path1","path2",...]}
func BackupCheck(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "backup", "write") {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		DeviceID string                `json:"device_id"`
		Files    []dbpkg.CheckRequest  `json:"files"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceID == "" {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}

	cfg := config.Get()
	backupRoot := filepath.Join(cfg.DataDir, "backups", sanitiseDeviceID(req.DeviceID))
	res, err := dbpkg.NeedsUpload(req.DeviceID, req.Files, backupRoot)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if res.NeedsUpload == nil {
		res.NeedsUpload = []string{}
	}
	log.Printf("[backup] check device=%s files=%d new=%d changed=%d unchanged=%d",
		sanitiseDeviceID(req.DeviceID), len(req.Files),
		res.NewCount, res.ChangedCount, res.UnchangedCount)
	jsonOK(w, map[string]interface{}{
		"needs_upload":    res.NeedsUpload,
		"count":           len(res.NeedsUpload),
		"new_count":       res.NewCount,
		"changed_count":   res.ChangedCount,
		"unchanged_count": res.UnchangedCount,
	})
}

// POST /api/v1/backup/upload
// Multipart form: device_id, file_path, mtime (unix), sha256 (optional), file (binary)
func BackupUpload(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "backup", "write") {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		jsonError(w, "parse error: "+err.Error(), http.StatusBadRequest)
		return
	}

	deviceID := r.FormValue("device_id")
	filePath := r.FormValue("file_path")  // original path on device
	mtimeStr := r.FormValue("mtime")
	clientSHA := r.FormValue("sha256")

	if deviceID == "" || filePath == "" {
		jsonError(w, "device_id and file_path required", http.StatusBadRequest)
		return
	}

	mtime, _ := strconv.ParseInt(mtimeStr, 10, 64)
	if mtime == 0 {
		mtime = time.Now().Unix()
	}

	file, _, err := r.FormFile("file")
	if err != nil {
		jsonError(w, "no file in request: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Store: backupDir/<deviceID>/<sanitised relative path>
	cfg := config.Get()
	backupRoot := filepath.Join(cfg.DataDir, "backups", sanitiseDeviceID(deviceID))
	relPath := sanitisePath(filePath)
	destPath := filepath.Join(backupRoot, relPath)

	if err := os.MkdirAll(filepath.Dir(destPath), 0700); err != nil {
		jsonError(w, "mkdir: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Write to temp file first, then rename (atomic)
	tmp, err := os.CreateTemp(filepath.Dir(destPath), ".tmp_")
	if err != nil {
		jsonError(w, "tmp file: "+err.Error(), http.StatusInternalServerError)
		return
	}
	tmpName := tmp.Name()
	// removeTmp cleans up the temp file; called on every error path.
	// On the success path we rename instead, so we must NOT defer-remove blindly.
	removeTmp := func() { os.Remove(tmpName) }

	hasher := sha256.New()
	tee := io.TeeReader(file, hasher)
	written, err := io.Copy(tmp, tee)
	tmp.Close()
	if err != nil {
		removeTmp()
		jsonError(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}

	actualSHA := hex.EncodeToString(hasher.Sum(nil))
	if clientSHA != "" && clientSHA != actualSHA {
		removeTmp()
		jsonError(w, "sha256 mismatch — corrupted upload", http.StatusBadRequest)
		return
	}

	if err := os.Rename(tmpName, destPath); err != nil {
		removeTmp()
		jsonError(w, "rename: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// Restore original mtime on the stored file
	t := time.Unix(mtime, 0)
	os.Chtimes(destPath, t, t)

	storedName := relPath
	if err := dbpkg.RecordUpload(deviceID, filePath, storedName, actualSHA, written, mtime); err != nil {
		jsonError(w, "db: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[backup] stored device=%s size=%d sha=%s path=%s", sanitiseDeviceID(deviceID), written, actualSHA[:8], relPath)

	jsonOK(w, map[string]interface{}{
		"stored":  true,
		"sha256":  actualSHA,
		"size":    written,
	})
}

// GET /api/v1/backup/stats?device_id=...
func BackupStats(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "backup", "read") {
		return
	}
	deviceID := r.URL.Query().Get("device_id")
	if deviceID == "" {
		// Return all devices
		devices, err := dbpkg.AllDevices()
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		var out []map[string]interface{}
		for _, d := range devices {
			count, total, last, err := dbpkg.BackupStats(d)
			if err != nil {
				continue
			}
			out = append(out, map[string]interface{}{
				"device_id":   d,
				"file_count":  count,
				"total_bytes": total,
				"last_run":    last,
			})
		}
		if out == nil {
			out = []map[string]interface{}{}
		}
		jsonOK(w, out)
		return
	}

	count, total, last, err := dbpkg.BackupStats(deviceID)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]interface{}{
		"device_id":   deviceID,
		"file_count":  count,
		"total_bytes": total,
		"last_run":    last,
	})
}

// GET /api/v1/backup/files?device_id=...
func BackupFiles(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "backup", "read") {
		return
	}
	deviceID := r.URL.Query().Get("device_id")
	if deviceID == "" {
		jsonError(w, "device_id required", http.StatusBadRequest)
		return
	}
	files, err := dbpkg.ListBackupFiles(deviceID)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if files == nil {
		files = []dbpkg.BackupFile{}
	}
	jsonOK(w, files)
}

// ---- sanitisation helpers ----

func sanitiseDeviceID(id string) string {
	var b strings.Builder
	for _, ch := range id {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') || ch == '-' || ch == '_' {
			b.WriteRune(ch)
		} else {
			b.WriteRune('_')
		}
	}
	s := b.String()
	if s == "" {
		return "unknown"
	}
	return s
}

// sanitisePath converts an absolute device path like /storage/emulated/0/DCIM/foo.jpg
// into a relative OS-neutral path like DCIM/foo.jpg, preventing path traversal.
func sanitisePath(p string) string {
	// Normalise separators
	p = filepath.ToSlash(p)
	// Strip known Android storage prefixes
	for _, pfx := range []string{
		"/storage/emulated/0/",
		"/storage/emulated/",
		"/sdcard/",
		"/data/media/0/",
	} {
		if strings.HasPrefix(p, pfx) {
			p = p[len(pfx):]
			break
		}
	}
	// Remove any remaining leading slashes
	p = strings.TrimLeft(p, "/")
	// Prevent traversal
	cleaned := filepath.Clean(p)
	if strings.HasPrefix(cleaned, "..") {
		return fmt.Sprintf("unknown/%s", filepath.Base(p))
	}
	return cleaned
}

// GET  /api/v1/backup/config?device_id=...  → BackupDeviceConfig
// PUT  /api/v1/backup/config                → body: BackupDeviceConfig (device_id field required)
func BackupConfig(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "backup", "read") {
		return
	}
	switch r.Method {
	case http.MethodGet:
		deviceID := r.URL.Query().Get("device_id")
		if deviceID == "" {
			jsonError(w, "device_id required", http.StatusBadRequest)
			return
		}
		cfg, err := dbpkg.GetBackupConfig(deviceID)
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, cfg)

	case http.MethodPut:
		var body struct {
			dbpkg.BackupDeviceConfig
			DeviceID string `json:"device_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.DeviceID == "" {
			jsonError(w, "invalid request — device_id required", http.StatusBadRequest)
			return
		}
		if err := dbpkg.SetBackupConfig(body.DeviceID, body.BackupDeviceConfig); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		log.Printf("[backup] config updated device=%s schedule=%dh enabled=%v includes=%d excludes=%d",
			sanitiseDeviceID(body.DeviceID),
			body.ScheduleHours,
			body.Enabled,
			len(body.IncludePaths),
			len(body.ExcludePatterns),
		)
		jsonOK(w, map[string]bool{"ok": true})

	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// GET /api/v1/s3/config   — returns current S3 config (secrets redacted for non-admin)
// PUT /api/v1/s3/config   — update S3 config (admin only)
func S3Config(w http.ResponseWriter, r *http.Request) {
	_, _, isAdmin := middleware.UserFromContext(r)
	cfg := config.Get()

	type s3ConfigView struct {
		Enabled   bool   `json:"enabled"`
		Bucket    string `json:"bucket"`
		Region    string `json:"region"`
		Endpoint  string `json:"endpoint"`
		KeyID     string `json:"access_key_id"`      // redacted for non-admin
		HasKey    bool   `json:"has_secret"`
		SetupDone bool   `json:"setup_done"`
		BackupKey string `json:"backup_key,omitempty"` // only shown to admin
	}

	switch r.Method {
	case http.MethodGet:
		view := s3ConfigView{
			Enabled:   cfg.S3Enabled,
			Bucket:    cfg.S3Bucket,
			Region:    cfg.S3Region,
			Endpoint:  cfg.S3Endpoint,
			HasKey:    cfg.S3SecretAccessKey != "",
			SetupDone: cfg.S3SetupDone,
		}
		if isAdmin {
			view.KeyID    = cfg.S3AccessKeyID
			view.BackupKey = cfg.S3BackupKey
		} else {
			if len(cfg.S3AccessKeyID) > 4 {
				view.KeyID = cfg.S3AccessKeyID[:4] + "…"
			}
		}
		jsonOK(w, view)

	case http.MethodPut:
		if !isAdmin {
			jsonError(w, "admin only", http.StatusForbidden)
			return
		}
		var req struct {
			Enabled   bool   `json:"enabled"`
			Bucket    string `json:"bucket"`
			Region    string `json:"region"`
			Endpoint  string `json:"endpoint"`
			KeyID     string `json:"access_key_id"`
			Secret    string `json:"secret_access_key"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request", http.StatusBadRequest)
			return
		}
		config.Update(func(c *config.Config) {
			c.S3Enabled   = req.Enabled
			c.S3SetupDone = true
			c.S3Bucket    = req.Bucket
			c.S3Region    = req.Region
			c.S3Endpoint  = req.Endpoint
			if req.KeyID != "" {
				c.S3AccessKeyID = req.KeyID
			}
			if req.Secret != "" {
				c.S3SecretAccessKey = req.Secret
			}
		})
		jsonOK(w, map[string]bool{"ok": true})

	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// GET /api/v1/backup/health — returns S3 retry queue status and snapshot summary.
func BackupHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "backup", "read") {
		return
	}
	cfg := config.Get()

	var lastSuccessAt int64
	if v := dbpkg.GetBackupState("last_s3_success"); v != "" {
		fmt.Sscanf(v, "%d", &lastSuccessAt)
	}

	snapCount, snapBytes := dbpkg.CountAndSizeSnapshots()

	health := models.BackupHealth{
		LastSuccessAt:  lastSuccessAt,
		QueueDepth:     dbpkg.GetQueueDepth(),
		TotalFailed:    dbpkg.GetMaxAttemptCount(),
		NextRetryAt:    dbpkg.GetNextRetryAt(),
		LastError:      dbpkg.GetLastQueueError(),
		S3Enabled:      cfg.S3Enabled,
		SnapshotCount:  snapCount,
		TotalSizeBytes: snapBytes,
	}
	jsonOK(w, health)
}
