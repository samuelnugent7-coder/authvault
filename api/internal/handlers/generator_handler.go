package handlers

import (
	"crypto/rand"
	"encoding/json"
	"math/big"
	"net/http"
	"strconv"
)

const (
	charsetLower   = "abcdefghijkmnopqrstuvwxyz"
	charsetUpper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
	charsetDigits  = "23456789"
	charsetSymbols = "!@#$%^&*()-_=+[]{}|;:,.<>?"
	charsetAmbig   = "lI1O0o" // characters excluded with no_ambiguous
)

type GeneratorRequest struct {
	Length       int  `json:"length"`
	Uppercase    bool `json:"uppercase"`
	Digits       bool `json:"digits"`
	Symbols      bool `json:"symbols"`
	NoAmbiguous  bool `json:"no_ambiguous"`
}

type GeneratorResponse struct {
	Password string `json:"password"`
	Strength int    `json:"strength"`
}

// GeneratePassword handles POST /api/v1/generator.
func GeneratePassword(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	var req GeneratorRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid body"}`, http.StatusBadRequest)
		return
	}
	if req.Length < 4 {
		req.Length = 16
	}
	if req.Length > 128 {
		req.Length = 128
	}

	charset := charsetLower
	if req.Uppercase {
		charset += charsetUpper
	}
	if req.Digits {
		charset += charsetDigits
	}
	if req.Symbols {
		charset += charsetSymbols
	}
	if req.NoAmbiguous {
		filtered := ""
		for _, c := range charset {
			isAmbig := false
			for _, a := range charsetAmbig {
				if c == a {
					isAmbig = true
					break
				}
			}
			if !isAmbig {
				filtered += string(c)
			}
		}
		charset = filtered
	}
	if charset == "" {
		charset = charsetLower + charsetDigits
	}

	pw := make([]byte, req.Length)
	for i := range pw {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			http.Error(w, `{"error":"rng failed"}`, http.StatusInternalServerError)
			return
		}
		pw[i] = charset[n.Int64()]
	}

	strength := scorePassword(string(pw))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(GeneratorResponse{Password: string(pw), Strength: strength})
}

func scorePassword(pw string) int {
	score := 0
	hasLower, hasUpper, hasDigit, hasSym := false, false, false, false
	for _, c := range pw {
		switch {
		case c >= 'a' && c <= 'z':
			hasLower = true
		case c >= 'A' && c <= 'Z':
			hasUpper = true
		case c >= '0' && c <= '9':
			hasDigit = true
		default:
			hasSym = true
		}
	}
	// Length score
	l := len(pw)
	switch {
	case l >= 20:
		score += 40
	case l >= 16:
		score += 30
	case l >= 12:
		score += 20
	case l >= 8:
		score += 10
	}
	// Variety score
	for _, b := range []bool{hasLower, hasUpper, hasDigit, hasSym} {
		if b {
			score += 15
		}
	}
	_ = strconv.Itoa(score)
	if score > 100 {
		score = 100
	}
	return score
}
