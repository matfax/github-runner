package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type testCA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte
}

func newTestCA(t *testing.T, cn string) *testCA {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: cn},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return &testCA{cert: c, key: key, pem: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

// issue returns PEM certificate and key signed by the CA.
func (ca *testCA) issue(t *testing.T, cn string, usage x509.ExtKeyUsage, dns ...string) ([]byte, []byte) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{usage},
		DNSNames:     dns,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := x509.MarshalECPrivateKey(key)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb})
}

// fakeDocker answers like a tenant dockerd: it echoes create bodies and implements a hijacked
// attach that replies only after the client half-closes its side.
func fakeDocker(t *testing.T, ln net.Listener) {
	mux := http.NewServeMux()
	mux.HandleFunc("/_ping", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "OK") })
	mux.HandleFunc("/v1.47/containers/create", func(w http.ResponseWriter, r *http.Request) { io.Copy(w, r.Body) })
	mux.HandleFunc("/v1.47/containers/x/attach", func(w http.ResponseWriter, r *http.Request) {
		conn, brw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		brw.WriteString("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
		brw.Flush()
		in, _ := io.ReadAll(brw)
		conn.Write([]byte("got:" + string(in)))
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
}

func TestGatewayEndToEnd(t *testing.T) {
	dir := t.TempDir()
	ca := newTestCA(t, "test CA")
	otherCA := newTestCA(t, "other CA")
	srvCert, srvKey := ca.issue(t, "docker-dind", x509.ExtKeyUsageServerAuth, "localhost")
	write := func(name string, b []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	certs := newCertStore(write("tls.crt", srvCert), write("tls.key", srvKey), write("ca.crt", ca.pem))
	if _, err := certs.load(); err != nil {
		t.Fatal(err)
	}

	cfg := defaultConfig()
	cfg.ExecRoot = dir
	m := &Manager{cfg: cfg, daemons: map[string]*daemon{}}
	var mu sync.Mutex
	acquired := map[string]int{}
	gw := &gateway{
		allowed: []string{"matfax/*"},
		acquire: func(_ context.Context, tn Tenant) (*Policy, http.Handler, func(), error) {
			mu.Lock()
			defer mu.Unlock()
			acquired[tn.Name]++
			d := m.daemons[tn.ID]
			if d == nil {
				d = m.newDaemon(tn)
				m.daemons[tn.ID] = d
				fakeDocker(t, listenTenant(t, d.addr))
			}
			return d.policy, d.proxy, func() {}, nil
		},
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", certs.tlsConfig())
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: gw}
	go srv.Serve(ln)
	defer srv.Close()
	addr := ln.Addr().String()

	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(ca.pem)
	client := func(certPEM, keyPEM []byte) *http.Client {
		cfg := &tls.Config{RootCAs: roots, ServerName: "localhost"}
		if certPEM != nil {
			c, err := tls.X509KeyPair(certPEM, keyPEM)
			if err != nil {
				t.Fatal(err)
			}
			cfg.Certificates = []tls.Certificate{c}
		}
		return &http.Client{Transport: &http.Transport{TLSClientConfig: cfg}, Timeout: 10 * time.Second}
	}
	get := func(c *http.Client, method, path, body string) (int, string, error) {
		req, _ := http.NewRequest(method, "https://"+addr+path, strings.NewReader(body))
		resp, err := c.Do(req)
		if err != nil {
			return 0, "", err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b), nil
	}

	if _, _, err := get(client(nil, nil), "GET", "/_ping", ""); err == nil {
		t.Error("a client without a certificate must be refused")
	}
	foreignCert, foreignKey := otherCA.issue(t, "matfax/repo", x509.ExtKeyUsageClientAuth)
	if _, _, err := get(client(foreignCert, foreignKey), "GET", "/_ping", ""); err == nil {
		t.Error("a client certificate from another CA must be refused")
	}
	serverUsage, serverUsageKey := ca.issue(t, "matfax/repo", x509.ExtKeyUsageServerAuth)
	if _, _, err := get(client(serverUsage, serverUsageKey), "GET", "/_ping", ""); err == nil {
		t.Error("a certificate without client-auth usage must be refused")
	}
	badCert, badKey := ca.issue(t, "not a repo", x509.ExtKeyUsageClientAuth)
	if code, _, err := get(client(badCert, badKey), "GET", "/_ping", ""); err != nil || code != http.StatusForbidden {
		t.Errorf("invalid identity: %d, %v; want 403", code, err)
	}
	strangerCert, strangerKey := ca.issue(t, "someone/repo", x509.ExtKeyUsageClientAuth)
	if code, _, err := get(client(strangerCert, strangerKey), "GET", "/_ping", ""); err != nil || code != http.StatusForbidden {
		t.Errorf("identity outside tenants.allowed: %d, %v; want 403", code, err)
	}

	repoCert, repoKey := ca.issue(t, "MatFax/Repo", x509.ExtKeyUsageClientAuth)
	c := client(repoCert, repoKey)
	if code, body, err := get(c, "GET", "/_ping", ""); err != nil || code != 200 || body != "OK" {
		t.Fatalf("ping: %d %q %v", code, body, err)
	}
	mu.Lock()
	n := acquired["matfax/repo"]
	mu.Unlock()
	if n == 0 {
		t.Error("the request did not reach the tenant matfax/repo")
	}
	if code, body, _ := get(c, "POST", "/v1.47/containers/create", `{"HostConfig":{}}`); code != 200 || !strings.Contains(body, `"NetworkMode":"build"`) {
		t.Errorf("create was not rewritten: %d %s", code, body)
	}
	if code, body, _ := get(c, "POST", "/v1.47/containers/create", `{"HostConfig":{"Binds":["C:\\:C:\\h"]}}`); code != http.StatusForbidden || !strings.Contains(body, "bind mount") {
		t.Errorf("bind mount: %d %s; want 403", code, body)
	}

	// Hijacked streams must survive the client closing its write side (docker run -i with stdin).
	cert, _ := tls.X509KeyPair(repoCert, repoKey)
	conn, err := tls.Dial("tcp", addr, &tls.Config{RootCAs: roots, ServerName: "localhost", Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	io.WriteString(conn, "POST /v1.47/containers/x/attach?stream=1&stdin=1 HTTP/1.1\r\nHost: docker\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("attach: %v %v", resp, err)
	}
	io.WriteString(conn, "hello")
	if err := conn.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	out, _ := io.ReadAll(br)
	if string(out) != "got:hello" {
		t.Errorf("attach output %q, want %q", out, "got:hello")
	}

	// A renewed server certificate is served without restarting.
	newCert, newKey := ca.issue(t, "docker-dind-renewed", x509.ExtKeyUsageServerAuth, "localhost")
	write("tls.crt", newCert)
	write("tls.key", newKey)
	if changed, err := certs.load(); err != nil || !changed {
		t.Fatalf("reload: %v %v", changed, err)
	}
	rc, err := tls.Dial("tcp", addr, &tls.Config{RootCAs: roots, ServerName: "localhost", Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatal(err)
	}
	if cn := rc.ConnectionState().PeerCertificates[0].Subject.CommonName; cn != "docker-dind-renewed" {
		t.Errorf("served %q after reload", cn)
	}
	rc.Close()
}
