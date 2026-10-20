package certs

import (
	"bytes"
	"net"
	"os"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// handshake runs one SSH handshake between a server holding the minted host
// key and certificate and a client that trusts trustCA for BuilderName.
func handshake(t *testing.T, keyPEM, certLine []byte, clientKey ssh.Signer, authorized []byte, trustCA ssh.PublicKey) error {
	host, err := ssh.ParsePrivateKey(keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey(certLine)
	if err != nil {
		t.Fatal(err)
	}
	hostSigner, err := ssh.NewCertSigner(pub.(*ssh.Certificate), host)
	if err != nil {
		t.Fatal(err)
	}
	authKey, _, _, _, _ := ssh.ParseAuthorizedKey(authorized)
	srvCfg := &ssh.ServerConfig{PublicKeyCallback: func(m ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
		if m.User() == SSHUser && bytes.Equal(k.Marshal(), authKey.Marshal()) {
			return nil, nil
		}
		return nil, net.ErrClosed
	}}
	srvCfg.AddHostKey(hostSigner)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		a, err := ln.Accept()
		if err != nil {
			return
		}
		a.SetDeadline(time.Now().Add(5 * time.Second))
		ssh.NewServerConn(a, srvCfg)
		a.Close()
	}()
	b, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	b.SetDeadline(time.Now().Add(5 * time.Second))
	checker := &ssh.CertChecker{IsHostAuthority: func(k ssh.PublicKey, addr string) bool {
		return bytes.Equal(k.Marshal(), trustCA.Marshal())
	}}
	c, _, _, err := ssh.NewClientConn(b, BuilderName+":22", &ssh.ClientConfig{
		User: SSHUser, Auth: []ssh.AuthMethod{ssh.PublicKeys(clientKey)}, HostKeyCallback: checker.CheckHostKey,
	})
	if c != nil {
		c.Close()
	}
	return err
}

func TestSSHHostCertTrustedOnlyViaOurCA(t *testing.T) {
	d := Dir(t.TempDir())
	if err := d.InitSSH("desk"); err != nil {
		t.Fatal(err)
	}
	a, err := d.SSH()
	if err != nil {
		t.Fatal(err)
	}
	clientPEM, _ := readFile(t, d.path("ssh_client"))
	client, err := ssh.ParsePrivateKey(clientPEM)
	if err != nil {
		t.Fatal(err)
	}
	key, cert, err := a.SSHHost(time.Now(), 3*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if err := handshake(t, key, cert, client, a.ClientPub, a.CA.PublicKey()); err != nil {
		t.Fatalf("our CA, our client: %v", err)
	}
	_, foreign, _ := newEd25519()
	if err := handshake(t, key, cert, client, a.ClientPub, foreign.PublicKey()); err == nil {
		t.Fatal("client accepted a host certified by a CA it does not trust")
	}
	_, stranger, _ := newEd25519()
	if err := handshake(t, key, cert, stranger, a.ClientPub, a.CA.PublicKey()); err == nil {
		t.Fatal("builder accepted a client key it was not given")
	}
	expired, expiredCert, _ := a.SSHHost(time.Now().Add(-4*time.Hour), 3*time.Hour)
	if err := handshake(t, expired, expiredCert, client, a.ClientPub, a.CA.PublicKey()); err == nil {
		t.Fatal("client accepted an expired host certificate")
	}
	kh, _ := readFile(t, d.path("ssh_known_hosts"))
	if !bytes.HasPrefix(kh, []byte("@cert-authority nbh-builder ssh-ed25519 ")) {
		t.Fatalf("known_hosts: %q", kh)
	}
}

func readFile(t *testing.T, p string) ([]byte, error) {
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b, nil
}
