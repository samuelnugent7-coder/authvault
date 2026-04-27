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

// FolderSharesHandler handles GET / POST /api/v1/safe/folders/:id/shares
func FolderSharesHandler(w http.ResponseWriter, r *http.Request) {
	// Path: /api/v1/safe/folders/:id/shares
	trimmed := strings.TrimSuffix(r.URL.Path, "/shares")
	idStr := trimmed[strings.LastIndex(trimmed, "/")+1:]
	folderID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid folder id"}`, http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		shares, err := db.GetFolderShares(folderID)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if shares == nil {
			shares = []models.FolderShare{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(shares)

	case http.MethodPost:
		_, username, _ := middleware.UserFromContext(r)
		var body struct {
			UserID   int64 `json:"user_id"`
			CanWrite bool  `json:"can_write"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.UserID == 0 {
			http.Error(w, `{"error":"user_id required"}`, http.StatusBadRequest)
			return
		}
		if err := db.AddFolderShare(folderID, body.UserID, body.CanWrite, username); err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// RemoveFolderShare handles DELETE /api/v1/safe/folders/:fid/shares/:uid
func RemoveFolderShare(w http.ResponseWriter, r *http.Request) {
	// Path: /api/v1/safe/folders/:fid/shares/:uid
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 2 {
		http.Error(w, `{"error":"invalid path"}`, http.StatusBadRequest)
		return
	}
	uidStr := parts[len(parts)-1]
	var fidStr string
	for i, p := range parts {
		if p == "folders" && i+1 < len(parts) {
			fidStr = parts[i+1]
		}
	}
	folderID, err1 := strconv.ParseInt(fidStr, 10, 64)
	userID, err2 := strconv.ParseInt(uidStr, 10, 64)
	if err1 != nil || err2 != nil {
		http.Error(w, `{"error":"invalid ids"}`, http.StatusBadRequest)
		return
	}
	db.RemoveFolderShare(folderID, userID)
	w.WriteHeader(http.StatusNoContent)
}
