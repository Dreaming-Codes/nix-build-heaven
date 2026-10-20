package certs

// SSH material for the ssh-ng transport, the counterpart of the TLS CA:
// a host CA whose key stays on the client host, a per-launch host key with a
// short-lived host certificate in user-data, and one client key whose public
// half the builder authorises from user-data. Nothing long-lived is in the AMI.

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSHUser is the builder account the client logs in as; it is a trusted Nix user.
const SSHUser = "nbh"

func newEd25519() (ed25519.PrivateKey, ssh.Signer, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	s, err := ssh.NewSignerFromKey(priv)
	return priv, s, err
}

func openSSHPEM(priv ed25519.PrivateKey, comment string) ([]byte, error) {
	b, err := ssh.MarshalPrivateKey(priv, comment)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(b), nil
}

// InitSSH creates ssh_host_ca, ssh_client and ssh_known_hosts once. It is
// separate from Init so an existing TLS-only pki directory gains SSH keys.
func (d Dir) InitSSH(clientComment string) error {
	if _, err := os.Stat(d.path("ssh_host_ca")); err == nil {
		return nil
	}
	if err := os.MkdirAll(string(d), 0o700); err != nil {
		return err
	}
	files := map[string][]byte{}
	for _, name := range []string{"ssh_host_ca", "ssh_client"} {
		priv, s, err := newEd25519()
		if err != nil {
			return err
		}
		p, err := openSSHPEM(priv, clientComment)
		if err != nil {
			return err
		}
		files[name] = p
		files[name+".pub"] = ssh.MarshalAuthorizedKey(s.PublicKey())
	}
	// The client trusts any host key the CA certified for BuilderName.
	files["ssh_known_hosts"] = []byte(fmt.Sprintf("@cert-authority %s %s", BuilderName, files["ssh_host_ca.pub"]))
	for name, data := range files {
		if err := os.WriteFile(d.path(name), data, 0o600); err != nil {
			return err
		}
	}
	return nil
}

func (d Dir) path(name string) string { return filepath.Join(string(d), name) }

// SSHAuthority is what the gate needs to mint builder user-data for ssh-ng.
type SSHAuthority struct {
	CA        ssh.Signer
	ClientPub []byte // authorized_keys line
}

func (d Dir) SSH() (SSHAuthority, error) {
	pemCA, err := os.ReadFile(d.path("ssh_host_ca"))
	if err != nil {
		return SSHAuthority{}, err
	}
	ca, err := ssh.ParsePrivateKey(pemCA)
	if err != nil {
		return SSHAuthority{}, err
	}
	pub, err := os.ReadFile(d.path("ssh_client.pub"))
	if err != nil {
		return SSHAuthority{}, err
	}
	if _, _, _, _, err := ssh.ParseAuthorizedKey(pub); err != nil {
		return SSHAuthority{}, errors.New("certs: ssh_client.pub is not an authorized_keys line")
	}
	return SSHAuthority{ca, pub}, nil
}

// SSHHost mints a fresh host key and a host certificate for BuilderName,
// valid from five minutes ago for ttl, like the TLS server certificate.
func (a SSHAuthority) SSHHost(now time.Time, ttl time.Duration) (keyPEM, certLine []byte, err error) {
	priv, s, err := newEd25519()
	if err != nil {
		return nil, nil, err
	}
	cert := &ssh.Certificate{
		Key:             s.PublicKey(),
		Serial:          uint64(now.UnixNano()),
		CertType:        ssh.HostCert,
		KeyId:           "nbh-builder " + now.UTC().Format(time.RFC3339),
		ValidPrincipals: []string{BuilderName},
		ValidAfter:      uint64(now.Add(-5 * time.Minute).Unix()),
		ValidBefore:     uint64(now.Add(ttl).Unix()),
	}
	if err := cert.SignCert(rand.Reader, a.CA); err != nil {
		return nil, nil, err
	}
	keyPEM, err = openSSHPEM(priv, BuilderName)
	if err != nil {
		return nil, nil, err
	}
	return keyPEM, ssh.MarshalAuthorizedKey(cert), nil
}

// WithSSH adds the ssh-ng material to user-data.
func (u *UserData) WithSSH(a SSHAuthority, now time.Time, ttl time.Duration) error {
	key, cert, err := a.SSHHost(now, ttl)
	if err != nil {
		return err
	}
	u.SSHHostKey, u.SSHHostCert, u.SSHAuthorizedKeys = string(key), string(cert), string(a.ClientPub)
	return nil
}
