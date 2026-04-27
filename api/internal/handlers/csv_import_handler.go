package handlers

import (
	"encoding/csv"
	"encoding/json"
	"net/http"
	"strings"

	"authvault/api/internal/db"
	"authvault/api/internal/models"
)

// CSVImport handles POST /api/v1/import/csv?format=bitwarden|1password|lastpass|generic
func CSVImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	format := strings.ToLower(r.URL.Query().Get("format"))
	if format == "" {
		format = "generic"
	}

	if err := r.ParseMultipartForm(10 << 20); err != nil {
		// Fall back to raw body
	}

	var reader *csv.Reader
	file, _, err := r.FormFile("file")
	if err != nil {
		// Try reading raw body as CSV
		reader = csv.NewReader(r.Body)
	} else {
		defer file.Close()
		reader = csv.NewReader(file)
	}

	records, err := reader.ReadAll()
	if err != nil {
		http.Error(w, `{"error":"invalid CSV"}`, http.StatusBadRequest)
		return
	}

	result, err := importCSV(format, records)
	if err != nil {
		http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func importCSV(format string, rows [][]string) (*models.CSVImportResult, error) {
	result := &models.CSVImportResult{Format: format}
	if len(rows) < 2 {
		return result, nil
	}

	header := rows[0]
	colIdx := map[string]int{}
	for i, h := range header {
		colIdx[strings.ToLower(strings.TrimSpace(h))] = i
	}

	// Ensure an import folder exists
	folderID, _ := db.InsertFolder("CSV Import", nil)

	get := func(row []string, keys ...string) string {
		for _, k := range keys {
			if i, ok := colIdx[k]; ok && i < len(row) {
				return strings.TrimSpace(row[i])
			}
		}
		return ""
	}

	for _, row := range rows[1:] {
		if len(row) == 0 {
			continue
		}

		var name, username, password, url, notes, folder string

		switch format {
		case "bitwarden":
			name = get(row, "name")
			username = get(row, "login_username")
			password = get(row, "login_password")
			url = get(row, "login_uri")
			notes = get(row, "notes")
			folder = get(row, "folder")

		case "1password":
			name = get(row, "title")
			username = get(row, "username")
			password = get(row, "password")
			url = get(row, "url", "website")
			notes = get(row, "notes", "notesplain")
			folder = get(row, "vault")

		case "lastpass":
			name = get(row, "name")
			username = get(row, "username")
			password = get(row, "password")
			url = get(row, "url")
			notes = get(row, "extra")
			folder = get(row, "grouping")

		default: // generic: name,username,password,url,notes
			name = get(row, "name", "title", "account")
			username = get(row, "username", "user", "login", "email")
			password = get(row, "password", "pass")
			url = get(row, "url", "website", "uri")
			notes = get(row, "notes", "note", "comment")
			folder = get(row, "folder", "group", "category")
		}

		if name == "" {
			result.Skipped++
			continue
		}

		// Resolve folder
		fID := folderID
		if folder != "" {
			found, _ := db.FindOrCreateFolder(folder, nil)
			if found > 0 {
				fID = found
			}
		}

		rec := &models.SafeRecord{
			FolderID: fID,
			Name:     name,
			Login:    username,
			Password: password,
		}
		if url != "" {
			rec.Items = append(rec.Items, models.SafeItem{Name: "URL", Content: url})
		}
		if notes != "" {
			rec.Items = append(rec.Items, models.SafeItem{Name: "Notes", Content: notes})
		}

		if _, err := db.InsertRecord(rec); err != nil {
			result.Errors = append(result.Errors, "row "+name+": "+err.Error())
		} else {
			result.Created++
		}
	}
	return result, nil
}
