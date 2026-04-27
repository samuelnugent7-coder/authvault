package handlers

import (
	"net/http"
	"strconv"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
)

// GET /api/v1/audit?limit=200
func ListAuditLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !requirePerm(w, r, "audit", "read") {
		return
	}
	limit := 200
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	logs, err := db.GetAuditLogs(uid, isAdmin, limit)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, logs)
}
