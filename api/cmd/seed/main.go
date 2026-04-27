// Seed tool – injects test TOTP + safe entries via the live API.
// Usage: go run ./cmd/seed --pass 123456
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
)

var base = "http://localhost:8443"

func main() {
	pass := flag.String("pass", "123456", "admin password")
	flag.Parse()

	tok := login(*pass)
	fmt.Println("Logged in OK")

	seedTOTP(tok)
	seedSafe(tok)
	fmt.Println("All done")
}

func login(pass string) string {
	body := map[string]any{"username": "admin", "password": pass}
	res := postJ("/api/v1/auth/login", "", body)
	tok, ok := res["token"].(string)
	if !ok || tok == "" {
		log.Fatalf("login failed: %v", res)
	}
	return tok
}

func seedTOTP(tok string) {
	// hash_algo: 0=SHA1, 1=SHA256, 2=SHA512
	type totpEntry struct {
		Name     string `json:"name"`
		Issuer   string `json:"issuer"`
		Secret   string `json:"secret"`
		Duration int    `json:"duration"`
		Length   int    `json:"length"`
		HashAlgo int    `json:"hash_algo"`
	}
	entries := []totpEntry{
		{"GitHub", "GitHub", "JBSWY3DPEHPK3PXP", 30, 6, 0},
		{"Google", "Google", "JBSWY3DPEHPK3PXQ", 30, 6, 0},
		{"Discord", "Discord", "KRUGKIDROVUWG2ZA", 30, 6, 0},
		{"Cloudflare", "Cloudflare", "MFRGGZDFMZTWQ2LK", 30, 6, 0},
		{"AWS Root", "Amazon", "NBSWY3DPFQQGK3TF", 30, 8, 1},
		{"ProtonMail", "Proton", "ORSXG5BRGIXTCMI=", 30, 6, 0},
		{"Microsoft", "Microsoft", "GEZDGNBVGY3TQOJQ", 30, 6, 0},
		{"Bitwarden", "Bitwarden", "HEZDGNBVGY3TQOLQ", 30, 6, 0},
	}
	for _, e := range entries {
		r := postJ("/api/v1/totp", tok, e)
		fmt.Printf("  TOTP  %-15s id=%v\n", e.Name, r["id"])
	}
}

func seedSafe(tok string) {
	type folder struct {
		Name     string `json:"name"`
		ParentID *int64 `json:"parent_id,omitempty"`
	}
	type record struct {
		FolderID int64  `json:"folder_id"`
		Name     string `json:"name"`
		Login    string `json:"login,omitempty"`
		Password string `json:"password,omitempty"`
	}

	personalR := postJ("/api/v1/safe/folders", tok, folder{Name: "Personal"})
	personalID := int64(personalR["id"].(float64))
	fmt.Printf("  Folder Personal id=%d\n", personalID)

	workR := postJ("/api/v1/safe/folders", tok, folder{Name: "Work"})
	workID := int64(workR["id"].(float64))
	fmt.Printf("  Folder Work     id=%d\n", workID)

	socialR := postJ("/api/v1/safe/folders", tok, folder{Name: "Social", ParentID: &personalID})
	socialID := int64(socialR["id"].(float64))
	fmt.Printf("  Folder Social   id=%d\n", socialID)

	records := []record{
		{personalID, "Gmail", "myemail@gmail.com", "SuperSecret1!"},
		{personalID, "GitHub", "myuser", "GitHubPass99!"},
		{personalID, "Netflix", "myemail@gmail.com", "Netflix2026!"},
		{personalID, "WiFi Home", "admin", "HomeWifi2026!"},
		{socialID, "Twitter / X", "myuser", "Twitter2026!"},
		{socialID, "Reddit", "myuser", "Reddit2026#"},
		{workID, "AWS Console", "admin@company.com", "AwsR00t!Secure"},
		{workID, "Cloudflare", "admin@company.com", "CF_Work2026#"},
		{workID, "SSH Passphrase", "", "my-ssh-passphrase-123"},
		{workID, "VPN", "myuser", "VPN_Pass2026!"},
	}
	for _, rec := range records {
		r := postJ("/api/v1/safe/records", tok, rec)
		fmt.Printf("  Record %-20s id=%v\n", rec.Name, r["id"])
	}
}

func postJ(path, tok string, body any) map[string]any {
	b, err := json.Marshal(body)
	if err != nil {
		log.Fatalf("marshal: %v", err)
	}
	req, _ := http.NewRequest("POST", base+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("POST %s: %v", path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	json.Unmarshal(raw, &out)
	if resp.StatusCode >= 400 {
		log.Fatalf("POST %s -> %d: %s", path, resp.StatusCode, raw)
	}
	return out
}
