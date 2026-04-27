package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"authvault/api/internal/db"
)

// GetTOTPQR handles GET /api/v1/totp/:id/qr — returns the otpauth:// URI to display as QR.
func GetTOTPQR(w http.ResponseWriter, r *http.Request) {
	// Path: /api/v1/totp/:id/qr
	trimmed := strings.TrimSuffix(r.URL.Path, "/qr")
	idStr := trimmed[strings.LastIndex(trimmed, "/")+1:]
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}
	entry, err := db.GetTOTP(id)
	if err != nil || entry == nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	// Build otpauth://totp/<label>?secret=<>&issuer=<>&digits=<>&period=<>
	label := entry.Issuer
	if label == "" {
		label = entry.Name
	}
	if entry.Name != "" && label != entry.Name {
		label = fmt.Sprintf("%s:%s", label, entry.Name)
	}
	label = url.PathEscape(label)

	uri := fmt.Sprintf("otpauth://totp/%s?secret=%s&issuer=%s&digits=%d&period=%d",
		label,
		url.QueryEscape(entry.Secret),
		url.QueryEscape(entry.Issuer),
		entry.Length,
		entry.Duration,
	)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"uri": uri})
}
