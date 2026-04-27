package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
)

// GET /api/v1/sessions
func ListSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	sessions, err := db.GetSessions(uid, isAdmin)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, sessions)
}

// DELETE /api/v1/sessions/:id  — revoke a session
func RevokeSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	uid, username, isAdmin := middleware.UserFromContext(r)
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/sessions/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid session id", http.StatusBadRequest)
		return
	}
	if err := db.RevokeSession(id, uid, isAdmin); err != nil {
		if err.Error() == "permission denied" {
			jsonError(w, "permission denied", http.StatusForbidden)
		} else {
			jsonError(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}
	db.LogAudit(uid, username, "session_revoked", "", "", strconv.FormatInt(id, 10))
	jsonOK(w, map[string]string{"message": "revoked"})
}

// DELETE /api/v1/sessions  — revoke all sessions for a user (admin only via ?user_id=X, or own)
func RevokeAllSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	uid, username, isAdmin := middleware.UserFromContext(r)

	targetID := uid
	if isAdmin {
		if uidStr := r.URL.Query().Get("user_id"); uidStr != "" {
			if parsed, err := strconv.ParseInt(uidStr, 10, 64); err == nil {
				targetID = parsed
			}
		}
	}
	if err := db.RevokeAllUserSessions(targetID); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	db.LogAudit(uid, username, "session_revoked", "", "", "all")
	jsonOK(w, map[string]string{"message": "all sessions revoked"})
}

// Helper used by Login handler to record a session.
func RecordSession(userID int64, username, token string, r *http.Request) {
	ip := r.RemoteAddr
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		ip = strings.Split(fwd, ",")[0]
	}
	device := r.Header.Get("User-Agent")
	if len(device) > 200 {
		device = device[:200]
	}
	fpHash := ComputeFingerprint(r)
	db.CreateSession(userID, username, token, device, ip, fpHash)
}

// ComputeFingerprint builds a stable device fingerprint from request headers.
// It is NOT used to block logins — only to detect changes and flag sessions.
func ComputeFingerprint(r *http.Request) string {
	ua   := r.Header.Get("User-Agent")
	lang := r.Header.Get("Accept-Language")
	enc  := r.Header.Get("Accept-Encoding")
	raw  := fmt.Sprintf("%s|%s|%s", ua, lang, enc)
	h    := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

// TokenFromRequest extracts the raw JWT from the Authorization header.
func TokenFromRequest(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		return auth[7:]
	}
	return ""
}
