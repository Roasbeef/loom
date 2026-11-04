package ghproxy

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"
)

// backdate is how far before now a certificate's NotBefore is set. A guest's
// clock is set from the host at boot but can still lag it, and a certificate
// that is not yet valid fails the handshake in a way that looks like a trust
// failure.
const backdate = time.Hour

// ca is the per-VM certificate authority. It is created in memory when the
// proxy starts, signs leaf certificates for the injection hosts only, and
// stops being valid when the VM's lifetime ends. The private key is a field
// of an unexported type and has no accessor, so nothing outside this package
// can write it anywhere.
type ca struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte

	mu     sync.Mutex
	leaves map[string]*tls.Certificate
}

// newCA generates an ECDSA P-256 authority valid for lifetime. Its name
// constraints permit only the given DNS domains, so a copy of the certificate
// in the guest's trust store is trusted to vouch for the injection hosts and
// for nothing else, whatever else the key could sign.
func newCA(lifetime time.Duration, permitted []string) (*ca, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("ghproxy: ca key: %w", err)
	}

	serial, err := newSerial()
	if err != nil {
		return nil, err
	}

	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "loom-vm proxy CA " + serial.Text(16)[:8],
			Organization: []string{"loom-vm"},
		},
		NotBefore:             now.Add(-backdate),
		NotAfter:              now.Add(lifetime),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		PermittedDNSDomains:   permitted,

		// A critical constraint makes a verifier that does not understand
		// it refuse the chain instead of ignoring the restriction.
		PermittedDNSDomainsCritical: len(permitted) > 0,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, fmt.Errorf("ghproxy: ca certificate: %w", err)
	}

	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, fmt.Errorf("ghproxy: parse ca certificate: %w", err)
	}

	return &ca{
		cert:   cert,
		key:    key,
		pem:    pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		leaves: make(map[string]*tls.Certificate),
	}, nil
}

// newSerial returns a random 127-bit certificate serial number.
func newSerial() (*big.Int, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, fmt.Errorf("ghproxy: serial: %w", err)
	}

	return serial, nil
}

// leaf returns a certificate for host signed by the authority, minting it on
// first use. A leaf expires with the authority, so a cached one is never
// stale.
func (c *ca) leaf(host string) (*tls.Certificate, error) {
	host = strings.ToLower(host)

	c.mu.Lock()
	defer c.mu.Unlock()

	if cert, ok := c.leaves[host]; ok {
		return cert, nil
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("ghproxy: leaf key: %w", err)
	}

	serial, err := newSerial()
	if err != nil {
		return nil, err
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-backdate),
		NotAfter:     c.cert.NotAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, &key.PublicKey, c.key)
	if err != nil {
		return nil, fmt.Errorf("ghproxy: leaf certificate for %s: %w", host, err)
	}

	cert := &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
	c.leaves[host] = cert

	return cert, nil
}
