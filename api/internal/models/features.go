package models

// ── Audit Log ───────────────────────────────────────────────────────────────

// AuditEvent constants
const (
	AuditLogin                = "login"
	AuditLoginFailed          = "login_failed"
	AuditLogout               = "logout"
	AuditVaultUnlock          = "vault_unlock"
	AuditBackupRestore        = "backup_restore"
	AuditBackupUpload         = "backup_upload"
	AuditAPIAccess            = "api_access"
	AuditNewIP                = "new_ip_detected"
	AuditSessionRevoke        = "session_revoked"
	AuditUserCreated          = "user_created"
	AuditUserDeleted          = "user_deleted"
	AuditPermsChanged         = "permissions_changed"
	AuditFingerprintMismatch  = "fingerprint_mismatch"
	AuditSnapshotCreated      = "snapshot_created"
	AuditSnapshotRestored     = "snapshot_restored"
)

type AuditLog struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"user_id"`
	Username  string `json:"username"`
	Event     string `json:"event"`
	IP        string `json:"ip"`
	Device    string `json:"device"`
	Details   string `json:"details"`
	CreatedAt int64  `json:"created_at"`
}

// ── Sessions ─────────────────────────────────────────────────────────────────

type Session struct {
	ID         int64  `json:"id"`
	UserID     int64  `json:"user_id"`
	Username   string `json:"username"`
	TokenHash  string `json:"-"`
	Device     string `json:"device"`
	IP         string `json:"ip"`
	CreatedAt  int64  `json:"created_at"`
	LastSeen   int64  `json:"last_seen"`
	Revoked    bool   `json:"revoked"`
	FpFlagged  bool   `json:"fp_flagged"`
}

// ── SSH Keys ─────────────────────────────────────────────────────────────────

type SSHKey struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	PublicKey  string `json:"public_key"`
	PrivateKey string `json:"private_key,omitempty"` // plaintext only in API response
	Comment    string `json:"comment"`
	CreatedAt  int64  `json:"created_at"`
}

// ── Attachments ──────────────────────────────────────────────────────────────

type Attachment struct {
	ID        int64  `json:"id"`
	RecordID  int64  `json:"record_id"`
	Name      string `json:"name"`
	MimeType  string `json:"mime_type"`
	SizeBytes int64  `json:"size_bytes"`
	Data      string `json:"data,omitempty"` // base64 plaintext, only on fetch
	CreatedAt int64  `json:"created_at"`
}

// ── Password Health ───────────────────────────────────────────────────────────

type PasswordHealthResult struct {
	RecordID   int64    `json:"record_id"`
	RecordName string   `json:"record_name"`
	FolderName string   `json:"folder_name"`
	Issues     []string `json:"issues"` // "weak","reused","old","breached"
	Strength   int      `json:"strength"` // 0-100
}

type PasswordHealthReport struct {
	ScannedAt     int64                  `json:"scanned_at"`
	TotalItems    int                    `json:"total_items"`
	IssueCount    int                    `json:"issue_count"`
	WeakCount     int                    `json:"weak_count"`
	ReusedCount   int                    `json:"reused_count"`
	OldCount      int                    `json:"old_count"`
	BreachedCount int                    `json:"breached_count"`
	Results       []PasswordHealthResult `json:"results"`
}

// ── Recycle Bin ──────────────────────────────────────────────────────────────

type RecycleBinEntry struct {
	ID          int64  `json:"id"`
	ItemType    string `json:"item_type"` // "record" | "folder" | "note"
	OriginalID  int64  `json:"original_id"`
	FolderID    int64  `json:"folder_id"`
	DataEnc     string `json:"-"`         // encrypted JSON snapshot
	Name        string `json:"name"`      // decrypted for display
	DeletedAt   int64  `json:"deleted_at"`
	DeletedBy   string `json:"deleted_by"`
	ExpiresAt   int64  `json:"expires_at"`
}

// ── Password History ──────────────────────────────────────────────────────────

type PasswordHistoryEntry struct {
	ID         int64  `json:"id"`
	RecordID   int64  `json:"record_id"`
	RecordName string `json:"record_name,omitempty"`
	OldPass    string `json:"old_pass"` // decrypted on read
	ChangedAt  int64  `json:"changed_at"`
	ChangedBy  string `json:"changed_by"`
}

// ── Secure Notes ──────────────────────────────────────────────────────────────

type SecureNote struct {
	ID        int64    `json:"id"`
	Title     string   `json:"title"`
	Content   string   `json:"content"`
	Tags      []string `json:"tags,omitempty"`
	CreatedAt int64    `json:"created_at"`
	UpdatedAt int64    `json:"updated_at"`
}

// ── Tags / Labels ─────────────────────────────────────────────────────────────

type Tag struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color"` // hex e.g. "#e53935"
	CreatedAt int64  `json:"created_at"`
}

// ── Shared Folders ────────────────────────────────────────────────────────────

type FolderShare struct {
	FolderID  int64  `json:"folder_id"`
	UserID    int64  `json:"user_id"`
	Username  string `json:"username,omitempty"`
	CanWrite  bool   `json:"can_write"`
	GrantedBy string `json:"granted_by"`
	GrantedAt int64  `json:"granted_at"`
}

// ── API Keys ──────────────────────────────────────────────────────────────────

