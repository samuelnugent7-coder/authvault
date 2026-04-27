package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// ListRecycleBin handles GET /api/v1/recycle-bin
func ListRecycleBin(w http.ResponseWriter, r *http.Request) {
	entries, err := db.ListRecycleBin()
	if err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	if entries == nil {
		entries = []models.RecycleBinEntry{}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(entries)
}

// RestoreFromBin handles POST /api/v1/recycle-bin/:id/restore
func RestoreBinItem(w http.ResponseWriter, r *http.Request) {
	_, username, _ := middleware.UserFromContext(r)
	idStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/v1/recycle-bin/"), "/restore")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	entry, err := db.RestoreFromRecycleBin(id, username)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusBadRequest)
		return
	}
	if entry == nil {
		http.Error(w, `{"error":"not found or expired"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(entry)
}

// DeleteBinItem handles DELETE /api/v1/recycle-bin/:id (permanent delete)
func DeleteBinItem(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/recycle-bin/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	db.DeleteBinEntry(id)
	w.WriteHeader(http.StatusNoContent)
}

// EmptyRecycleBin handles DELETE /api/v1/recycle-bin (purge all expired)
func EmptyRecycleBin(w http.ResponseWriter, r *http.Request) {
	db.PurgeExpiredBin()
	w.WriteHeader(http.StatusNoContent)
}
