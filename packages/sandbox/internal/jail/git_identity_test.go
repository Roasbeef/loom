//go:build linux || darwin

package jail

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/roasbeef/loom/sandbox/internal/policy"
	"golang.org/x/sys/unix"
)

func gitIdentityFixture(t *testing.T) (policy.Policy, string, string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	workspace := filepath.Join(root, "workspace")
	home := filepath.Join(workspace, ".codemode", "home")
	if err := os.MkdirAll(home, 0700); err != nil {
		t.Fatal(err)
	}
	return policy.Policy{
		WritableRoots: []string{workspace},
		ReadableRoots: []string{"/"},
		Protected:     []string{},
		EnvAllow:      []string{},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       filepath.Join(root, "scratch"),
	}, workspace, home
}

func TestGitIdentityPublicationRoundTripsThroughGit(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	name := "  snow ☃ #; \"quoted\" \\ slash\nnewline\ttab\bbackspace\rcarriage  "
	entries := [][2]string{
		{"user.name", "discarded"},
		{"user.email", " spaced@example.test "},
		{"user.name", name},
	}
	if err := PublishGitIdentity(pol, workspace, entries); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, "gitconfig")
	for key, want := range map[string]string{
		"user.name": name, "user.email": " spaced@example.test ", "user.useConfigOnly": "true",
	} {
		out, err := exec.Command("git", "config", "--file", path, "--null", "--get", key).Output()
		if err != nil || string(out) != want+"\x00" {
			t.Fatalf("Git decode of %s: got %q, err %v; want %q", key, out, err, want)
		}
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("published permissions: %v, %v", info, err)
	}
}

func TestGitIdentityPublicationDoesNotCreateMissingMasks(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	state := filepath.Join(workspace, "state")
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(state, "catalogue.db")
	if err := os.WriteFile(database, []byte("catalogue"), 0600); err != nil {
		t.Fatal(err)
	}
	pol.Protected = []string{database, database + "-journal", database + "-wal", database + "-shm"}
	if err := PublishGitIdentity(pol, workspace, nil); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"-journal", "-wal", "-shm"} {
		if _, err := os.Lstat(database + suffix); !os.IsNotExist(err) {
			t.Fatalf("publication materialized a protected side file: %s: %v", suffix, err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(home, "gitconfig")); err != nil ||
		!bytes.Contains(data, []byte("useConfigOnly = true")) {
		t.Fatalf("missing fixed identity guard: %q, %v", data, err)
	}
}

func TestGitIdentityPublicationRefusesParentSymlinks(t *testing.T) {
	for _, component := range []string{".codemode", filepath.Join(".codemode", "home")} {
		t.Run(component, func(t *testing.T) {
			pol, workspace, _ := gitIdentityFixture(t)
			outside := t.TempDir()
			target := outside
			if component == ".codemode" {
				target = filepath.Join(outside, "home")
				if err := os.Mkdir(target, 0700); err != nil {
					t.Fatal(err)
				}
			}
			path := filepath.Join(workspace, component)
			if err := os.RemoveAll(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, path); err != nil {
				t.Fatal(err)
			}
			if err := PublishGitIdentity(pol, workspace, nil); err == nil {
				t.Fatal("a planted parent link became a write grant")
			}
			entries, err := os.ReadDir(target)
			if err != nil || len(entries) != 0 {
				t.Fatalf("publication changed the link target: %v, %v", entries, err)
			}
		})
	}
}

func TestGitIdentityPublicationReplacesLinksWithoutFollowingThem(t *testing.T) {
	for _, kind := range []string{"symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			pol, workspace, home := gitIdentityFixture(t)
			outside := filepath.Join(t.TempDir(), "identity")
			if err := os.WriteFile(outside, []byte("untouched"), 0600); err != nil {
				t.Fatal(err)
			}
			destination := filepath.Join(home, "gitconfig")
			link := os.Symlink
			if kind == "hardlink" {
				link = os.Link
			}
			if err := link(outside, destination); err != nil {
				t.Fatal(err)
			}
			if err := PublishGitIdentity(pol, workspace, nil); err != nil {
				t.Fatal(err)
			}
			if data, err := os.ReadFile(outside); err != nil || string(data) != "untouched" {
				t.Fatalf("publication followed the existing link: %q, %v", data, err)
			}
			info, err := os.Lstat(destination)
			if err != nil || !info.Mode().IsRegular() {
				t.Fatalf("destination is not a newly published regular file: %v, %v", info, err)
			}
		})
	}
}

