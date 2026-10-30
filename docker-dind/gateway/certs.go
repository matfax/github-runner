package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"
)

// certStore holds the server certificate and the trusted client CAs, and reloads them when the
// files change. Kubernetes updates mounted Secrets in place (cert-manager renewals, rotated CAs),
// so certificates are picked up without restarting the gateway or any tenant daemon.
type certStore struct {
	certPath, keyPath, caPath string

	mu   sync.RWMutex
	sum  [32]byte
	cert *tls.Certificate
	cas  *x509.CertPool
}

func newCertStore(certPath, keyPath, caPath string) *certStore {
	return &certStore{certPath: certPath, keyPath: keyPath, caPath: caPath}
}

// load reads the files and swaps them in if they changed. It reports whether anything changed.
func (s *certStore) load() (bool, error) {
	var raw [3][]byte
	for i, p := range []string{s.certPath, s.keyPath, s.caPath} {
		b, err := os.ReadFile(p)
		if err != nil {
			return false, err
		}
		raw[i] = b
	}
	sum := sha256.Sum256(bytes.Join(raw[:], []byte{0}))
	s.mu.RLock()
	same := s.cert != nil && sum == s.sum
	s.mu.RUnlock()
	if same {
		return false, nil
	}

	cert, err := tls.X509KeyPair(raw[0], raw[1])
	if err != nil {
		return false, fmt.Errorf("server certificate %s: %w", s.certPath, err)
	}
	cas := x509.NewCertPool()
	if !cas.AppendCertsFromPEM(raw[2]) {
		return false, fmt.Errorf("client CA %s holds no PEM certificates", s.caPath)
	}

	s.mu.Lock()
	s.sum, s.cert, s.cas = sum, &cert, cas
	s.mu.Unlock()
	if leaf := cert.Leaf; leaf != nil {
		slog.Info("loaded TLS certificates", "subject", leaf.Subject.String(), "dnsNames", leaf.DNSNames, "notAfter", leaf.NotAfter.Format(time.RFC3339))
	}
	return true, nil
}

// watch reloads the files every interval. A failed reload keeps serving the previous certificates,
// since a Secret update can briefly expose a new certificate next to the old key.
func (s *certStore) watch(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if _, err := s.load(); err != nil {
				slog.Warn("TLS reload failed, keeping current certificates", "err", err)
			}
		}
	}
}

func (s *certStore) current() (*tls.Certificate, *x509.CertPool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cert, s.cas
}

// tlsConfig requires a client certificate that chains to the client CA on every connection,
// using whatever certificates are current when the handshake starts.
func (s *certStore) tlsConfig() *tls.Config {
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
			cert, cas := s.current()
			if cert == nil {
				return nil, errors.New("no server certificate loaded")
			}
			return &tls.Config{
				MinVersion:   tls.VersionTLS12,
				Certificates: []tls.Certificate{*cert},
				ClientAuth:   tls.RequireAndVerifyClientCert,
				ClientCAs:    cas,
			}, nil
		},
	}
}
