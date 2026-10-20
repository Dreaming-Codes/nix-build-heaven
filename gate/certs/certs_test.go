package certs

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"
)

func TestMutualTLSWithMintedUserData(t *testing.T) {
	now := time.Now()
	dir := Dir(t.TempDir())
	if err := dir.Init(now, "DreamingDesk"); err != nil {
		t.Fatal(err)
	}
	ca, err := dir.CA()
	if err != nil {
		t.Fatal(err)
	}
	srv, err := Server(ca, now, 3*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	var ud UserData
	if err := json.Unmarshal(NewUserData(ca, srv), &ud); err != nil {
		t.Fatal(err)
	}
	if len(NewUserData(ca, srv)) > 16384 {
		t.Fatal("user-data over the EC2 16 KiB limit")
	}
	serverCert, err := tls.X509KeyPair([]byte(ud.ServerCert), []byte(ud.ServerKey))
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM([]byte(ud.ClientCA))
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{serverCert}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	clientCert, err := tls.LoadX509KeyPair(string(dir)+"/client.crt", string(dir)+"/client.key")
	if err != nil {
		t.Fatal(err)
	}
	dial := func(certs []tls.Certificate) error {
		c, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", ln.Addr().String(), &tls.Config{RootCAs: pool, ServerName: BuilderName, Certificates: certs})
		if err != nil {
			return err
		}
		defer c.Close()
		if _, err := c.Write([]byte("x")); err != nil {
			return err
		}
		_, err = c.Read(make([]byte, 1))
		return err
	}
	if err := dial([]tls.Certificate{clientCert}); err != nil {
		t.Fatalf("client with CA-signed cert rejected: %v", err)
	}
	if err := dial(nil); err == nil {
		t.Fatal("client without a certificate was accepted")
	}
	other, _ := NewCA(now)
	stranger, _ := Client(other, "stranger", now)
	if err := dial([]tls.Certificate{{Certificate: [][]byte{stranger.Cert.Raw}, PrivateKey: stranger.Key}}); err == nil {
		t.Fatal("client signed by another CA was accepted")
	}
}

func TestInitKeepsExistingCA(t *testing.T) {
	dir := Dir(t.TempDir())
	dir.Init(time.Now(), "a")
	first, _ := dir.CA()
	dir.Init(time.Now(), "a")
	second, _ := dir.CA()
	if !first.Cert.Equal(second.Cert) {
		t.Fatal("Init replaced an existing CA")
	}
}