func TestGitIdentityPublicationHonorsPolicyDenials(t *testing.T) {
	cases := map[string]func(*policy.Policy, string, string){
		"no write grant": func(pol *policy.Policy, _, _ string) { pol.WritableRoots = nil },
		"protected home": func(pol *policy.Policy, _, home string) { pol.Protected = []string{home} },
		"protected destination": func(pol *policy.Policy, _, home string) {
			pol.Protected = []string{filepath.Join(home, "gitconfig")}
		},
		"read-only mount": func(pol *policy.Policy, _, home string) {
			pol.Mounts = []policy.Mount{{Path: home, Access: policy.MountReadOnly, Required: true}}
		},
		"file-size ceiling": func(pol *policy.Policy, _, _ string) { pol.Limits.FsizeBytes = 1 },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			pol, workspace, home := gitIdentityFixture(t)
			change(&pol, workspace, home)
			if err := PublishGitIdentity(pol, workspace, nil); err == nil {
				t.Fatal("publication ignored the policy restriction")
			}
			if files, err := os.ReadDir(home); err != nil || len(files) != 0 {
				t.Fatalf("refusal left files behind: %v, %v", files, err)
			}
		})
	}
}

func TestGitIdentityPublicationHonorsProtectedAliases(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	alias := filepath.Join(t.TempDir(), "protected")
	if err := os.Symlink(home, alias); err != nil {
		t.Fatal(err)
	}
	pol.Protected = []string{alias}
	if err := PublishGitIdentity(pol, workspace, nil); err == nil {
		t.Fatal("a protected alias did not protect its target")
	}
}

func TestGitIdentityPublicationParentReplacementCannotRedirectDescriptor(t *testing.T) {
	_, workspace, home := gitIdentityFixture(t)
	root, err := unix.Open(workspace, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(root)
	fd, err := walkGitIdentityHome(root, ".codemode/home")
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	retired := filepath.Join(workspace, "retired-home")
	if err := os.Rename(home, retired); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, home); err != nil {
		t.Fatal(err)
	}
	if err := replaceGitIdentity(fd, ".gitconfig-test-owned", []byte("complete")); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(retired, "gitconfig")); err != nil || string(data) != "complete" {
		t.Fatalf("the held parent did not receive the complete file: %q, %v", data, err)
	}
	if files, err := os.ReadDir(outside); err != nil || len(files) != 0 {
		t.Fatalf("the replacement link redirected publication: %v, %v", files, err)
	}
}

