package ghproxy

import (
	"fmt"
	"io/fs"
	"sort"
	"strings"
)

// Guest-side paths and addresses. The gateway is go-microvm's hosted stack,
// where the proxy is registered; the guest init's `update-ca-certificates`
// reads the certificate directory.
const (
	// GatewayAddr is the host-side address the guest reaches the proxy at.
	GatewayAddr = "192.168.127.1"

	// DefaultPort is the gateway port the launcher registers the proxy on.
	DefaultPort uint16 = 3128

	// CAPath is where the guest's init finds the proxy CA to trust.
	CAPath = "/usr/local/share/ca-certificates/loom-vm-proxy.crt"

	// EnvPath is the file the guest init exports into the workload.
	EnvPath = "/etc/loom-vm/github.env"

	// GitConfigPath is the system git configuration the proxy stages.
	GitConfigPath = "/etc/gitconfig"
)

// GuestFile is one file to stage into the guest root, as bytes rather than a
// host path so the content can be checked without touching the disk.
type GuestFile struct {
	Target  string
	Content []byte
	Mode    fs.FileMode
}

// GuestFiles returns what the guest needs to use the proxy listening at
// GatewayAddr:port: the CA to trust, an environment file, and a system git
// configuration. None of them holds the token. The environment file and the
// credential helper carry the placeholder, which is worthless outside this
// proxy, and the CA file carries a certificate.
func (p *Proxy) GuestFiles(port uint16) []GuestFile {
	proxyURL := fmt.Sprintf("http://%s:%d", GatewayAddr, port)
	noProxy := GatewayAddr + ",127.0.0.1,localhost"
	placeholder := p.Placeholder()

	env := strings.Join([]string{
		"HTTPS_PROXY=" + proxyURL,
		"https_proxy=" + proxyURL,
		"NO_PROXY=" + noProxy,
		"no_proxy=" + noProxy,
		"GH_TOKEN=" + placeholder,
		"GITHUB_TOKEN=" + placeholder,
		"",
	}, "\n")

	return []GuestFile{
		{Target: CAPath, Content: p.CACertPEM(), Mode: 0o644},
		{Target: EnvPath, Content: []byte(env), Mode: 0o644},
		{Target: GitConfigPath, Content: []byte(p.gitConfig(proxyURL)), Mode: 0o644},
	}
}

// gitConfig renders the system git configuration. Git sends every HTTPS
// request through the proxy, and for each injection host a credential helper
// answers with the username x-access-token and the placeholder, which the
// proxy turns into the token. The helper reads GH_TOKEN so a caller that sets
// its own value wins, and falls back to the placeholder so a jailed shell whose
// environment allowlist omits GH_TOKEN still authenticates through the proxy.
// The value is quoted because an unquoted ";" would start a comment.
//
// Each injection host also gets a rewrite of its SSH remote forms to HTTPS.
// Most developer checkouts name their origin as git@host:owner/repo, and the
// copy in the guest keeps that URL. The guest has no ssh client, no key and
// no route to port 22, so without the rewrite `git push` fails there with
// "cannot run ssh". The rewrite names the same host and adds no credential
// of its own: the request still goes through the proxy, which decides.
func (p *Proxy) gitConfig(proxyURL string) string {
	var b strings.Builder

	b.WriteString("# Written by loom-vm. The password below is a placeholder that only\n")
	b.WriteString("# the host-side proxy for this guest replaces with a real token.\n")
	fmt.Fprintf(&b, "[http]\n\tproxy = %s\n", proxyURL)

	hosts := p.InjectHosts()
	sort.Strings(hosts)

	for _, host := range hosts {
		fmt.Fprintf(&b, "[credential \"https://%s\"]\n", host)
		fmt.Fprintf(&b, "\thelper = \"!f() { echo username=x-access-token; "+
			"echo password=${GH_TOKEN:-%s}; }; f\"\n", p.Placeholder())
	}

	for _, host := range hosts {
		fmt.Fprintf(&b, "[url \"https://%s/\"]\n", host)
		fmt.Fprintf(&b, "\tinsteadOf = git@%s:\n", host)
		fmt.Fprintf(&b, "\tinsteadOf = ssh://git@%s/\n", host)
	}

	return b.String()
}
