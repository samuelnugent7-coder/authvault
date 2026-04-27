package middleware

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

type contextKey string

const ClaimsKey contextKey = "claims"

// fingerprintDB is an interface satisfied by db.GetSessionFingerprint and db.IsRevoked.
// We use function variables so the middleware doesn't import the db package directly
// (avoiding circular imports — handlers also import middleware).
var (
	IsRevokedFn            func(token string) bool
	GetSessionFingerprintFn func(token string) string
	FlagSessionFingerprintFn func(token string)
	LogFingerprintMismatchFn func(userID int64, username, ip, device, details string)
)

// JWT wraps a handler requiring a valid Bearer JWT signed with the given secret.
func JWT(secret string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			http.Error(w, `{"error":"missing token"}`, http.StatusUnauthorized)
			return
		}
		tokenStr := strings.TrimPrefix(header, "Bearer ")
		token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
			if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, jwt.ErrSignatureInvalid
			}
			return []byte(secret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !token.Valid {
			http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
			return
		}

		// Revocation check (non-blocking on DB error)
		if IsRevokedFn != nil && IsRevokedFn(tokenStr) {
			http.Error(w, `{"error":"session revoked"}`, http.StatusUnauthorized)
			return
		}

		// Device fingerprint check — flag but never block
		if GetSessionFingerprintFn != nil && FlagSessionFingerprintFn != nil {
			storedFP := GetSessionFingerprintFn(tokenStr)
			if storedFP != "" {
				// Compute current request fingerprint
				ua   := r.Header.Get("User-Agent")
				lang := r.Header.Get("Accept-Language")
				enc  := r.Header.Get("Accept-Encoding")
				raw  := fmt.Sprintf("%s|%s|%s", ua, lang, enc)
				h    := sha256.Sum256([]byte(raw))
				currentFP := fmt.Sprintf("%x", h)
				if currentFP != storedFP {
					FlagSessionFingerprintFn(tokenStr)
					// Log audit event via the function hook (populated by main)
					if LogFingerprintMismatchFn != nil {
						claims, _ := token.Claims.(jwt.MapClaims)
						var uid int64
						var uname string
						if v, ok := claims["uid"]; ok {
							if f, ok := v.(float64); ok {
								uid = int64(f)
							}
						}
						if v, ok := claims["username"]; ok {
							uname, _ = v.(string)
						}
						ip := r.RemoteAddr
						if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
							ip = strings.Split(fwd, ",")[0]
						}
						LogFingerprintMismatchFn(uid, uname, ip, r.UserAgent(),
							fmt.Sprintf("stored=%s current=%s", storedFP[:8], currentFP[:8]))
					}
				}
			}
		}

		ctx := context.WithValue(r.Context(), ClaimsKey, token.Claims)
		next(w, r.WithContext(ctx))
	}
}

// ClaimsFromContext extracts JWT MapClaims from the request context.
func ClaimsFromContext(r *http.Request) jwt.MapClaims {
	c, _ := r.Context().Value(ClaimsKey).(jwt.MapClaims)
	return c
}

// UserFromContext extracts userID, username, isAdmin from the JWT claims.
func UserFromContext(r *http.Request) (userID int64, username string, isAdmin bool) {
	c := ClaimsFromContext(r)
	if c == nil {
		return 0, "", false
	}
	if v, ok := c["uid"]; ok {
		switch x := v.(type) {
		case float64:
			userID = int64(x)
		}
	}
	if v, ok := c["username"]; ok {
		username, _ = v.(string)
	}
	if v, ok := c["admin"]; ok {
		isAdmin, _ = v.(bool)
	}
	return
}
