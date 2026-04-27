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

// ShareLinksHandler handles GET /api/v1/share-links and POST /api/v1/share-links
func ShareLinksHandler(w http.ResponseWriter, r *http.Request) {
	uid, username, _ := middleware.UserFromContext(r)
	switch r.Method {
	case http.MethodGet:
		links, err := db.ListShareLinks(username)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if links == nil {
			links = []models.ShareLink{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(links)

	case http.MethodPost:
		var body struct {
			RecordID   int64 `json:"record_id"`
			OneTime    bool  `json:"one_time"`
			TTLSeconds int64 `json:"ttl_seconds"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RecordID == 0 {
			http.Error(w, `{"error":"record_id required"}`, http.StatusBadRequest)
			return
		}
		if body.TTLSeconds <= 0 {
			body.TTLSeconds = 86400
		}
		link, err := db.CreateShareLink(body.RecordID, body.OneTime, body.TTLSeconds, username)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		db.LogAudit(uid, username, "share_link_create", "", "", strconv.FormatInt(body.RecordID, 10))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(link)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// DeleteShareLink handles DELETE /api/v1/share-links/:id
func DeleteShareLinkHandler(w http.ResponseWriter, r *http.Request) {
	_, username, _ := middleware.UserFromContext(r)
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/share-links/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	db.DeleteShareLink(id, username)
	w.WriteHeader(http.StatusNoContent)
}

// GetSharedRecord handles GET /api/v1/share/:token — public endpoint (no auth)
func GetSharedRecord(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.URL.Path, "/api/v1/share/")
	if token == "" {
		http.Error(w, `{"error":"token required"}`, http.StatusBadRequest)
		return
	}
	link, err := db.ConsumeShareLink(token)
	if err != nil || link == nil {
		http.Error(w, `{"error":"invalid or expired link"}`, http.StatusNotFound)
		return
	}
	record, err := db.GetRecord(link.RecordID)
	if err != nil || record == nil {
		http.Error(w, `{"error":"record not found"}`, http.StatusNotFound)
		return
	}
	db.LogAudit(0, "anonymous", "share_link_view", r.RemoteAddr, r.UserAgent(), token[:8]+"...")
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(record)
}
