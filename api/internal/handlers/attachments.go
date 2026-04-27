package handlers

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// GET /api/v1/attachments?record_id=X — list attachments for a record
func ListAttachments(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "safe", "read") {
		return
	}
	ridStr := r.URL.Query().Get("record_id")
	rid, err := strconv.ParseInt(ridStr, 10, 64)
	if err != nil || rid <= 0 {
		jsonError(w, "record_id required", http.StatusBadRequest)
		return
	}
	list, err := db.GetAttachmentsByRecord(rid)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, list)
}

// GET /api/v1/attachments/:id/data — download decrypted attachment
func GetAttachmentDataHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "safe", "read") {
		return
	}
	// Path: /api/v1/attachments/:id/data
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/attachments/")
	path = strings.TrimSuffix(path, "/data")
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	att, rawData, err := db.GetAttachmentData(id)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if att == nil {
		jsonError(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", att.MimeType)
	w.Header().Set("Content-Disposition", "attachment; filename="+att.Name)
	w.Write(rawData) //nolint:errcheck
}

// POST /api/v1/attachments — upload an attachment
// Body: JSON { record_id, name, mime_type, data: "<base64>" }
func UploadAttachment(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	var req struct {
		RecordID int64  `json:"record_id"`
		Name     string `json:"name"`
		MimeType string `json:"mime_type"`
		Data     string `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if req.RecordID <= 0 || req.Name == "" || req.Data == "" {
		jsonError(w, "record_id, name and data are required", http.StatusBadRequest)
		return
	}
	rawData, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		jsonError(w, "data must be base64 encoded", http.StatusBadRequest)
		return
	}
	if len(rawData) > 10*1024*1024 {
		jsonError(w, "attachment too large (max 10 MB)", http.StatusRequestEntityTooLarge)
		return
	}
	mime := req.MimeType
	if mime == "" {
		mime = "application/octet-stream"
	}
	a := &models.Attachment{
		RecordID: req.RecordID,
		Name:     req.Name,
		MimeType: mime,
	}
	id, err := db.InsertAttachment(a, rawData)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]int64{"id": id})
}

// DELETE /api/v1/attachments/:id
func DeleteAttachmentHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "safe", "delete") {
		return
	}
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/attachments/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	if err := db.DeleteAttachment(id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"message": "deleted"})
}

