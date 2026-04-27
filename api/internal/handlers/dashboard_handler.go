package handlers

import (
	"encoding/json"
	"net/http"
	"os"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// GetDashboard handles GET /api/v1/dashboard
func GetDashboard(w http.ResponseWriter, r *http.Request) {
	// Collect stats
	stats := models.DashboardStats{
		TotalRecords:   db.CountRecords(),
		TotalTOTP:      db.CountTOTP(),
		TotalSSH:       db.CountSSH(),
		TotalNotes:     db.SecureNotesCount(),
		TotalTags:      db.TagsCount(),
		TotalAPIKeys:   0, // single-user context not available here; omit
		ActiveSessions: db.ActiveSessionsCount(),
		RecycleBinSize: db.RecycleBinCount(),
		SharedFolders:  db.SharedFoldersCount(),
	}

	// DB size
	dbPath := db.DBPath()
	if fi, err := os.Stat(dbPath); err == nil {
		stats.DBSizeBytes = fi.Size()
	}

	// Password health score: fraction of records with no issues
	// Use simple: 100 - (recycle_bin_size / max(1, total_records)) * 100
	total := stats.TotalRecords
	if total > 0 {
		stats.HealthScore = 100.0 - (float64(stats.RecycleBinSize)/float64(total))*10.0
	} else {
		stats.HealthScore = 100.0
	}
	if stats.HealthScore < 0 {
		stats.HealthScore = 0
	}

	// Recent 5 audit events
	recentAudit, _ := db.GetAuditLogs(0, true, 5)
	stats.RecentAudit = recentAudit

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}
