package models

// ------ Users ------

type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	IsAdmin      bool   `json:"is_admin"`
	CreatedAt    int64  `json:"created_at"`
	ExpiresAt    int64  `json:"expires_at,omitempty"` // 0 = never
	PasswordHash string `json:"-"`
	ArgonSalt    string `json:"-"`
}

// Permission granted to a user for a specific resource+action pair.
type Permission struct {
	UserID   int64  `json:"user_id"`
	Resource string `json:"resource"` // "totp" | "safe" | "backup"
	Action   string `json:"action"`   // "read" | "write" | "delete"
	Allowed  bool   `json:"allowed"`
}

// Full permission set for a user — used in admin API and /me endpoint
type UserPermissions struct {
	Totp   ResourcePerms `json:"totp"`
	Safe   ResourcePerms `json:"safe"`
	Backup ResourcePerms `json:"backup"`
	SSH    ResourcePerms `json:"ssh"`

	// Granular per-folder overrides. Key = folder ID as decimal string.
	// If a folder key is missing, the section-level Safe permission applies.
	// set read/write/delete false to explicitly deny even when Safe allows it.
	FolderPerms map[string]ResourcePerms `json:"folder_perms,omitempty"`

	// Granular per-TOTP-entry overrides. Key = TOTP ID as decimal string.
	TotpPerms map[string]ResourcePerms `json:"totp_perms,omitempty"`
}

type ResourcePerms struct {
	Read   bool `json:"read"`
	Write  bool `json:"write"`
	Delete bool `json:"delete"`
	Export bool `json:"export"`
	Import bool `json:"import"`
}

// ------ Admin API request/response models ------

type CreateUserRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	IsAdmin  bool   `json:"is_admin"`
}

type UpdateUserRequest struct {
	Password string `json:"password,omitempty"` // empty = don't change
	IsAdmin  bool   `json:"is_admin"`
}

type UserResponse struct {
	ID        int64           `json:"id"`
	Username  string          `json:"username"`
	IsAdmin   bool            `json:"is_admin"`
	CreatedAt int64           `json:"created_at"`
	Perms     UserPermissions `json:"permissions"`
}

// ------ /me endpoint ------

type MeResponse struct {
	Username string          `json:"username"`
	IsAdmin  bool            `json:"is_admin"`
	Perms    UserPermissions `json:"permissions"`
}

// ------ extended Login ------

type LoginRequestV2 struct {
	Username string `json:"username"` // optional, defaults to "admin"
	Password string `json:"password"`
}

type LoginResponseV2 struct {
	Token    string          `json:"token"`
	Username string          `json:"username"`
	IsAdmin  bool            `json:"is_admin"`
	Perms    UserPermissions `json:"permissions"`
}
