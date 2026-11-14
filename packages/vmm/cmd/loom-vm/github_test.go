package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/vmm/ghproxy"
	"github.com/roasbeef/loom/vmm/machine"
)

const testToken = "ghp_TokenForTheLauncherTest0123456789"

func parseGitHubFlags(t *testing.T, args ...string) *githubFlags {
	t.Helper()

	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	g := &githubFlags{}
	g.register(fs)

	if err := fs.Parse(args); err != nil {
		t.Fatal(err)
	}

	return g
}

func TestGitHubFlagsUnsetDoNothing(t *testing.T) {
	spec := machine.Spec{}

	stop, err := parseGitHubFlags(t).apply(&spec, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	stop()

	if len(spec.Files) != 0 || len(spec.HostServices) != 0 {
		t.Fatalf("spec was changed with the flag unset: %+v", spec)
	}
}

func TestGitHubFlagsStageProxyAndFiles(t *testing.T) {
	t.Setenv(githubTokenEnv, testToken+"\n")

	spec := machine.Spec{Egress: machine.Egress{Hosts: []string{"github.com", "api.github.com"}}}

	stop, err := parseGitHubFlags(t, "--github-token-from", "env",
		"--inject-host", "ghe.example.com").apply(&spec, time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	if len(spec.HostServices) != 1 || spec.HostServices[0].Port != ghproxy.DefaultPort {
		t.Fatalf("host services = %+v", spec.HostServices)
	}

	targets := map[string]string{}
	for _, f := range spec.Files {
		raw, err := os.ReadFile(f.Source)
		if err != nil {
			t.Fatal(err)
		}

		if strings.Contains(string(raw), testToken) {
			t.Fatalf("staged file %s holds the real token", f.Target)
		}

		targets[f.Target] = string(raw)
	}

	for _, want := range []string{ghproxy.CAPath, ghproxy.EnvPath, ghproxy.GitConfigPath} {
		if _, ok := targets[want]; !ok {
			t.Fatalf("%s was not staged", want)
		}
	}

	if !strings.Contains(targets[ghproxy.GitConfigPath], `"https://ghe.example.com"`) {
		t.Fatalf("--inject-host did not reach the git configuration:\n%s",
			targets[ghproxy.GitConfigPath])
	}

	if err := spec.Validate(); err == nil || !strings.Contains(err.Error(), "no root") {
		t.Fatalf("the staged spec should fail only for the root the test omits: %v", err)
	}

	stop()

	if _, err := os.Stat(spec.Files[0].Source); !os.IsNotExist(err) {
		t.Fatalf("staging directory survived cleanup: %v", err)
	}
}

func TestGitHubTokenSourceErrors(t *testing.T) {
	t.Setenv(githubTokenEnv, "")

	for _, from := range []string{"env", "keychain"} {
		spec := machine.Spec{}

		if _, err := parseGitHubFlags(t, "--github-token-from", from).apply(&spec, time.Minute); err == nil {
			t.Fatalf("--github-token-from %s with no token was accepted", from)
		}
	}
}

// A host with no usable `gh` login is the common first-run failure, so the
// error must name each way out of it, and must still name the cause.
func TestGitHubTokenErrorNamesTheRemedies(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\nexit 1\n"

	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PATH", dir)

	_, err := readGitHubToken("gh")
	if err == nil {
		t.Fatal("a failing gh was accepted")
	}

	for _, want := range []string{
		"gh auth token failed",
		"exit status 1",
		"gh auth login",
		"--github env",
		githubTokenEnv,
		"--github off",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

// An empty variable is a missing token, and names the same remedies.
func TestGitHubEnvTokenMissingNamesTheRemedies(t *testing.T) {
	t.Setenv(githubTokenEnv, "")

	_, err := readGitHubToken("env")
	if err == nil || !strings.Contains(err.Error(), "--github off") {
		t.Fatalf("empty env token error = %v, want the remedies", err)
	}
}
