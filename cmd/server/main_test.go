package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateAndListSignaturesDoesNotExposePrivateFields(t *testing.T) {
	db, err := openDB(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	app := &application{db: db}

	body := `{
		"name":"Jane Doe",
		"category":"Individual-Chatham Resident",
		"town":"Chatham, MA",
		"street_address":"520 Cotton Street",
		"email":"private@example.com",
		"phone":"508-555-0100",
		"reason":"The light helps me navigate."
	}`
	create := httptest.NewRecorder()
	app.routes().ServeHTTP(create, httptest.NewRequest(http.MethodPost, "/api/signatures", strings.NewReader(body)))
	if create.Code != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", create.Code, create.Body.String())
	}

	list := httptest.NewRecorder()
	app.routes().ServeHTTP(list, httptest.NewRequest(http.MethodGet, "/api/signatures", nil))
	if list.Code != http.StatusOK {
		t.Fatalf("list status = %d, body = %s", list.Code, list.Body.String())
	}
	response := list.Body.String()
	for _, private := range []string{"private@example.com", "508-555-0100", "520 Cotton Street"} {
		if strings.Contains(response, private) {
			t.Errorf("public response leaked %q: %s", private, response)
		}
	}
	if !strings.Contains(response, "Cotton Street") {
		t.Errorf("public response did not contain sanitized street: %s", response)
	}
}

func TestCreateRejectsInvalidInput(t *testing.T) {
	db, err := openDB(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	app := &application{db: db}

	request := httptest.NewRequest(http.MethodPost, "/api/signatures", bytes.NewBufferString(`{"name":"Jane","category":"Admin"}`))
	response := httptest.NewRecorder()
	app.routes().ServeHTTP(response, request)
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}

	var payload map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil || payload["error"] == "" {
		t.Fatalf("expected JSON error, body = %s", response.Body.String())
	}
}
