package handlers

import (
"context"
"encoding/base64"
"encoding/json"
"log"
"net/http"
"strings"
"time"

"github.com/golang-jwt/jwt/v5"

"authvault/api/internal/config"
"authvault/api/internal/crypto"
"authvault/api/internal/db"
"authvault/api/internal/middleware"
"authvault/api/internal/models"
"authvault/api/internal/s3backup"
)

// POST /api/v1/auth/login
// Accepts: {"username":"admin","password":"..."} — username defaults to "admin"
func Login(w http.ResponseWriter, r *http.Request) {
if r.Method != http.MethodPost {
jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
return
}

var req models.LoginRequestV2
if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
jsonError(w, "invalid request", http.StatusBadRequest)
return
}
if req.Username == "" {
req.Username = "admin"
}
req.Username = strings.ToLower(strings.TrimSpace(req.Username))

cfg := config.Get()

// First-ever login: set master password + create admin user
if cfg.PasswordHash == "" {
if req.Username != "admin" {
jsonError(w, "no users exist yet – log in as admin to set the master password", http.StatusUnauthorized)
return
}
saltHex, hashB64, err := crypto.HashPassword(req.Password)
if err != nil {
jsonError(w, "internal error", http.StatusInternalServerError)
return
}
if err := config.Update(func(c *config.Config) {
c.ArgonSalt    = saltHex
c.PasswordHash = hashB64
}); err != nil {
jsonError(w, "could not save config", http.StatusInternalServerError)
return
}
cfg = config.Get()
if err := db.CreateAdminFromLegacy(saltHex, hashB64); err != nil {
jsonError(w, "could not create admin user", http.StatusInternalServerError)
return
}
}

// Ensure admin user exists (migration from old single-password setup)
if req.Username == "admin" {
if err := db.CreateAdminFromLegacy(cfg.ArgonSalt, cfg.PasswordHash); err != nil {
log.Printf("admin migration: %v", err)
}
}

// Look up user
user, err := db.GetUserByUsername(req.Username)
if err != nil {
jsonError(w, "internal error", http.StatusInternalServerError)
return
}
if user == nil {
	db.LogAudit(0, req.Username, "login_failed", clientIP(r), r.UserAgent(), "unknown user")
	jsonError(w, "invalid username or password", http.StatusUnauthorized)
	return
}

if !crypto.VerifyPassword(req.Password, user.ArgonSalt, user.PasswordHash) {
	// Check duress password before returning failure
	cfg2 := config.Get()
	if cfg2.DuressPasswordHash != "" && cfg2.DuressArgonSalt != "" &&
		crypto.VerifyPassword(req.Password, cfg2.DuressArgonSalt, cfg2.DuressPasswordHash) {
		// Duress login — issue limited JWT with duress flag
		db.LogAudit(user.ID, user.Username, "duress_login", clientIP(r), r.UserAgent(), "")
		dToken := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
			"sub":      "vault",
			"uid":      user.ID,
			"username": user.Username,
			"admin":    false,
			"duress":   true,
			"exp":      time.Now().Add(12 * time.Hour).Unix(),
			"iat":      time.Now().Unix(),
		})
		signed, _ := dToken.SignedString([]byte(cfg2.ClientSecret))
		perms := db.GetPermissions(user.ID, false)
		jsonOK(w, models.LoginResponseV2{Token: signed, Username: user.Username, IsAdmin: false, Perms: perms})
		return
	}
	db.LogAudit(user.ID, user.Username, "login_failed", clientIP(r), r.UserAgent(), "wrong password")
	jsonError(w, "invalid username or password", http.StatusUnauthorized)
	return
}

// Check account expiry
if user.ExpiresAt > 0 && time.Now().Unix() > user.ExpiresAt {
	db.LogAudit(user.ID, user.Username, "login_failed", clientIP(r), r.UserAgent(), "account expired")
	jsonError(w, "account has expired", http.StatusForbidden)
	return
}

