package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/config"
	dbpkg "authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
	"authvault/api/internal/snapshot"
)

// GET /api/v1/snapshots
func ListSnapshots(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "backup", "read") {
		return
	}
	snaps, err := dbpkg.GetSnapshots()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	count, totalBytes := dbpkg.CountAndSizeSnapshots()
	jsonOK(w, map[string]interface{}{
		"snapshots":        snaps,
		"count":            count,
		"total_size_bytes": totalBytes,
	})
}

// POST /api/v1/snapshots
// Body: {"type":"full"} or {"type":"incremental"}
func TriggerSnapshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "backup", "write") {
		return
	}

	uid, username, _ := middleware.UserFromContext(r)

	var req struct {
		Type string `json:"type"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Type == "" {
		req.Type = "full"
	}
	if req.Type != "full" && req.Type != "incremental" {
		jsonError(w, `type must be "full" or "incremental"`, http.StatusBadRequest)
		return
	}

	cfg := config.Get()

	var (
		snap     *models.Snapshot
		filePath string
		err      error
	)

	if req.Type == "incremental" {
		base, berr := dbpkg.GetLastFullSnapshot()
		if berr != nil || base == nil {
			// Fall back to full if no base exists
			req.Type = "full"
			log.Printf("[snapshot] no full snapshot found; falling back to full")
		} else {
			snap, filePath, err = snapshot.CreateIncremental(cfg.DataDir, base)
		}
	}

	if req.Type == "full" {
		snap, filePath, err = snapshot.CreateFull(cfg.DataDir)
	}

	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	snapID, err := dbpkg.InsertSnapshot(snap)
	if err != nil {
		// Clean up the orphaned file
		snapshot.DeleteFile(cfg.DataDir, snap.FileName)
		jsonError(w, "db error: "+err.Error(), http.StatusInternalServerError)
		return
	}
	snap.ID = snapID
	_ = filePath

	log.Printf("[snapshot] %s created: id=%d file=%s size=%d records=%d",
		snap.Type, snap.ID, snap.FileName, snap.SizeBytes, snap.RecordCount)

	dbpkg.LogAudit(uid, username, models.AuditSnapshotCreated, clientIP(r), r.UserAgent(),
		fmt.Sprintf("type=%s id=%d size=%d", snap.Type, snap.ID, snap.SizeBytes))

	// Prune old snapshots if over limit
	maxCount := cfg.SnapshotMaxCount
	if maxCount <= 0 {
		maxCount = 30
	}
	pruneOldSnapshots(cfg.DataDir, maxCount)

	jsonOK(w, snap)
}

// POST /api/v1/snapshots/:id/restore
func RestoreSnapshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	uid, username, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		jsonError(w, "admin only", http.StatusForbidden)
		return
	}

	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/snapshots/")
	idStr = strings.TrimSuffix(idStr, "/restore")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid snapshot id", http.StatusBadRequest)
		return
	}

	cfg := config.Get()
	if err := snapshot.RestoreFromID(cfg.DataDir, id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("[snapshot] restore: id=%d by user %d", id, uid)
	dbpkg.LogAudit(uid, username, models.AuditSnapshotRestored, clientIP(r), r.UserAgent(),
		fmt.Sprintf("snapshot_id=%d", id))

	jsonOK(w, map[string]string{"message": "restored"})
}

// DELETE /api/v1/snapshots/:id
func DeleteSnapshot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	_, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		jsonError(w, "admin only", http.StatusForbidden)
		return
	}

	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/snapshots/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid snapshot id", http.StatusBadRequest)
		return
	}

	snap, err := dbpkg.GetSnapshot(id)
	if err != nil || snap == nil {
		jsonError(w, "snapshot not found", http.StatusNotFound)
		return
	}

	cfg := config.Get()
	snapshot.DeleteFile(cfg.DataDir, snap.FileName) // best-effort delete
	if err := dbpkg.DeleteSnapshotRecord(id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"message": "deleted"})
}

// pruneOldSnapshots deletes oldest snapshots beyond maxCount (keeps full snaps preferentially).
func pruneOldSnapshots(dataDir string, maxCount int) {
	snaps, err := dbpkg.GetSnapshots()
	if err != nil || len(snaps) <= maxCount {
		return
	}
	// snaps is newest-first; delete tail
	toDelete := snaps[maxCount:]
	for _, s := range toDelete {
		snapshot.DeleteFile(dataDir, s.FileName)
		dbpkg.DeleteSnapshotRecord(s.ID)
	}
}
