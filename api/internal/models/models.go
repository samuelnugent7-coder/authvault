package models

// ------ TOTP ------

type TOTPEntry struct {
	ID        int64    `json:"id"`
	Name      string   `json:"name"`
	Issuer    string   `json:"issuer"`
	Secret    string   `json:"secret"`  // stored encrypted, returned decrypted to authed client
	Duration  int      `json:"duration"` // seconds (default 30)
	Length    int      `json:"length"`   // digits (default 6)
	HashAlgo  int      `json:"hash_algo"` // 0=SHA1, 1=SHA256, 2=SHA512
	Tags      []string `json:"tags,omitempty"`
	CreatedAt int64    `json:"created_at"`
}

type TOTPImportEntry struct {
	Name      string `json:"Name"`
	Issuer    string `json:"Issuer"`
	Secret    string `json:"Secret"`
	Duration  int    `json:"Duration"`
	Length    int    `json:"Length"`
	HashAlgo  int    `json:"HashAlgo"`
}

// ------ SAFE ------

type SafeFolder struct {
	ID       int64        `json:"id"`
	Name     string       `json:"name"`
	ParentID *int64       `json:"parent_id,omitempty"`
	Children []SafeFolder `json:"children,omitempty"`
	Records  []SafeRecord `json:"records,omitempty"`
}

type SafeRecord struct {
	ID        int64       `json:"id"`
	FolderID  int64       `json:"folder_id"`
	Name      string      `json:"name"`
	Login     string      `json:"login,omitempty"`
	Password  string      `json:"password,omitempty"`
	Items     []SafeItem  `json:"items,omitempty"`
	CreatedAt int64       `json:"created_at,omitempty"`
}

type SafeItem struct {
	ID       int64  `json:"id"`
	RecordID int64  `json:"record_id"`
	Name     string `json:"name"`
	Content  string `json:"content"`
}

// ------ XML Import/Export ------

type XMLRoot struct {
	Name    string      `xml:"name"`
	Folders []XMLFolder `xml:"folder"`
	Records []XMLRecord `xml:"record"`
}

type XMLFolder struct {
	Name    string      `xml:"name"`
	Folders []XMLFolder `xml:"folder"`
	Records []XMLRecord `xml:"record"`
}

type XMLRecord struct {
	Name     string    `xml:"name"`
	Login    string    `xml:"login,omitempty"`
	Password string    `xml:"password,omitempty"`
	Items    []XMLItem `xml:"item"`
}

type XMLItem struct {
	Name    string `xml:"name"`
	Content string `xml:"content"`
}

// ------ API responses ------

type LoginRequest struct {
	Password string `json:"password"`
}

type LoginResponse struct {
	Token string `json:"token"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

type StatusResponse struct {
	Unlocked bool   `json:"unlocked"`
	Message  string `json:"message,omitempty"`
}
