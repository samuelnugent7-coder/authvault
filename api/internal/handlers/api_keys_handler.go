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

// APIKeysHandler handles GET /api/v1/api-keys and POST /api/v1/api-keys
func APIKeysHandler(w http.ResponseWriter, r *http.Request) {
	uid, username, _ := middleware.UserFromContext(r)
	switch r.Method {
	case http.MethodGet:
		keys, err := db.ListAPIKeys(uid)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if keys == nil {
			keys = []models.APIKey{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(keys)

	case http.MethodPost:
		var body struct {
			Name      string `json:"name"`
			ExpiresAt int64  `json:"expires_at"` // unix ts, 0 = never
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
			http.Error(w, `{"error":"name required"}`, http.StatusBadRequest)
			return
		}
		key, err := db.GenerateAPIKey(uid, body.Name, body.ExpiresAt)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		db.LogAudit(uid, username, "api_key_created", "", "", body.Name)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(key)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// APIKeyByID handles DELETE /api/v1/api-keys/:id and POST /api/v1/api-keys/:id/revoke
func APIKeyByID(w http.ResponseWriter, r *http.Request) {
	uid, username, _ := middleware.UserFromContext(r)
	path := r.URL.Path
	var action string
	if strings.HasSuffix(path, "/revoke") {
		action = "revoke"
		path = strings.TrimSuffix(path, "/revoke")
	}
	idStr := strings.TrimPrefix(path, "/api/v1/api-keys/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	if action == "revoke" || r.Method == http.MethodPost {
		db.RevokeAPIKey(id, uid)
		db.LogAudit(uid, username, "api_key_revoked", "", "", strconv.FormatInt(id, 10))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method == http.MethodDelete {
		db.DeleteAPIKey(id, uid)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
}
