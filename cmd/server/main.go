package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type application struct {
	db *sql.DB
}

type createSignatureRequest struct {
	Name          string `json:"name"`
	Category      string `json:"category"`
	Town          string `json:"town"`
	StreetAddress string `json:"street_address"`
	Email         string `json:"email"`
	Phone         string `json:"phone"`
	Reason        string `json:"reason"`
}

// publicSignature deliberately contains no email, phone, or full address.
// Keeping a separate response type makes accidentally leaking private fields
// much harder than serializing the database model directly.
type publicSignature struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	Category  string `json:"category"`
	Location  string `json:"location,omitempty"`
	Reason    string `json:"reason,omitempty"`
	CreatedAt string `json:"created_at"`
}

func main() {
	addr := envOr("ADDR", ":8080")
	dbPath := envOr("DB_PATH", "data/signatures.db")

	if err := os.MkdirAll(filepath.Dir(dbPath), 0o750); err != nil {
		log.Fatalf("create database directory: %v", err)
	}
	db, err := openDB(dbPath)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer db.Close()

	app := &application{db: db}
	server := &http.Server{
		Addr:              addr,
		Handler:           app.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("petition API listening on %s (database %s)", addr, dbPath)
	log.Fatal(server.ListenAndServe())
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func openDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := db.ExecContext(ctx, `
		PRAGMA journal_mode = WAL;
		PRAGMA foreign_keys = ON;
		CREATE TABLE IF NOT EXISTS signatures (
			id              INTEGER PRIMARY KEY AUTOINCREMENT,
			name            TEXT NOT NULL,
			category        TEXT NOT NULL,
			town            TEXT NOT NULL DEFAULT '',
			street_address  TEXT NOT NULL DEFAULT '',
			email           TEXT NOT NULL DEFAULT '',
			phone           TEXT NOT NULL DEFAULT '',
			reason          TEXT NOT NULL DEFAULT '',
			created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
		);
		CREATE INDEX IF NOT EXISTS signatures_created_at_idx
			ON signatures(created_at DESC, id DESC);
	`); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func (app *application) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", app.health)
	mux.HandleFunc("POST /api/signatures", app.createSignature)
	mux.HandleFunc("GET /api/signatures", app.listSignatures)
	return mux
}

func (app *application) health(w http.ResponseWriter, r *http.Request) {
	if err := app.db.PingContext(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (app *application) createSignature(w http.ResponseWriter, r *http.Request) {
	var input createSignatureRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	trimInput(&input)
	if err := validate(input); err != nil {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}

	result, err := app.db.ExecContext(r.Context(), `
		INSERT INTO signatures (name, category, town, street_address, email, phone, reason)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		input.Name, input.Category, input.Town, input.StreetAddress,
		input.Email, input.Phone, input.Reason,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not save signature")
		return
	}
	id, err := result.LastInsertId()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read saved signature")
		return
	}

	// Do not echo private fields back in the response.
	writeJSON(w, http.StatusCreated, map[string]int64{"id": id})
}

func (app *application) listSignatures(w http.ResponseWriter, r *http.Request) {
	rows, err := app.db.QueryContext(r.Context(), `
		SELECT id, name, category,
			CASE WHEN category = 'Individual-Chatham Resident'
				THEN trim(ltrim(street_address, '0123456789 ,-'))
				ELSE town
			END AS public_location,
			reason, created_at
		FROM signatures
		ORDER BY created_at DESC, id DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list signatures")
		return
	}
	defer rows.Close()

	items := make([]publicSignature, 0)
	for rows.Next() {
		var item publicSignature
		if err := rows.Scan(&item.ID, &item.Name, &item.Category, &item.Location, &item.Reason, &item.CreatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, "could not read signatures")
			return
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "could not read signatures")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"signatures": items})
}

func trimInput(input *createSignatureRequest) {
	input.Name = strings.TrimSpace(input.Name)
	input.Category = strings.TrimSpace(input.Category)
	input.Town = strings.TrimSpace(input.Town)
	input.StreetAddress = strings.TrimSpace(input.StreetAddress)
	input.Email = strings.TrimSpace(input.Email)
	input.Phone = strings.TrimSpace(input.Phone)
	input.Reason = strings.TrimSpace(input.Reason)
}

func validate(input createSignatureRequest) error {
	if input.Name == "" {
		return errors.New("name is required")
	}
	if len(input.Name) > 200 || len(input.Town) > 200 || len(input.StreetAddress) > 300 ||
		len(input.Email) > 320 || len(input.Phone) > 50 || len(input.Reason) > 2000 {
		return errors.New("one or more fields are too long")
	}
	validCategories := map[string]bool{
		"Individual-Chatham Resident": true,
		"Individual":                  true,
		"Organization":                true,
		"Business":                    true,
	}
	if !validCategories[input.Category] {
		return fmt.Errorf("invalid category")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
