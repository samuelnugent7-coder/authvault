package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// GET /api/v1/totp
func ListTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "read") {
		return
	}
	list, err := db.AllTOTP()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if list == nil {
		list = []models.TOTPEntry{}
	}
	// Per-entry read filtering for non-admin users
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		filtered := list[:0]
		for _, e := range list {
			if !db.IsExplicitlyDenied(uid, fmt.Sprintf("totp:%d", e.ID), "read") {
				filtered = append(filtered, e)
			}
		}
		list = filtered
	}
	jsonOK(w, list)
}

// POST /api/v1/totp
func CreateTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "write") {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "", http.StatusMethodNotAllowed)
		return
	}
	var e models.TOTPEntry
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	if e.Duration == 0 { e.Duration = 30 }
	if e.Length == 0 { e.Length = 6 }

	id, err := db.InsertTOTP(&e)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	e.ID = id
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, e)
}

// PUT /api/v1/totp/{id}
func UpdateTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin && db.IsExplicitlyDenied(uid, fmt.Sprintf("totp:%d", id), "write") {
		jsonError(w, "permission denied for this TOTP entry", http.StatusForbidden)
		return
	}
	var e models.TOTPEntry
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	e.ID = id
	if err := db.UpdateTOTP(&e); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, e)
}

// DELETE /api/v1/totp/{id}
func DeleteTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin && db.IsExplicitlyDenied(uid, fmt.Sprintf("totp:%d", id), "write") {
		jsonError(w, "permission denied for this TOTP entry", http.StatusForbidden)
		return
	}
	if err := db.DeleteTOTP(id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /api/v1/totp/import  — body: JSON array matching Accounts.json format
func ImportTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "import") {
		return
	}
	var entries []models.TOTPImportEntry
	if err := json.NewDecoder(r.Body).Decode(&entries); err != nil {
		jsonError(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	count := 0
	for _, imp := range entries {
		e := models.TOTPEntry{
			Name:     imp.Name,
			Issuer:   imp.Issuer,
			Secret:   imp.Secret,
			Duration: imp.Duration,
			Length:   imp.Length,
			HashAlgo: imp.HashAlgo,
		}
		if e.Duration == 0 { e.Duration = 30 }
		if e.Length == 0 { e.Length = 6 }
		if _, err := db.InsertTOTP(&e); err == nil {
			count++
		}
	}
	jsonOK(w, map[string]int{"imported": count})
}

// GET /api/v1/totp/export  — returns JSON array in Accounts.json format
func ExportTOTP(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "totp", "export") {
		return
	}
	list, err := db.AllTOTP()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var out []models.TOTPImportEntry
	for _, e := range list {
		out = append(out, models.TOTPImportEntry{
			Name:     e.Name,
			Issuer:   e.Issuer,
			Secret:   e.Secret,
			Duration: e.Duration,
			Length:   e.Length,
			HashAlgo: e.HashAlgo,
		})
	}
	if out == nil {
		out = []models.TOTPImportEntry{}
	}
	w.Header().Set("Content-Disposition", "attachment; filename=Accounts.json")
	jsonOK(w, out)
}

// ---- helper ----
func idFromPath(path string) (int64, bool) {
	parts := strings.Split(strings.TrimRight(path, "/"), "/")
	if len(parts) == 0 {
		return 0, false
	}
	id, err := strconv.ParseInt(parts[len(parts)-1], 10, 64)
	return id, err == nil
}
