package handlers

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"

	"authvault/api/internal/db"
	"authvault/api/internal/middleware"
	"authvault/api/internal/models"
)

// GET /api/v1/safe
func GetSafe(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "read") {
		return
	}
	tree, err := db.GetFolderTree()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if tree == nil {
		tree = []models.SafeFolder{}
	}

	// For non-admin users apply per-folder read filtering
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin {
		tree = filterSafeTree(tree, uid)
	}

	jsonOK(w, tree)
}

// filterSafeTree removes folders the user is explicitly denied read access to.
// If no per-folder row exists the section-level allow is inherited.
func filterSafeTree(folders []models.SafeFolder, userID int64) []models.SafeFolder {
	var out []models.SafeFolder
	for _, f := range folders {
		if f.ID > 0 {
			res := fmt.Sprintf("safe:folder:%d", f.ID)
			if db.IsExplicitlyDenied(userID, res, "read") {
				continue
			}
		}
		f.Children = filterSafeTree(f.Children, userID)
		out = append(out, f)
	}
	return out
}

// ---- Folders ----

// POST /api/v1/safe/folders
func CreateFolder(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	var body struct {
		Name     string `json:"name"`
		ParentID *int64 `json:"parent_id,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	id, err := db.InsertFolder(body.Name, body.ParentID)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, map[string]int64{"id": id})
}

// PUT /api/v1/safe/folders/{id}
func UpdateFolder(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin && db.IsExplicitlyDenied(uid, fmt.Sprintf("safe:folder:%d", id), "write") {
		jsonError(w, "permission denied for this folder", http.StatusForbidden)
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	if err := db.UpdateFolder(id, body.Name); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"status": "ok"})
}

// DELETE /api/v1/safe/folders/{id}
func DeleteFolder(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	uid, username, isAdmin := middleware.UserFromContext(r)
	if !isAdmin && db.IsExplicitlyDenied(uid, fmt.Sprintf("safe:folder:%d", id), "write") {
		jsonError(w, "permission denied for this folder", http.StatusForbidden)
		return
	}
	folderName, _ := db.GetFolderName(id)
	if err := db.SoftDeleteFolder(id, folderName, username); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- Records ----

// POST /api/v1/safe/records
func CreateRecord(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	var rec models.SafeRecord
	if err := json.NewDecoder(r.Body).Decode(&rec); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	uid, _, isAdmin := middleware.UserFromContext(r)
	if !isAdmin && db.IsExplicitlyDenied(uid, fmt.Sprintf("safe:folder:%d", rec.FolderID), "write") {
		jsonError(w, "permission denied for this folder", http.StatusForbidden)
		return
	}
	id, err := db.InsertRecord(&rec)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	rec.ID = id
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, rec)
}

// PUT /api/v1/safe/records/{id}
func UpdateRecord(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	var rec models.SafeRecord
	if err := json.NewDecoder(r.Body).Decode(&rec); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	rec.ID = id
	// Capture version snapshot and password history before overwriting
	_, username, _ := middleware.UserFromContext(r)
	if old, err := db.GetRecord(id); err == nil && old != nil {
		_ = db.CaptureRecordVersion(old, username)
		if old.Password != rec.Password && rec.Password != "" {
			_ = db.RecordPasswordHistory(id, old.Password, username)
		}
	}
	if err := db.UpdateRecord(&rec); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, rec)
}

// DELETE /api/v1/safe/records/{id}
func DeleteRecord(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	// Soft-delete: move to recycle bin instead of hard delete
	_, username, _ := middleware.UserFromContext(r)
	if old, serr := db.GetRecord(id); serr == nil && old != nil {
		if err := db.SoftDeleteRecord(old, username); err != nil {
			_ = db.DeleteRecord(id)
		}
	} else {
		_ = db.DeleteRecord(id)
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- Items ----

// POST /api/v1/safe/items
func CreateItem(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	var item models.SafeItem
	if err := json.NewDecoder(r.Body).Decode(&item); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	id, err := db.InsertItem(&item)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	item.ID = id
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, item)
}

// PUT /api/v1/safe/items/{id}
func UpdateItem(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	var item models.SafeItem
	if err := json.NewDecoder(r.Body).Decode(&item); err != nil {
		jsonError(w, "invalid json", http.StatusBadRequest)
		return
	}
	item.ID = id
	if err := db.UpdateItem(&item); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, item)
}

// DELETE /api/v1/safe/items/{id}
func DeleteItem(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "write") {
		return
	}
	id, ok := idFromPath(r.URL.Path)
	if !ok {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	if err := db.DeleteItem(id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- XML Import/Export ----

// POST /api/v1/safe/import  — body: XML matching safe.xml format
func ImportSafe(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "import") {
		return
	}
	replace := r.URL.Query().Get("replace") == "true"
	var root models.XMLRoot
	if err := xml.NewDecoder(r.Body).Decode(&root); err != nil {
		jsonError(w, "invalid xml: "+err.Error(), http.StatusBadRequest)
		return
	}
	if replace {
		if err := db.ClearAll(); err != nil {
			jsonError(w, "clear failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	count := 0
	for _, xmlFolder := range root.Folders {
		if err := importXMLFolder(xmlFolder, nil, &count); err != nil {
			jsonError(w, "import error: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	// Records at root level
	for _, xmlRec := range root.Records {
		fid, _ := db.InsertFolder("(root)", nil)
		importXMLRecord(xmlRec, fid, &count)
	}
	jsonOK(w, map[string]int{"imported_records": count})
}

func importXMLFolder(f models.XMLFolder, parentID *int64, count *int) error {
	id, err := db.InsertFolder(f.Name, parentID)
	if err != nil {
		return err
	}
	for _, rec := range f.Records {
		importXMLRecord(rec, id, count)
	}
	for _, child := range f.Folders {
		if err := importXMLFolder(child, &id, count); err != nil {
			return err
		}
	}
	return nil
}

func importXMLRecord(r models.XMLRecord, folderID int64, count *int) {
	rec := models.SafeRecord{
		FolderID: folderID,
		Name:     r.Name,
		Login:    r.Login,
		Password: r.Password,
	}
	for _, xi := range r.Items {
		rec.Items = append(rec.Items, models.SafeItem{Name: xi.Name, Content: xi.Content})
	}
	db.InsertRecord(&rec)
	*count++
}

// GET /api/v1/safe/export
func ExportSafe(w http.ResponseWriter, r *http.Request) {
	if !requirePerm(w, r, "safe", "export") {
		return
	}
	tree, err := db.GetFolderTree()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	root := models.XMLRoot{Name: "Safe"}
	for _, f := range tree {
		root.Folders = append(root.Folders, folderToXML(f))
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Content-Disposition", "attachment; filename=safe.xml")
	w.Write([]byte(xml.Header))
	enc := xml.NewEncoder(w)
	enc.Indent("", "  ")
	enc.Encode(root)
}

func folderToXML(f models.SafeFolder) models.XMLFolder {
	xf := models.XMLFolder{Name: f.Name}
	for _, rec := range f.Records {
		xr := models.XMLRecord{Name: rec.Name, Login: rec.Login, Password: rec.Password}
		for _, item := range rec.Items {
			xr.Items = append(xr.Items, models.XMLItem{Name: item.Name, Content: item.Content})
		}
		xf.Records = append(xf.Records, xr)
	}
	for _, child := range f.Children {
		xf.Folders = append(xf.Folders, folderToXML(child))
	}
	return xf
}