if user.IsAdmin {
	key, err := crypto.DeriveKey(req.Password, user.ArgonSalt)
	if err != nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	crypto.SetActiveKey(key)
	go func() {
		if err := s3backup.Run(context.Background()); err != nil {
			log.Printf("[s3backup] post-login run: %v", err)
		}
	}()
} else {
	// Non-admin users can only log in if the vault is already unlocked by admin
	if !crypto.IsUnlocked() {
		jsonError(w, "vault is locked - an admin must unlock it first", http.StatusForbidden)
		return
	}
}

// Issue JWT with user claims
token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
"sub":      "vault",
"uid":      user.ID,
"username": user.Username,
"admin":    user.IsAdmin,
"exp":      time.Now().Add(12 * time.Hour).Unix(),
"iat":      time.Now().Unix(),
})
signed, err := token.SignedString([]byte(cfg.ClientSecret))
if err != nil {
jsonError(w, "internal error", http.StatusInternalServerError)
return
}

perms := db.GetPermissions(user.ID, user.IsAdmin)

// Record session and audit log
ip := clientIP(r)
device := r.UserAgent()
RecordSession(user.ID, user.Username, signed, r)
// Check if this IP is new for this user (geo/IP alert)
var prevLogins int
db.QueryRowForAudit(user.ID, ip, &prevLogins)
if prevLogins == 0 {
	db.LogAudit(user.ID, user.Username, "new_ip_detected", ip, device, "first login from this IP")
}
db.LogAudit(user.ID, user.Username, "login", ip, device, "")

jsonOK(w, models.LoginResponseV2{
Token:    signed,
Username: user.Username,
IsAdmin:  user.IsAdmin,
Perms:    perms,
})
}

// POST /api/v1/auth/logout
func Logout(w http.ResponseWriter, r *http.Request) {
uid, username, isAdmin := middleware.UserFromContext(r)
// Touch the session last_seen then revoke it
tok := TokenFromRequest(r)
if tok != "" {
	db.TouchSession(tok)
}
db.LogAudit(uid, username, "logout", clientIP(r), r.UserAgent(), "")
if isAdmin {
	// Re-load the key from config so non-admin users stay unblocked after admin logout.
	cfg := config.Get()
	if cfg.PasswordHash != "" {
		if keyBytes, err := base64.StdEncoding.DecodeString(cfg.PasswordHash); err == nil && len(keyBytes) == 32 {
			crypto.SetActiveKey(keyBytes)
		} else {
			crypto.ClearActiveKey()
		}
	} else {
		crypto.ClearActiveKey()
	}
}
jsonOK(w, map[string]string{"message": "locked"})
}

// GET /api/v1/auth/status
func Status(w http.ResponseWriter, r *http.Request) {
jsonOK(w, models.StatusResponse{Unlocked: crypto.IsUnlocked()})
}

// GET /api/v1/auth/me
func Me(w http.ResponseWriter, r *http.Request) {
userID, username, isAdmin := middleware.UserFromContext(r)
perms := db.GetPermissions(userID, isAdmin)
jsonOK(w, models.MeResponse{
Username: username,
IsAdmin:  isAdmin,
Perms:    perms,
})
}

// ---- helpers ----

func jsonOK(w http.ResponseWriter, v any) {
w.Header().Set("Content-Type", "application/json")
json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
w.Header().Set("Content-Type", "application/json")
w.WriteHeader(code)
json.NewEncoder(w).Encode(models.ErrorResponse{Error: msg})
}

// requirePerm checks section-level permission. Returns false and writes 403 on denial.
func requirePerm(w http.ResponseWriter, r *http.Request, resource, action string) bool {
	uid, _, isAdmin := middleware.UserFromContext(r)
	if db.HasPermission(uid, isAdmin, resource, action) {
		return true
	}
	jsonError(w, "permission denied", http.StatusForbidden)
	return false
}

// clientIP extracts the real client IP from the request.
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		parts := strings.Split(fwd, ",")
		return strings.TrimSpace(parts[0])
	}
	if rip := r.Header.Get("X-Real-IP"); rip != "" {
		return rip
	}
	ip := r.RemoteAddr
	if idx := strings.LastIndex(ip, ":"); idx > 0 {
		ip = ip[:idx]
	}
	return ip
}
