package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/roasbeef/loom/vmm/ghproxy"
	"github.com/roasbeef/loom/vmm/machine"
)

// githubTokenEnv is the host variable --github-token-from env reads. It is a
// host variable only: the guest never receives it.
const githubTokenEnv = "LOOM_VM_GITHUB_TOKEN"

// proxyLifetimeMargin is how long the proxy's CA outlives the run's timeout.
const proxyLifetimeMargin = time.Hour

// standingProxyLifetime bounds the CA of a run with no timeout, a standing
// guest. The key never leaves this process and dies with it, so the bound
// only limits how long a stolen copy of the guest's CA certificate could
// matter; a guest that outlives it is restarted to mint a new one.
const standingProxyLifetime = 30 * 24 * time.Hour

// githubFlags are the flags that give a guest GitHub access through the
// credential-injecting proxy in package ghproxy. With --github-token-from
// unset they do nothing, and the guest has no route to GitHub except what
// --allow opens directly, with no credential.
type githubFlags struct {
	tokenFrom string
	inject    listFlag
}

// register adds the flags to fs.
func (g *githubFlags) register(fs *flag.FlagSet) {
	fs.StringVar(&g.tokenFrom, "github-token-from", "",
		"enable the GitHub credential proxy; read the token from the host with "+
			"`gh` (gh auth token) or `env` ("+githubTokenEnv+")")
	fs.Var(&g.inject, "inject-host", "extra host whose Authorization placeholder the proxy "+
		"replaces (repeatable; github.com, api.github.com and uploads.github.com are built in)")
}

// apply starts the proxy and adds what the guest needs to spec: the proxy as a
// host service on the gateway, and the files that make the guest trust and use
// it. The returned function stops the proxy and removes the staging directory;
// call it after the guest has stopped. With the flag unset it does nothing.
//
// The proxy admits exactly the hosts spec.Egress allows, so the guest's
// allowlist stays the one statement of what it may reach. Injection only
// decides which of those hosts get a credential.
func (g *githubFlags) apply(spec *machine.Spec, timeout time.Duration) (func(), error) {
	if g.tokenFrom == "" {
		return func() {}, nil
	}

	token, err := readGitHubToken(g.tokenFrom)
	if err != nil {
		return nil, err
	}

	inject := append(append([]string{}, ghproxy.DefaultInjectHosts...), g.inject...)
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil)).With("component", "ghproxy")

	proxy, err := ghproxy.New(ghproxy.Config{
		Token:    token,
		Allow:    spec.Egress.Hosts,
		Inject:   inject,
		Lifetime: proxyLifetime(timeout),
		Logger:   logger,
	})
	if err != nil {
		return nil, err
	}

	dir, err := os.MkdirTemp("", "loom-vm-ghproxy-")
	if err != nil {
		proxy.Close()
		return nil, fmt.Errorf("github proxy: %w", err)
	}

	cleanup := func() {
		proxy.Close()
		_ = os.RemoveAll(dir)
	}

	for n, f := range proxy.GuestFiles(ghproxy.DefaultPort) {
		src := filepath.Join(dir, fmt.Sprintf("file%d", n))
		if err := os.WriteFile(src, f.Content, 0o600); err != nil {
			cleanup()
			return nil, fmt.Errorf("github proxy: %w", err)
		}

		spec.Files = append(spec.Files, machine.File{Source: src, Target: f.Target, Mode: f.Mode})
	}

	spec.HostServices = append(spec.HostServices,
		machine.HostService{Port: ghproxy.DefaultPort, Handler: proxy})

	return cleanup, nil
}

// readGitHubToken fetches the token from the host. The value is returned to
// the caller and nowhere else: it is not logged and not placed in an error.
func readGitHubToken(from string) (string, error) {
	var token string

	switch from {
	case "gh":
		out, err := exec.Command("gh", "auth", "token").Output()
		if err != nil {
			return "", fmt.Errorf("--github-token-from gh: gh auth token failed: %w", err)
		}
		token = string(out)

	case "env":
		token = os.Getenv(githubTokenEnv)

	default:
		return "", fmt.Errorf("--github-token-from %q: want gh or env", from)
	}

	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("--github-token-from %s: no token", from)
	}

	return token, nil
}

// proxyLifetime is the CA's validity for a run of the given timeout, where
// zero means the run lasts until it is stopped.
func proxyLifetime(timeout time.Duration) time.Duration {
	if timeout == 0 {
		return standingProxyLifetime
	}

	return timeout + proxyLifetimeMargin
}