type APIKey struct {
	ID          int64  `json:"id"`
	UserID      int64  `json:"user_id"`
	Name        string `json:"name"`
	KeyPrefix   string `json:"key_prefix"`      // first 8 chars of key for display
	KeyFull     string `json:"key,omitempty"`   // only returned on creation
	CreatedAt   int64  `json:"created_at"`
	LastUsedAt  int64  `json:"last_used_at"`
	ExpiresAt   int64  `json:"expires_at"`       // 0 = never
	Revoked     bool   `json:"revoked"`
}

// ── Share Links ───────────────────────────────────────────────────────────────

type ShareLink struct {
	ID        int64  `json:"id"`
	Token     string `json:"token,omitempty"` // full token on creation only
	RecordID  int64  `json:"record_id"`
	OneTime   bool   `json:"one_time"`
	ExpiresAt int64  `json:"expires_at"`
	UsedAt    int64  `json:"used_at"`
	CreatedBy string `json:"created_by"`
	CreatedAt int64  `json:"created_at"`
}

// ── Record Versions ───────────────────────────────────────────────────────────

type RecordVersion struct {
	ID          int64  `json:"id"`
	RecordID    int64  `json:"record_id"`
	VersionNum  int    `json:"version_num"`
	Name        string `json:"name"`
	Login       string `json:"login"`
	Password    string `json:"password"`
	ItemsJSON   string `json:"items_json"`
	ChangedAt   int64  `json:"changed_at"`
	ChangedBy   string `json:"changed_by"`
}

// ── Vault Dashboard ───────────────────────────────────────────────────────────

type DashboardStats struct {
	TotalRecords   int     `json:"total_records"`
	TotalTOTP      int     `json:"total_totp"`
	TotalSSH       int     `json:"total_ssh"`
	TotalNotes     int     `json:"total_notes"`
	TotalTags      int     `json:"total_tags"`
	TotalAPIKeys   int     `json:"total_api_keys"`
	ActiveSessions int     `json:"active_sessions"`
	HealthScore    float64 `json:"health_score"`    // 0-100
	RecycleBinSize int     `json:"recycle_bin_size"`
	SharedFolders  int     `json:"shared_folders"`
	DBSizeBytes    int64   `json:"db_size_bytes"`
	RecentAudit    []AuditLog `json:"recent_audit"`
}

// ── Email Config ──────────────────────────────────────────────────────────────

type EmailConfig struct {
	Enabled    bool     `json:"enabled"`
	Provider   string   `json:"provider"` // "smtp" | "ses"
	SMTPHost   string   `json:"smtp_host"`
	SMTPPort   int      `json:"smtp_port"`
	SMTPUser   string   `json:"smtp_user"`
	SMTPPass   string   `json:"smtp_pass,omitempty"` // omitted in GET
	SMTPTLS    bool     `json:"smtp_tls"`
	SESKeyID   string   `json:"ses_key_id,omitempty"`
	SESSecret  string   `json:"ses_secret,omitempty"`
	SESRegion  string   `json:"ses_region,omitempty"`
	FromAddr   string   `json:"from_addr"`
	AlertTo    string   `json:"alert_to"`   // comma-separated
	Triggers   []string `json:"triggers"`
}

// ── Integrity Check ───────────────────────────────────────────────────────────

type IntegrityReport struct {
	CheckedAt     int64              `json:"checked_at"`
	TotalChecked  int                `json:"total_checked"`
	FailedCount   int                `json:"failed_count"`
	Failures      []IntegrityFailure `json:"failures"`
}

type IntegrityFailure struct {
	Table    string `json:"table"`
	ID       int64  `json:"id"`
	Field    string `json:"field"`
	Error    string `json:"error"`
}

// ── CSV Import ────────────────────────────────────────────────────────────────

type CSVImportResult struct {
	Format   string   `json:"format"`
	Created  int      `json:"created"`
	Skipped  int      `json:"skipped"`
	Errors   []string `json:"errors"`
}

// ── New Audit Constants ───────────────────────────────────────────────────────

const (
	AuditRecycleDelete   = "recycle_delete"
	AuditRecycleRestore  = "recycle_restore"
	AuditShareLinkCreate = "share_link_create"
	AuditShareLinkView   = "share_link_view"
	AuditAPIKeyCreated   = "api_key_created"
	AuditAPIKeyRevoked   = "api_key_revoked"
	AuditDuressLogin     = "duress_login"
	AuditIntegrityCheck  = "integrity_check"
	AuditEmailAlertSent  = "email_alert_sent"
)

// ── Snapshots ─────────────────────────────────────────────────────────────────

type Snapshot struct {
	ID          int64  `json:"id"`
	Type        string `json:"type"`       // "full" or "incremental"
	BaseID      int64  `json:"base_id"`    // 0 for full snapshots
	FileName    string `json:"file_name"`
	SizeBytes   int64  `json:"size_bytes"`
	RecordCount int    `json:"record_count"`
	S3Uploaded  bool   `json:"s3_uploaded"`
	CreatedAt   int64  `json:"created_at"`
}

// ── Backup Health ─────────────────────────────────────────────────────────────

type BackupHealth struct {
	LastSuccessAt  int64  `json:"last_success_at"`
	QueueDepth     int    `json:"queue_depth"`
	TotalFailed    int    `json:"total_failed"`
	NextRetryAt    int64  `json:"next_retry_at,omitempty"`
	LastError      string `json:"last_error,omitempty"`
	S3Enabled      bool   `json:"s3_enabled"`
	SnapshotCount  int    `json:"snapshot_count"`
	TotalSizeBytes int64  `json:"total_size_bytes"`
}
