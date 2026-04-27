package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/config"
	"authvault/api/internal/crypto"
	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// requireAdmin returns false and writes a 403 if the caller is not admin.
func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	_, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		jsonError(w, "admin access required", http.StatusForbidden)
		return false
	}
	return true
}

// GET /api/v1/admin/users
func ListAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	users, err := db.ListUsers()
	if err != nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	var resp []models.UserResponse
	for _, u := range users {
		perms := db.GetPermissions(u.ID, u.IsAdmin)
		resp = append(resp, models.UserResponse{
			ID:        u.ID,
			Username:  u.Username,
			IsAdmin:   u.IsAdmin,
			CreatedAt: u.CreatedAt,
			Perms:     perms,
		})
	}
	if resp == nil {
		resp = []models.UserResponse{}
	}
	jsonOK(w, resp)
}

// POST /api/v1/admin/users
func CreateAdminUser(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	var req models.CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	req.Username = strings.ToLower(strings.TrimSpace(req.Username))
	if req.Username == "" || req.Password == "" {
		jsonError(w, "username and password are required", http.StatusBadRequest)
		return
	}
	// Don't allow creating a duplicate admin username
	existing, _ := db.GetUserByUsername(req.Username)
	if existing != nil {
		jsonError(w, "username already exists", http.StatusConflict)
		return
	}
	user, err := db.CreateUser(req.Username, req.Password, req.IsAdmin)
	if err != nil {
		jsonError(w, "could not create user: "+err.Error(), http.StatusInternalServerError)
		return
	}
	perms := db.GetPermissions(user.ID, user.IsAdmin)
	jsonOK(w, models.UserResponse{
		ID:        user.ID,
		Username:  user.Username,
		IsAdmin:   user.IsAdmin,
		CreatedAt: user.CreatedAt,
		Perms:     perms,
	})
}

// GET /api/v1/admin/users/:id
func GetAdminUser(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	// Strip sub-paths like /permissions
	user, err := db.GetUserByID(id)
	if err != nil || user == nil {
		jsonError(w, "user not found", http.StatusNotFound)
		return
	}
	perms := db.GetPermissions(user.ID, user.IsAdmin)
	jsonOK(w, models.UserResponse{
		ID:        user.ID,
		Username:  user.Username,
		IsAdmin:   user.IsAdmin,
		CreatedAt: user.CreatedAt,
		Perms:     perms,
	})
}

// PUT /api/v1/admin/users/:id
func UpdateAdminUser(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	var req models.UpdateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	// Prevent stripping own admin flag
	callerID, _, _ := middleware.UserFromContext(r)
	if callerID == id && !req.IsAdmin {
		jsonError(w, "you cannot remove your own admin status", http.StatusBadRequest)
		return
	}
	if err := db.UpdateUser(id, req.Password, req.IsAdmin); err != nil {
		jsonError(w, "could not update user", http.StatusInternalServerError)
		return
	}
	user, _ := db.GetUserByID(id)
	if user == nil {
		jsonError(w, "user not found", http.StatusNotFound)
		return
	}
	perms := db.GetPermissions(user.ID, user.IsAdmin)
	jsonOK(w, models.UserResponse{
		ID:        user.ID,
		Username:  user.Username,
		IsAdmin:   user.IsAdmin,
		CreatedAt: user.CreatedAt,
		Perms:     perms,
	})
}

// DELETE /api/v1/admin/users/:id
func DeleteAdminUser(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	callerID, _, _ := middleware.UserFromContext(r)
	if callerID == id {
		jsonError(w, "you cannot delete your own account", http.StatusBadRequest)
		return
	}
	if err := db.DeleteUser(id); err != nil {
		jsonError(w, "could not delete user", http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"message": "deleted"})
}

// GET /api/v1/admin/users/:id/permissions
func GetUserPermissions(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	user, _ := db.GetUserByID(id)
	if user == nil {
		jsonError(w, "user not found", http.StatusNotFound)
		return
	}
	perms := db.GetPermissions(user.ID, user.IsAdmin)
	jsonOK(w, perms)
}

// PUT /api/v1/admin/users/:id/permissions
func SetUserPermissions(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	user, _ := db.GetUserByID(id)
	if user == nil {
		jsonError(w, "user not found", http.StatusNotFound)
		return
	}
	if user.IsAdmin {
		jsonError(w, "admin users have all permissions", http.StatusBadRequest)
		return
	}
	var perms models.UserPermissions
	if err := json.NewDecoder(r.Body).Decode(&perms); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if err := db.SetPermissions(id, perms); err != nil {
		jsonError(w, "could not save permissions", http.StatusInternalServerError)
		return
	}
	jsonOK(w, db.GetPermissions(id, false))
}

// parseIDFromPath extracts the integer segment after the given prefix.
// e.g. GET /api/v1/admin/users/5/permissions → id=5 (strips /permissions suffix)
func parseIDFromPath(w http.ResponseWriter, r *http.Request, prefix string) (int64, bool) {
	path := strings.TrimPrefix(r.URL.Path, prefix)
	// strip any trailing sub-path like /permissions
	if idx := strings.Index(path, "/"); idx != -1 {
		path = path[:idx]
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return 0, false
	}
	return id, true
}

// PUT /api/v1/admin/users/:id/expiry — set or clear account expiry
func SetUserExpiry(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	id, ok := parseIDFromPath(w, r, "/api/v1/admin/users/")
	if !ok {
		return
	}
	var body struct {
		ExpiresAt int64 `json:"expires_at"` // unix ts, 0 = clear
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if err := db.SetUserExpiry(id, body.ExpiresAt); err != nil {
		jsonError(w, "could not set expiry", http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]interface{}{"expires_at": body.ExpiresAt})
}

// PUT /api/v1/admin/duress — set duress vault password
func SetDuressPassword(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	var body struct {
		Password string `json:"password"`
		Clear    bool   `json:"clear"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if body.Clear {
		config.Update(func(c *config.Config) {
			c.DuressPasswordHash = ""
			c.DuressArgonSalt = ""
		})
		config.Save()
		jsonOK(w, map[string]string{"message": "duress password cleared"})
		return
	}
	if body.Password == "" {
		jsonError(w, "password required", http.StatusBadRequest)
		return
	}
	salt, hash, err := crypto.HashPassword(body.Password)
	if err != nil {
		jsonError(w, "internal error", http.StatusInternalServerError)
		return
	}
	config.Update(func(c *config.Config) {
		c.DuressPasswordHash = hash
		c.DuressArgonSalt = salt
	})
	config.Save()
	jsonOK(w, map[string]string{"message": "duress password set"})
}

// GET /api/v1/admin/duress/folders — list decoy folders
func ListDecoyFolders(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	folders, err := db.GetDecoyFolders()
	if err != nil {
		jsonError(w, "db error", http.StatusInternalServerError)
		return
	}
	jsonOK(w, folders)
}

// PUT /api/v1/admin/duress/folders/:id — toggle decoy flag on a folder
func SetDecoyFolder(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/admin/duress/folders/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	var body struct {
		IsDecoy bool `json:"is_decoy"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	db.SetFolderDecoy(id, body.IsDecoy)
	w.WriteHeader(http.StatusNoContent)
}
