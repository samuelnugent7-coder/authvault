package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// GetPasswordHistory handles GET /api/v1/safe/records/:id/history
func GetPasswordHistory(w http.ResponseWriter, r *http.Request) {
	// Path: /api/v1/safe/records/:id/history
	parts := strings.Split(r.URL.Path, "/")
	var idStr string
	for i, p := range parts {
		if p == "records" && i+1 < len(parts) {
			idStr = parts[i+1]
		}
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	history, err := db.GetPasswordHistory(id)
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	if history == nil {
		history = []models.PasswordHistoryEntry{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(history)
}

// GetRecordVersions handles GET /api/v1/safe/records/:id/versions
func GetRecordVersions(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(r.URL.Path, "/")
	var idStr string
	for i, p := range parts {
		if p == "records" && i+1 < len(parts) {
			idStr = parts[i+1]
		}
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	versions, err := db.GetRecordVersions(id)
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	if versions == nil {
		versions = []models.RecordVersion{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(versions)
}

// RestoreRecordVersion handles POST /api/v1/safe/records/versions/:id/restore
func RestoreRecordVersion(w http.ResponseWriter, r *http.Request) {
	// Path: /api/v1/safe/records/versions/:versionID/restore
	trimmed := strings.TrimSuffix(r.URL.Path, "/restore")
	idStr := trimmed[strings.LastIndex(trimmed, "/")+1:]
	vID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid version id"}`, http.StatusBadRequest)
		return
	}
	record, err := db.RestoreRecordVersion(vID)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(record)
}
