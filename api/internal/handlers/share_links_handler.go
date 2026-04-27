package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
	"authvault/api/internal/s3backup"
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

		// Fetch the record so we can snapshot it to S3
		record, _ := db.GetRecord(body.RecordID)
		var shareURL, s3Key string
		if record != nil {
			jsonData, err := json.Marshal(record)
			if err == nil {
				ttlDur := time.Duration(body.TTLSeconds) * time.Second
				// Generate a temporary token to build the S3 key before DB insert
				tmpToken := fmt.Sprintf("tmp_%d_%s", uid, username)
				s3Key, shareURL, _ = s3backup.UploadShareSnapshot(
					context.Background(), tmpToken, jsonData, ttlDur)
			}
		}

		link, err := db.CreateShareLink(body.RecordID, body.OneTime, body.TTLSeconds, username, shareURL, s3Key)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}

		// Re-upload with the real token so the key matches the token in the DB
		if record != nil && link != nil {
			jsonData, err := json.Marshal(record)
			if err == nil {
				ttlDur := time.Duration(body.TTLSeconds) * time.Second
				s3Key2, shareURL2, _ := s3backup.UploadShareSnapshot(
					context.Background(), link.Token, jsonData, ttlDur)
				if s3Key2 != "" {
					link.S3Key = s3Key2
					link.ShareURL = shareURL2
					// Clean up the tmp key
					s3backup.DeleteShareSnapshot(context.Background(), s3Key)
					db.UpdateShareLinkS3(link.ID, s3Key2, shareURL2)
				}
			}
		}

		db.LogAudit(uid, username, "share_link_create", "", "", strconv.FormatInt(body.RecordID, 10))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(link)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// DeleteShareLinkHandler handles DELETE /api/v1/share-links/:id
func DeleteShareLinkHandler(w http.ResponseWriter, r *http.Request) {
	_, username, _ := middleware.UserFromContext(r)
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/share-links/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	// Delete S3 object if any
	links, _ := db.ListShareLinks(username)
	for _, l := range links {
		if l.ID == id && l.S3Key != "" {
			s3backup.DeleteShareSnapshot(context.Background(), l.S3Key)
			break
		}
	}
	db.DeleteShareLink(id, username)
	w.WriteHeader(http.StatusNoContent)
}

// GetSharedRecord handles GET /api/v1/share/:token — public endpoint (no auth required)
// If the record snapshot was uploaded to S3, redirect to the presigned URL.
// Otherwise fall back to serving directly from the DB.
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
	db.LogAudit(0, "anonymous", "share_link_view", r.RemoteAddr, r.UserAgent(), token[:8]+"...")

	// If we have a fresh presigned S3 URL, redirect to it
	if link.ShareURL != "" {
		http.Redirect(w, r, link.ShareURL, http.StatusTemporaryRedirect)
		return
	}

	// Fall back: serve from DB
	record, err := db.GetRecord(link.RecordID)
	if err != nil || record == nil {
		http.Error(w, `{"error":"record not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(record)
}
