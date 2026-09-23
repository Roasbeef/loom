package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var profileName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`)
var errAccountMismatch = errors.New("account identity mismatch")

const authClaim = "https://api.openai.com/auth"
const profileClaim = "https://api.openai.com/profile"

type credential struct {
	Access    string    `json:"access"`
	Refresh   string    `json:"refresh"`
	Expires   time.Time `json:"expires"`
	AccountID string    `json:"account_id"`
	Email     string    `json:"email,omitempty"`
	Plan      string    `json:"plan,omitempty"`
	Residency string    `json:"residency,omitempty"`
}

type profileStore struct {
	mu   sync.Mutex
	dir  string
	name string
}

func newProfileStore(dir, name string) (*profileStore, error) {
	if !profileName.MatchString(name) {
		return nil, errors.New("invalid profile name")
	}
	return &profileStore{dir: dir, name: name}, nil
}

func (p *profileStore) path() string { return filepath.Join(p.dir, p.name+".json") }

func (p *profileStore) load() (credential, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.loadLocked()
}

func (p *profileStore) loadLocked() (credential, error) {
	info, err := os.Lstat(p.path())
	if err != nil {
		return credential{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return credential{}, errors.New("unsafe credential file")
	}
	buf, err := os.ReadFile(p.path())
	if err != nil {
		return credential{}, err
	}
	var c credential
	if err := json.Unmarshal(buf, &c); err != nil || c.Access == "" || c.Refresh == "" || c.AccountID == "" {
		return credential{}, errors.New("invalid credential file")
	}
	return c, nil
}

func (p *profileStore) save(c credential) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.saveLocked(c)
}

// saveLogin refuses an implicit workspace switch. The operator must log out
// before a browser/device login may bind this profile to another account.
func (p *profileStore) saveLogin(c credential) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	old, err := p.loadLocked()
	if err == nil && old.AccountID != c.AccountID {
		return errAccountMismatch
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return p.saveLocked(c)
}

func (p *profileStore) saveLocked(c credential) error {
	if c.Access == "" || c.Refresh == "" || c.AccountID == "" {
		return errors.New("incomplete credential")
	}
	if err := os.MkdirAll(p.dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(p.dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("unsafe profile directory")
	}
	buf, err := json.Marshal(c)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(p.dir, ".credential-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(buf); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), p.path()); err != nil {
		return err
	}
	d, err := os.Open(p.dir)
	if err == nil {
		defer d.Close()
		_ = d.Sync()
	}
	return nil
}

func (p *profileStore) remove() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	err := os.Remove(p.path())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func tokenClaims(token string) (accountID, email, plan, residency string, err error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", "", "", "", errors.New("invalid token claims")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", "", "", "", errors.New("invalid token claims")
	}
	var claims map[string]json.RawMessage
	if json.Unmarshal(payload, &claims) != nil {
		return "", "", "", "", errors.New("invalid token claims")
	}
	var auth struct {
		AccountID        string `json:"chatgpt_account_id"`
		Plan             string `json:"chatgpt_plan_type"`
		DataResidency    string `json:"chatgpt_data_residency"`
		ComputeResidency string `json:"chatgpt_compute_residency"`
	}
	if json.Unmarshal(claims[authClaim], &auth) != nil || auth.AccountID == "" {
		return "", "", "", "", errors.New("missing account identity")
	}
	var user struct {
		Email string `json:"email"`
	}
	_ = json.Unmarshal(claims[profileClaim], &user)
	residency = auth.DataResidency
	if residency == "" {
		residency = auth.ComputeResidency
	}
	return auth.AccountID, strings.ToLower(strings.TrimSpace(user.Email)), strings.ToLower(auth.Plan), residency, nil
}
