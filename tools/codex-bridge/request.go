package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
)

const backendURL = "https://chatgpt.com/backend-api/codex/responses"
const clientVersion = "0.155.1"

var modelName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)
var errModelUnavailable = errors.New("model unavailable for account")
var errRequestTransport = errors.New("request transport failed")
var errInvalidRequest = errors.New("invalid request")

type requestClient struct {
	http *http.Client
	url  string
	auth *authClient
}

func decodeRequestBody(encoded string) ([]byte, string, error) {
	body, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(body) == 0 || len(body) > maxFrame/2 {
		return nil, "", errInvalidRequest
	}
	var doc struct {
		Model  string `json:"model"`
		Stream *bool  `json:"stream"`
		Store  *bool  `json:"store"`
	}
	if json.Unmarshal(body, &doc) != nil || !modelName.MatchString(doc.Model) || doc.Stream == nil || !*doc.Stream || doc.Store == nil || *doc.Store {
		return nil, "", errInvalidRequest
	}
	return body, doc.Model, nil
}

func (r *requestClient) open(ctx context.Context, body []byte, model string, c credential) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Access)
	req.Header.Set("chatgpt-account-id", c.AccountID)
	req.Header.Set("x-codex-routing-hint", "model="+model)
	req.Header.Set("OpenAI-Beta", "responses=experimental")
	req.Header.Set("originator", "loom")
	req.Header.Set("version", clientVersion)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	if c.Residency != "" {
		req.Header.Set("x-openai-internal-codex-residency", c.Residency)
	}
	return r.http.Do(req)
}

// stream emits raw SSE bytes. The provider adapter, not this credential
// owner, validates response events and reconstructs Loom messages.
func (r *requestClient) stream(ctx context.Context, encoded string, send func(event)) error {
	body, model, err := decodeRequestBody(encoded)
	if err != nil {
		return err
	}
	usedReplay := false
	models, err := r.modelsWithReplayBudget(ctx, &usedReplay)
	if err != nil {
		return err
	}
	available := false
	for _, candidate := range models {
		if candidate.ID == model {
			available = true
			break
		}
	}
	if !available {
		return errModelUnavailable
	}
	c, err := r.auth.current(ctx, false)
	if err != nil {
		return err
	}
	resp, err := r.open(ctx, body, model, c)
	if err != nil {
		return errRequestTransport
	}
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		if usedReplay {
			return errRefreshFailed
		}
		usedReplay = true
		c, err = r.auth.current(ctx, true)
		if err != nil {
			return err
		}
		resp, err = r.open(ctx, body, model, c)
		if err != nil {
			return errRequestTransport
		}
	}
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		return errRefreshFailed
	}
	send(event{Event: "http_status", Status: resp.StatusCode})
	buf := make([]byte, 32<<10)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			send(event{Event: "chunk", DataB64: base64.StdEncoding.EncodeToString(buf[:n])})
		}
		if readErr == io.EOF {
			if err := resp.Body.Close(); err != nil {
				return errRequestTransport
			}
			return nil
		}
		if readErr != nil {
			resp.Body.Close()
			return errRequestTransport
		}
	}
}
