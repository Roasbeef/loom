package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
)

func (r *requestClient) getModels(ctx context.Context, path string, c credential) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(r.url, "/codex/responses")+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Access)
	req.Header.Set("chatgpt-account-id", c.AccountID)
	req.Header.Set("originator", "loom")
	req.Header.Set("version", clientVersion)
	if c.Residency != "" {
		req.Header.Set("x-openai-internal-codex-residency", c.Residency)
	}
	return r.http.Do(req)
}

func parseModels(body io.Reader) ([]modelInfo, error) {
	var envelope struct {
		Models []json.RawMessage `json:"models"`
		Data   []json.RawMessage `json:"data"`
	}
	limited := io.LimitReader(body, 1<<20+1)
	buf, err := io.ReadAll(limited)
	if err != nil || len(buf) > 1<<20 || json.Unmarshal(buf, &envelope) != nil {
		return nil, errors.New("invalid model catalogue")
	}
	entries := envelope.Models
	if entries == nil {
		entries = envelope.Data
	}
	if entries == nil {
		return nil, errors.New("model catalogue missing list")
	}
	if len(entries) > 256 {
		return nil, errors.New("model catalogue too large")
	}
	models := make([]modelInfo, 0, len(entries))
	seen := make(map[string]bool)
	for _, raw := range entries {
		var value struct {
			Slug             string `json:"slug"`
			ID               string `json:"id"`
			Visibility       string `json:"visibility"`
			ContextWindow    int    `json:"context_window"`
			MaxContextWindow int    `json:"max_context_window"`
			ReasoningLevels  []struct {
				Effort string `json:"effort"`
			} `json:"supported_reasoning_levels"`
		}
		if json.Unmarshal(raw, &value) != nil {
			continue
		}
		id := value.Slug
		if id == "" {
			id = value.ID
		}
		if !modelName.MatchString(id) || seen[id] || value.Visibility == "hide" || value.Visibility == "hidden" {
			continue
		}
		seen[id] = true
		model := modelInfo{ID: id}
		window := value.ContextWindow
		if window == 0 {
			window = value.MaxContextWindow
		}
		if window > 0 && window <= 10_000_000 {
			model.ContextWindow = window
		}
		for _, level := range value.ReasoningLevels {
			if modelName.MatchString(level.Effort) && len(model.ReasoningLevels) < 16 {
				model.ReasoningLevels = append(model.ReasoningLevels, level.Effort)
			}
		}
		models = append(models, model)
	}
	return models, nil
}

func (r *requestClient) models(ctx context.Context) ([]modelInfo, error) {
	usedReplay := false
	return r.modelsWithReplayBudget(ctx, &usedReplay)
}

func (r *requestClient) modelsWithReplayBudget(ctx context.Context, usedReplay *bool) ([]modelInfo, error) {
	c, err := r.auth.current(ctx, false)
	if err != nil {
		return nil, err
	}
	paths := []string{"/codex/models?client_version=" + clientVersion, "/models?client_version=" + clientVersion}
	for i, path := range paths {
		resp, err := r.getModels(ctx, path, c)
		if err != nil {
			return nil, errors.New("model discovery transport failed")
		}
		if resp.StatusCode == http.StatusUnauthorized {
			resp.Body.Close()
			if *usedReplay {
				return nil, errRefreshFailed
			}
			*usedReplay = true
			c, err = r.auth.current(ctx, true)
			if err != nil {
				return nil, err
			}
			resp, err = r.getModels(ctx, path, c)
			if err != nil {
				return nil, errors.New("model discovery transport failed")
			}
		}
		if resp.StatusCode == http.StatusUnauthorized {
			resp.Body.Close()
			return nil, errRefreshFailed
		}
		if resp.StatusCode == http.StatusNotFound && i == 0 {
			resp.Body.Close()
			continue
		}
		if resp.StatusCode == http.StatusForbidden {
			resp.Body.Close()
			return nil, errModelUnavailable
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return nil, errors.New("model discovery rejected")
		}
		models, err := parseModels(resp.Body)
		resp.Body.Close()
		return models, err
	}
	return nil, errors.New("model catalogue unavailable")
}
