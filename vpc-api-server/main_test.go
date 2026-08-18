package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func Test_generatePreAuthKey_requestsOneUseEphemeralEnrollment(t *testing.T) {
	var request PreAuthKeyRequest

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/user", func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer test-api-key" {
			t.Fatalf("Authorization header = %q, want %q", got, "Bearer test-api-key")
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"users":[{"id":"user-1","name":"default"}]}`))
	})
	mux.HandleFunc("/api/v1/preauthkey", func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatalf("decode pre-auth key request: %v", err)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"preAuthKey":{"key":"tskey-auth-test"}}`))
	})

	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	previousHeadscaleURL := headscaleInternalURL
	headscaleInternalURL = server.URL
	t.Cleanup(func() {
		headscaleInternalURL = previousHeadscaleURL
	})
	t.Setenv("HEADSCALE_API_KEY", "test-api-key")

	key, err := generatePreAuthKey()
	if err != nil {
		t.Fatalf("generatePreAuthKey() error = %v", err)
	}
	if key != "tskey-auth-test" {
		t.Fatalf("generatePreAuthKey() = %q, want %q", key, "tskey-auth-test")
	}
	if request.Reusable {
		t.Fatal("pre-auth key is reusable, want one-use enrollment")
	}
	if !request.Ephemeral {
		t.Fatal("pre-auth key is non-ephemeral, want automatic stale-node cleanup")
	}
}
