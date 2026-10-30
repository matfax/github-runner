// Command gateway is the mutual-TLS front end of the docker-dind service. It authenticates each
// client certificate, maps its owner/repo identity to that repository's own dockerd (started on
// first use, stopped when idle), screens the request and proxies it over the daemon's named pipe.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

var version = "dev"

// acquireFunc returns the tenant's policy and handler, plus a release func to call when done.
type acquireFunc func(ctx context.Context, t Tenant) (*Policy, http.Handler, func(), error)

type gateway struct {
	allowed []string
	acquire acquireFunc
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 || len(r.TLS.VerifiedChains[0]) == 0 {
		writeError(w, http.StatusUnauthorized, "docker-dind: a verified client certificate is required")
		return
	}
	name, err := identityFromCert(r.TLS.VerifiedChains[0][0])
	if err != nil {
		writeError(w, http.StatusForbidden, "docker-dind: "+err.Error())
		return
	}
	if !allowedTenant(g.allowed, name) {
		slog.Warn("identity not allowed", "tenant", name, "remote", r.RemoteAddr)
		writeError(w, http.StatusForbidden, fmt.Sprintf("docker-dind: %s may not use this service", name))
		return
	}
	t := newTenant(name)
	policy, h, release, err := g.acquire(r.Context(), t)
	if err != nil {
		slog.Error("tenant daemon unavailable", "tenant", name, "err", err)
		writeError(w, http.StatusServiceUnavailable, "docker-dind: "+err.Error())
		return
	}
	defer release()
	if perr := policy.Apply(r); perr != nil {
		slog.Warn("request refused", "tenant", name, "method", r.Method, "path", r.URL.Path, "reason", perr.msg)
		writeError(w, perr.status, perr.msg)
		return
	}
	h.ServeHTTP(w, r)
}

// writeError answers in the Docker API's error format, which the docker CLI prints as is.
func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": msg})
}

func main() {
	configPath := flag.String("config", `C:\dind\gateway.json`, "gateway configuration file")
	check := flag.Bool("check", false, "validate the configuration and certificates, then exit")
	plan := flag.Bool("firewall-plan", false, "print the tenant pool and the ranges build containers may not reach as JSON, then exit")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	if *plan {
		if err := printFirewallPlan(*configPath); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := run(*configPath, *check); err != nil {
		slog.Error("gateway failed", "err", err)
		os.Exit(1)
	}
}

// printFirewallPlan tells start.ps1 which Windows Firewall rules to create for build containers.
func printFirewallPlan(configPath string) error {
	cfg, err := loadConfig(configPath)
	if err != nil {
		return err
	}
	host, err := hostAddresses()
	if err != nil {
		return err
	}
	ranges, err := egressBlockRanges(cfg, host)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"pool": cfg.Network.Pool, "block": ranges})
}

func run(configPath string, check bool) error {
	cfg, err := loadConfig(configPath)
	if err != nil {
		return err
	}
	certs := newCertStore(cfg.TLS.Cert, cfg.TLS.Key, cfg.TLS.ClientCA)
	if _, err := certs.load(); err != nil {
		return err
	}
	if check {
		fmt.Println("configuration and certificates are valid")
		return nil
	}
	mgr, err := newManager(cfg)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	gw := &gateway{
		allowed: cfg.Tenants.Allowed,
		acquire: func(ctx context.Context, t Tenant) (*Policy, http.Handler, func(), error) {
			d, release, err := mgr.Acquire(ctx, t)
			if err != nil {
				return nil, nil, nil, err
			}
			return d.policy, d.proxy, release, nil
		},
	}
	srv := &http.Server{
		Handler:           gw,
		TLSConfig:         certs.tlsConfig(),
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       5 * time.Minute,
		MaxHeaderBytes:    1 << 20,
		ErrorLog:          log.New(&probeFilter{}, "", 0),
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	slog.Info("docker-dind gateway listening", "version", version, "addr", ln.Addr().String(), "isolation", cfg.Isolation)

	go certs.watch(ctx, cfg.TLS.ReloadInterval.Duration)
	go mgr.reap(ctx)
	errc := make(chan error, 1)
	go func() { errc <- srv.ServeTLS(ln, "", "") }()

	select {
	case err = <-errc:
	case <-ctx.Done():
		slog.Info("shutting down")
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	mgr.StopAll(20 * time.Second)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// probeFilter drops the handshake errors of TCP probes and port scans (connections closed before
// a TLS hello) and logs everything else.
type probeFilter struct{}

func (probeFilter) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte("TLS handshake error")) && bytes.HasSuffix(bytes.TrimSpace(p), []byte("EOF")) {
		return len(p), nil
	}
	slog.Warn(string(bytes.TrimSpace(p)))
	return len(p), nil
}
