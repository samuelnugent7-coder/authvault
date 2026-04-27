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

// NoteMessagesHandler handles GET/POST /api/v1/notes/:id/messages
func NoteMessagesHandler(w http.ResponseWriter, r *http.Request) {
	// Extract note ID from path: /api/v1/notes/{noteID}/messages
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	// parts: ["api","v1","notes","{id}","messages"]
	if len(parts) < 5 {
		http.Error(w, `{"error":"invalid path"}`, http.StatusBadRequest)
		return
	}
	noteID, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid note id"}`, http.StatusBadRequest)
		return
	}

	uid, username, isAdmin := middleware.UserFromContext(r)

	note, nerr := db.GetSecureNote(noteID)
	if nerr != nil || note == nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	switch r.Method {
	case http.MethodGet:
		if !db.CanViewNote(noteID, note.OwnerID, uid, isAdmin) {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		msgs, err := db.GetNoteMessages(noteID)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if msgs == nil {
			msgs = []models.NoteMessage{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(msgs)

	case http.MethodPost:
		if !db.CanViewNote(noteID, note.OwnerID, uid, isAdmin) {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		var body struct {
			Content string `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Content == "" {
			http.Error(w, `{"error":"content required"}`, http.StatusBadRequest)
			return
		}
		msg, err := db.PostNoteMessage(noteID, uid, username, body.Content)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(msg)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// NoteMessageByIDHandler handles DELETE /api/v1/notes/:id/messages/:msgId
// and PUT /api/v1/notes/:id/messages/:msgId (edit own message)
func NoteMessageByIDHandler(w http.ResponseWriter, r *http.Request) {
	// path: /api/v1/notes/{noteID}/messages/{msgID}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 6 {
		http.Error(w, `{"error":"invalid path"}`, http.StatusBadRequest)
		return
	}
	noteID, err1 := strconv.ParseInt(parts[3], 10, 64)
	msgID, err2 := strconv.ParseInt(parts[5], 10, 64)
	if err1 != nil || err2 != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	uid, _, isAdmin := middleware.UserFromContext(r)

	note, nerr := db.GetSecureNote(noteID)
	if nerr != nil || note == nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	switch r.Method {
	case http.MethodPut:
		var body struct {
			Content string `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Content == "" {
			http.Error(w, `{"error":"content required"}`, http.StatusBadRequest)
			return
		}
		if err := db.EditNoteMessage(msgID, uid, body.Content); err != nil {
			http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusForbidden)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	case http.MethodDelete:
		// Only the message author, note owner, or admin may delete
		if !isAdmin && note.OwnerID != uid {
			// Attempt author-only delete (EditNoteMessage checks authorID)
			if err := db.DeleteNoteMessage(msgID); err != nil {
				http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
				return
			}
		} else {
			db.DeleteNoteMessage(msgID)
		}
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// NotePermissionsHandler handles GET/PUT /api/v1/notes/:id/permissions
func NotePermissionsHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 5 {
		http.Error(w, `{"error":"invalid path"}`, http.StatusBadRequest)
		return
	}
	noteID, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid note id"}`, http.StatusBadRequest)
		return
	}

	uid, username, isAdmin := middleware.UserFromContext(r)

	note, nerr := db.GetSecureNote(noteID)
	if nerr != nil || note == nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	// Only owner or admin may manage permissions
	if !isAdmin && note.OwnerID != uid {
		http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
		return
	}

	switch r.Method {
	case http.MethodGet:
		perms, err := db.GetNotePermissions(noteID)
		if err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		if perms == nil {
			perms = []models.NotePermission{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(perms)

	case http.MethodPut:
		var perms []models.NotePermission
		if err := json.NewDecoder(r.Body).Decode(&perms); err != nil {
			http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
			return
		}
		if err := db.SetNotePermissions(noteID, perms, username); err != nil {
			http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

// TOTPTagsHandler handles PUT /api/v1/totp/:id/tags
func TOTPTagsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	totpID, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	var body struct {
		Tags []string `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}
	tagIDs := resolveTagIDs(body.Tags)
	if err := db.SetTOTPTags(totpID, tagIDs); err != nil {
		http.Error(w, `{"error":"db error"}`, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