func TestGitIdentityPublicationReadersSeeCompleteFiles(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	one := [][2]string{{"user.name", strings.Repeat("a", 4000)}}
	two := [][2]string{{"user.name", strings.Repeat("b", 4000)}}
	first, _ := renderGitIdentity(one)
	second, _ := renderGitIdentity(two)
	if err := PublishGitIdentity(pol, workspace, one); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(home, "gitconfig")
	old, err := os.Open(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()
	done := make(chan struct{})
	reader := make(chan error, 1)
	go func() {
		for {
			select {
			case <-done:
				reader <- nil
				return
			default:
				data, err := os.ReadFile(destination)
				if err != nil || (!bytes.Equal(data, first) && !bytes.Equal(data, second)) {
					reader <- os.ErrInvalid
					return
				}
			}
		}
	}()
	for i := 0; i < 30; i++ {
		entries := one
		if i%2 == 0 {
			entries = two
		}
		if err := PublishGitIdentity(pol, workspace, entries); err != nil {
			close(done)
			<-reader
			t.Fatal(err)
		}
	}
	close(done)
	if err := <-reader; err != nil {
		t.Fatal("a concurrent reader observed a partial configuration")
	}
	oldBytes := make([]byte, len(first))
	if n, err := old.Read(oldBytes); err != nil || n != len(first) || !bytes.Equal(oldBytes, first) {
		t.Fatalf("an existing reader lost its old complete file: %d, %v", n, err)
	}
	files, err := os.ReadDir(home)
	if err != nil || len(files) != 1 || files[0].Name() != "gitconfig" {
		t.Fatalf("publication left temporary files: %v, %v", files, err)
	}
}

func TestGitIdentityPublicationCLIRejectsMalformedEntries(t *testing.T) {
	pol, workspace, _ := gitIdentityFixture(t)
	encoded, err := policy.Encode(pol)
	if err != nil {
		t.Fatal(err)
	}
	policyText := base64.StdEncoding.EncodeToString(encoded)
	for _, entries := range []string{
		"null", "{}", "[[]]", "[[\"user.name\"]]", "[[\"user.name\",\"x\",\"extra\"]]",
		"[[\"core.hooksPath\",\"secret-value\"]]", "[[\"user.name\",\"\\u0000\"]]", "[[\"user.name\",null]]",
		"[] trailing", strings.Repeat(" ", gitIdentityInputLimit+1),
	} {
		if err := RunGitIdentityPublication([]string{policyText, workspace, entries}); err == nil {
			t.Fatalf("accepted malformed entries: %.80q", entries)
		} else if strings.Contains(err.Error(), "secret-value") {
			t.Fatal("an error disclosed the supplied value")
		}
	}
	if err := RunGitIdentityPublication([]string{policyText, workspace, "[]"}); err != nil {
		t.Fatalf("valid empty projection refused: %v", err)
	}
}

func TestGitIdentityPublicationRefusesMissingParentsAndCleansFailedReplace(t *testing.T) {
	for _, kind := range []string{"missing home", "directory destination"} {
		t.Run(kind, func(t *testing.T) {
			pol, workspace, home := gitIdentityFixture(t)
			if kind == "missing home" {
				if err := os.Remove(home); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Mkdir(filepath.Join(home, "gitconfig"), 0700); err != nil {
				t.Fatal(err)
			}
			if err := PublishGitIdentity(pol, workspace, nil); err == nil {
				t.Fatal("an unavailable destination unexpectedly accepted publication")
			}
			if kind == "missing home" {
				if _, err := os.Stat(home); !os.IsNotExist(err) {
					t.Fatal("publication created its own parent")
				}
			} else if files, err := os.ReadDir(home); err != nil || len(files) != 1 || files[0].Name() != "gitconfig" {
				t.Fatalf("failed rename left a temporary file: %v, %v", files, err)
			}
		})
	}
}

func TestGitIdentityPublicationUsesOriginalExplicitWriteGrant(t *testing.T) {
	pol, workspace, home := gitIdentityFixture(t)
	pol.WritableRoots = []string{}
	pol.Mounts = []policy.Mount{{Path: workspace, Access: policy.MountReadWrite, Required: true}}
	if err := PublishGitIdentity(pol, workspace, nil); err != nil {
		t.Fatalf("the original explicit workspace grant was lost: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, "gitconfig")); err != nil {
		t.Fatal(err)
	}
}

func TestGitIdentityPublicationPrivateScratchIsNotHostAuthority(t *testing.T) {
	pol := policy.Policy{
		WritableRoots: []string{"/tmp"},
		ReadableRoots: []string{"/"},
		Network:       policy.Network{Mode: policy.NetworkOff},
		Scratch:       "tmpfs",
	}
	if _, _, err := gitIdentityAuthority(pol, "/tmp", ".gitconfig-test-owned"); err == nil {
		t.Fatal("private scratch was treated as a host write grant")
	}
}
