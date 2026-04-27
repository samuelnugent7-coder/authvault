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

// SecureNotes handles GET /api/v1/notes and POST /api/v1/notes
func SecureNotes(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		notes, err := db.AllSecureNotes()
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if notes == nil {
			notes = []models.SecureNote{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(notes)

	case http.MethodPost:
		var n models.SecureNote
		if err := json.NewDecoder(r.Body).Decode(&n); err != nil {
			http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
			return
		}
		if n.Title == "" {
			http.Error(w, `{"error":"title required"}`, http.StatusBadRequest)
			return
		}
		ownerID, ownerUsername, _ := middleware.UserFromContext(r)
		n.OwnerID = ownerID
		n.OwnerUsername = ownerUsername
		id, err := db.InsertSecureNote(&n)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		n.ID = id
		// Set tags if any
		if len(n.Tags) > 0 {
			tagIDs := resolveTagIDs(n.Tags)
			db.SetNoteTags(id, tagIDs)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(n)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// SecureNoteByID handles GET, PUT, DELETE /api/v1/notes/:id
func SecureNoteByID(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/notes/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		n, err := db.GetSecureNote(id)
		if err != nil || n == nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		uid, _, isAdmin := middleware.UserFromContext(r)
		if !db.CanViewNote(id, n.OwnerID, uid, isAdmin) {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		n.Tags, _ = db.GetNoteTagNames(id)
		n.Messages, _ = db.GetNoteMessages(id)
		n.Permissions, _ = db.GetNotePermissions(id)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(n)

	case http.MethodPut:
		var n models.SecureNote
		if err := json.NewDecoder(r.Body).Decode(&n); err != nil {
			http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
			return
		}
		// Permission check
		existing, eErr := db.GetSecureNote(id)
		if eErr != nil || existing == nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		uid, _, isAdmin := middleware.UserFromContext(r)
		if !db.CanEditNote(id, existing.OwnerID, uid, isAdmin) {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		n.ID = id
		if err := db.UpdateSecureNote(&n); err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		tagIDs := resolveTagIDs(n.Tags)
		db.SetNoteTags(id, tagIDs)
		w.WriteHeader(http.StatusNoContent)

	case http.MethodDelete:
		note, err := db.GetSecureNote(id)
		if err != nil || note == nil {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		_, username, _ := middleware.UserFromContext(r)
		// Soft delete to recycle bin
		db.SoftDeleteNote(note, username)
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// resolveTagIDs converts tag names to IDs (creates tags that don't exist).
func resolveTagIDs(names []string) []int64 {
	var ids []int64
	for _, name := range names {
		tags, _ := db.AllTags()
		found := int64(0)
		for _, t := range tags {
			if strings.EqualFold(t.Name, name) {
				found = t.ID
				break
			}
		}
		if found == 0 {
			id, _ := db.CreateTag(name, "#607d8b")
			found = id
		}
		if found > 0 {
			ids = append(ids, found)
		}
	}
	return ids
}
