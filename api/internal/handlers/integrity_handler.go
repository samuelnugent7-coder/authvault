package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"authvault/api/internal/crypto"
	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// IntegrityCheck handles POST /api/v1/admin/integrity
func IntegrityCheck(w http.ResponseWriter, r *http.Request) {
	uid, username, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		http.Error(w, `{"error":"admin only"}`, http.StatusForbidden)
		return
	}

	report := models.IntegrityReport{CheckedAt: time.Now().Unix()}

	// Helper to try decrypt
	tryDec := func(table, field string, id int64, enc string) {
		report.TotalChecked++
		if _, err := crypto.Decrypt(enc); err != nil {
			report.FailedCount++
			report.Failures = append(report.Failures, models.IntegrityFailure{
				Table: table, ID: id, Field: field, Error: err.Error(),
			})
		}
	}

	// Check TOTP secrets
	totps, _ := db.AllTOTPRaw(0)
	for _, t := range totps {
		tryDec("totp_entries", "secret_enc", t.ID, t.SecretEnc)
	}

	// Check safe records
	records, _ := db.AllRecordsRaw(0)
	for _, r := range records {
		tryDec("safe_records", "name_enc", r.ID, r.NameEnc)
		tryDec("safe_records", "login_enc", r.ID, r.LoginEnc)
		tryDec("safe_records", "pass_enc", r.ID, r.PassEnc)
	}

	// Check safe items
	items, _ := db.AllItemsRaw(0)
	for _, i := range items {
		tryDec("safe_items", "name_enc", i.ID, i.NameEnc)
		tryDec("safe_items", "content_enc", i.ID, i.ContentEnc)
	}

	// Check SSH keys
	sshKeys, _ := db.AllSSHKeysRaw(0)
	for _, k := range sshKeys {
		tryDec("ssh_keys", "pub_enc", k.ID, k.PublicKeyEnc)
		tryDec("ssh_keys", "priv_enc", k.ID, k.PrivateKeyEnc)
		tryDec("ssh_keys", "comment_enc", k.ID, k.CommentEnc)
	}

	// Check secure notes
	notes, _ := db.AllSecureNotesRaw(0)
	for _, n := range notes {
		tryDec("secure_notes", "title_enc", n.ID, n.TitleEnc)
		tryDec("secure_notes", "content_enc", n.ID, n.ContentEnc)
	}

	if report.Failures == nil {
		report.Failures = []models.IntegrityFailure{}
	}

	details := "ok"
	if report.FailedCount > 0 {
		details = "FAILURES detected"
	}
	db.LogAudit(uid, username, "integrity_check", "", "", details)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(report)
}
