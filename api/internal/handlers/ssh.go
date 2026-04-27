package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// GET  /api/v1/ssh  — list all SSH keys
// POST /api/v1/ssh  — create
func SSHKeys(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		if !requirePerm(w, r, "ssh", "read") {
			return
		}
		list, err := db.AllSSHKeys()
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, list)

	case http.MethodPost:
		if !requirePerm(w, r, "ssh", "write") {
			return
		}
		var k models.SSHKey
		if err := json.NewDecoder(r.Body).Decode(&k); err != nil || k.Name == "" {
			jsonError(w, "invalid request", http.StatusBadRequest)
			return
		}
		id, err := db.InsertSSHKey(&k)
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		k.ID = id
		jsonOK(w, k)

	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// PUT    /api/v1/ssh/:id  — update
// DELETE /api/v1/ssh/:id  — delete
func SSHKeyByID(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/ssh/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		if !requirePerm(w, r, "ssh", "read") {
			return
		}
		k, err := db.GetSSHKey(id)
		if err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if k == nil {
			jsonError(w, "not found", http.StatusNotFound)
			return
		}
		jsonOK(w, k)

	case http.MethodPut:
		if !requirePerm(w, r, "ssh", "write") {
			return
		}
		var k models.SSHKey
		if err := json.NewDecoder(r.Body).Decode(&k); err != nil {
			jsonError(w, "invalid request", http.StatusBadRequest)
			return
		}
		k.ID = id
		if err := db.UpdateSSHKey(&k); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, k)

	case http.MethodDelete:
		if !requirePerm(w, r, "ssh", "delete") {
			return
		}
		if err := db.DeleteSSHKey(id); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]string{"message": "deleted"})

	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
