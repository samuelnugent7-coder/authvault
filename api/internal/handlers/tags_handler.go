package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// TagsHandler handles GET /api/v1/tags and POST /api/v1/tags
func TagsHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		tags, err := db.AllTags()
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if tags == nil {
			tags = []models.Tag{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(tags)

	case http.MethodPost:
		var t models.Tag
		if err := json.NewDecoder(r.Body).Decode(&t); err != nil || t.Name == "" {
			http.Error(w, `{"error":"name required"}`, http.StatusBadRequest)
			return
		}
		if t.Color == "" {
			t.Color = "#607d8b"
		}
		id, err := db.CreateTag(t.Name, t.Color)
		if err != nil {
			http.Error(w, `{"error":"could not create tag (may already exist)"}`, http.StatusConflict)
			return
		}
		t.ID = id
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(t)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// TagByID handles GET, PUT, DELETE /api/v1/tags/:id
func TagByID(w http.ResponseWriter, r *http.Request) {
	// strip possible /records suffix
	path := r.URL.Path
	var sub string
	if strings.HasSuffix(path, "/records") {
		sub = "records"
		path = strings.TrimSuffix(path, "/records")
	}
	idStr := strings.TrimPrefix(path, "/api/v1/tags/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	if sub == "records" {
		// GET /api/v1/tags/:id/records — return record IDs with this tag
		recordIDs := db.GetRecordsByTag(id)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"record_ids": recordIDs})
		return
	}

	switch r.Method {
	case http.MethodGet:
		t, err := db.GetTag(id)
		if err != nil || t == nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(t)

	case http.MethodPut:
		var t models.Tag
		if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
			http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
			return
		}
		db.UpdateTag(id, t.Name, t.Color)
		w.WriteHeader(http.StatusNoContent)

	case http.MethodDelete:
		db.DeleteTag(id)
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// SetRecordTags handles PUT /api/v1/safe/records/:id/tags
func SetRecordTagsHandler(w http.ResponseWriter, r *http.Request) {
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
	var body struct {
		TagIDs []int64 `json:"tag_ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}
	if err := db.SetRecordTags(id, body.TagIDs); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
