package handlers

import (
	"bufio"
	"crypto/sha1" //nolint:gosec
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// GET /api/v1/health/passwords?hibp=true
// Scans all safe records for password health issues.
func PasswordHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requirePerm(w, r, "safe", "read") {
		return
	}
	checkHIBP := r.URL.Query().Get("hibp") == "true"

	// Load all folder/record trees
	tree, err := db.GetFolderTree()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Flatten all records with folder names
	type record struct {
		id         int64
		name       string
		folderName string
		password   string
		createdAt  int64
	}
	var allRecords []record
	var walkFolder func(f models.SafeFolder, parentName string)
	walkFolder = func(f models.SafeFolder, parentName string) {
		name := f.Name
		if parentName != "" {
			name = parentName + " / " + f.Name
		}
		for _, rec := range f.Records {
			allRecords = append(allRecords, record{
				id:         rec.ID,
				name:       rec.Name,
				folderName: name,
				password:   rec.Password,
				createdAt:  rec.CreatedAt,
			})
		}
		for _, child := range f.Children {
			walkFolder(child, name)
		}
	}
	for _, f := range tree {
		walkFolder(f, "")
	}

	// Build reuse map: password → count
	passCount := map[string]int{}
	for _, rec := range allRecords {
		if rec.password != "" {
			passCount[rec.password]++
		}
	}

	// Prepare HIBP lookup cache
	hibpCache := map[string]bool{} // sha1hex → breached

	now := time.Now().Unix()
	ninetyDays := int64(90 * 24 * 3600)

	var results []models.PasswordHealthResult
	weak, reused, old, breached := 0, 0, 0, 0

	for _, rec := range allRecords {
		var issues []string
		strength := passwordStrength(rec.password)

		if strength < 40 {
			issues = append(issues, "weak")
			weak++
		}
		if passCount[rec.password] > 1 {
			issues = append(issues, "reused")
			reused++
		}
		if rec.createdAt > 0 && (now-rec.createdAt) > ninetyDays {
			issues = append(issues, "old")
			old++
		}
		if checkHIBP && rec.password != "" {
			if isBreached, ok := hibpCache[rec.password]; ok {
				if isBreached {
					issues = append(issues, "breached")
					breached++
				}
			} else {
				count, err := hibpCheck(rec.password)
				if err == nil {
					hibpCache[rec.password] = count > 0
					if count > 0 {
						issues = append(issues, "breached")
						breached++
					}
				}
			}
		}

		if len(issues) > 0 {
			results = append(results, models.PasswordHealthResult{
				RecordID:   rec.id,
				RecordName: rec.name,
				FolderName: rec.folderName,
				Issues:     issues,
				Strength:   strength,
			})
		}
	}
	if results == nil {
		results = []models.PasswordHealthResult{}
	}

	report := models.PasswordHealthReport{
		ScannedAt:     now,
		TotalItems:    len(allRecords),
		IssueCount:    len(results),
		WeakCount:     weak,
		ReusedCount:   reused,
		OldCount:      old,
		BreachedCount: breached,
		Results:       results,
	}
	jsonOK(w, report)
}

// passwordStrength scores a password 0-100.
func passwordStrength(pw string) int {
	if pw == "" {
		return 0
	}
	score := 0
	length := len(pw)

	// Length scoring
	switch {
	case length >= 20:
		score += 40
	case length >= 16:
		score += 35
	case length >= 12:
		score += 25
	case length >= 8:
		score += 15
	default:
		score += 5
	}

	// Character variety
	var hasUpper, hasLower, hasDigit, hasSpecial bool
	for _, ch := range pw {
		switch {
		case unicode.IsUpper(ch):
			hasUpper = true
		case unicode.IsLower(ch):
			hasLower = true
		case unicode.IsDigit(ch):
			hasDigit = true
		default:
			hasSpecial = true
		}
	}
	if hasUpper {
		score += 15
	}
	if hasLower {
		score += 10
	}
	if hasDigit {
		score += 15
	}
	if hasSpecial {
		score += 20
	}

	if score > 100 {
		score = 100
	}
	return score
}

// hibpCheck queries the HaveIBeenPwned k-anonymity API.
// Returns the number of times the password appears in known breaches.
func hibpCheck(password string) (int, error) {
	//nolint:gosec
	h := sha1.Sum([]byte(password))
	full := fmt.Sprintf("%X", h)
	prefix := full[:5]
	suffix := full[5:]

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("https://api.pwnedpasswords.com/range/" + prefix)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		if strings.EqualFold(parts[0], suffix) {
			count := 0
			fmt.Sscanf(parts[1], "%d", &count)
			return count, nil
		}
	}
	return 0, scanner.Err()
}
