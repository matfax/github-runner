package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// tenantNetwork is the Docker name of each tenant's NAT network. Every tenant daemon also sees the
// other tenants' networks (HNS networks are host-wide), which the policy refuses.
const tenantNetwork = "build"

// errBusy means no tenant daemon can be started until another one goes idle.
var errBusy = errors.New("too many tenant daemons are running; retry later")

// Manager starts a dockerd per tenant on first use and stops it once idle.
type Manager struct {
	cfg     *Config
	base    map[string]any
	subnets *subnetStore

	mu      sync.Mutex
	daemons map[string]*daemon
	closing bool
}

type daemon struct {
	m      *Manager
	tenant Tenant
	dir    string
	host   string
	addr   string
	policy *Policy
	proxy  *httputil.ReverseProxy
	tr     *http.Transport

	// startMu serializes starting and stopping.
	startMu sync.Mutex

	mu       sync.Mutex
	running  bool
	starting bool
	inflight int
	lastUsed time.Time
	cmd      *exec.Cmd
	exited   chan struct{}
}

func newManager(cfg *Config) (*Manager, error) {
	base := map[string]any{}
	if b, err := os.ReadFile(cfg.BaseDaemonConfig); err == nil {
		if err := json.Unmarshal(b, &base); err != nil {
			return nil, fmt.Errorf("%s: %w", cfg.BaseDaemonConfig, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, dir := range []string{cfg.DataRoot, cfg.ExecRoot} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	}
	subnets, err := openSubnetStore(filepath.Join(cfg.DataRoot, "subnets.json"), cfg.Network.Pool, cfg.Network.PrefixLength)
	if err != nil {
		return nil, err
	}
	return &Manager{cfg: cfg, base: base, subnets: subnets, daemons: map[string]*daemon{}}, nil
}

// Acquire returns the tenant's running daemon, starting it if needed. The caller must call
// release once its request is done; a daemon with requests in flight is never stopped.
func (m *Manager) Acquire(ctx context.Context, t Tenant) (*daemon, func(), error) {
	m.mu.Lock()
	if m.closing {
		m.mu.Unlock()
		return nil, nil, errors.New("gateway is shutting down")
	}
	d := m.daemons[t.ID]
	if d == nil {
		d = m.newDaemon(t)
		m.daemons[t.ID] = d
	}
	m.mu.Unlock()
	if d.tenant.Name != t.Name {
		return nil, nil, fmt.Errorf("tenant ID %s of %s is already used by %s", t.ID, t.Name, d.tenant.Name)
	}

	d.mu.Lock()
	d.inflight++
	d.lastUsed = time.Now()
	d.mu.Unlock()
	release := func() {
		d.mu.Lock()
		d.inflight--
		d.lastUsed = time.Now()
		d.mu.Unlock()
	}
	if err := d.ensureRunning(ctx); err != nil {
		release()
		return nil, nil, err
	}
	return d, release, nil
}

func (m *Manager) newDaemon(t Tenant) *daemon {
	host, addr := tenantEndpoint(m.cfg.ExecRoot, t.ID)
	d := &daemon{
		m:      m,
		tenant: t,
		dir:    filepath.Join(m.cfg.DataRoot, t.ID),
		host:   host,
		addr:   addr,
		policy: &Policy{Network: tenantNetwork, Isolation: m.cfg.Isolation, Tenant: t.Name},
	}
	d.tr = &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialTenant(ctx, d.addr)
		},
		DisableCompression:  true,
		MaxIdleConnsPerHost: 16,
		IdleConnTimeout:     90 * time.Second,
	}
	d.proxy = &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			// Send the path the policy checked, re-encoded from its decoded form.
			pr.Out.URL.RawPath = ""
			pr.Out.URL.Scheme = "http"
			pr.Out.URL.Host = "docker"
			pr.Out.Host = "docker"
		},
		Transport: d.tr,
		// Build output, logs and events stream; flush every write.
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			slog.Warn("proxying to tenant daemon failed", "tenant", t.Name, "path", r.URL.Path, "err", err)
			writeError(w, http.StatusBadGateway, "docker-dind: tenant daemon unavailable")
		},
	}
	return d
}

// reserve claims one of the MaxRunning slots for d, counting daemons that are still starting so
// concurrent first requests of different tenants cannot exceed the cap.
func (m *Manager) reserve(d *daemon) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, o := range m.daemons {
		if o == d {
			continue
		}
		o.mu.Lock()
		if o.running || o.starting {
			n++
		}
		o.mu.Unlock()
	}
	if n >= m.cfg.Tenants.MaxRunning {
		return false
	}
	d.mu.Lock()
	d.starting = true
	d.mu.Unlock()
	return true
}

func (d *daemon) isRunning() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.running
}

func (d *daemon) ensureRunning(ctx context.Context) error {
	d.startMu.Lock()
	defer d.startMu.Unlock()
	if d.isRunning() {
		return nil
	}
	if !d.m.reserve(d) && (!d.m.evictIdle(ctx, d) || !d.m.reserve(d)) {
		return errBusy
	}
	defer func() {
		d.mu.Lock()
		d.starting = false
		d.mu.Unlock()
	}()
	return d.start(ctx)
}

func (d *daemon) start(ctx context.Context) error {
	log := slog.With("tenant", d.tenant.Name, "id", d.tenant.ID)
	execRoot := filepath.Join(d.m.cfg.ExecRoot, d.tenant.ID)
	for _, dir := range []string{d.dir, execRoot} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	if err := d.claimDir(); err != nil {
		return err
	}
	cfgPath := filepath.Join(d.dir, "daemon.json")
	b, err := json.MarshalIndent(d.m.daemonConfig(d.tenant, d.host, execRoot), "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(cfgPath, b, 0o600); err != nil {
		return err
	}

	cmd := exec.Command(d.m.cfg.Dockerd, "--config-file", cfgPath)
	out := &prefixWriter{prefix: "[" + d.tenant.ID + "] "}
	cmd.Stdout, cmd.Stderr = out, out
	if err := startProcess(cmd); err != nil {
		return fmt.Errorf("starting dockerd for %s: %w", d.tenant.Name, err)
	}
	exited := make(chan struct{})
	go func() {
		err := cmd.Wait()
		out.Flush()
		d.mu.Lock()
		d.running = false
		d.mu.Unlock()
		d.tr.CloseIdleConnections()
		log.Info("tenant daemon exited", "err", err)
		close(exited)
	}()
	d.mu.Lock()
	d.cmd, d.exited = cmd, exited
	d.mu.Unlock()
	log.Info("starting tenant daemon", "pid", cmd.Process.Pid)

	if err := d.waitReady(ctx, exited); err != nil {
		d.kill()
		return err
	}
	if err := d.ensureNetwork(ctx); err != nil {
		d.kill()
		return fmt.Errorf("creating the build network for %s: %w", d.tenant.Name, err)
	}
	d.mu.Lock()
	d.running = true
	d.lastUsed = time.Now()
	d.mu.Unlock()
	log.Info("tenant daemon ready")
	return nil
}

// claimDir records which repository a tenant directory belongs to and refuses to reuse it for
// another one, should two names ever map to the same ID.
func (d *daemon) claimDir() error {
	path := filepath.Join(d.dir, "tenant.json")
	var owner struct{ Name string }
	if b, err := os.ReadFile(path); err == nil {
		if json.Unmarshal(b, &owner) == nil && owner.Name != "" && owner.Name != d.tenant.Name {
			return fmt.Errorf("tenant directory %s belongs to %s, not %s", d.dir, owner.Name, d.tenant.Name)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	owner.Name = d.tenant.Name
	b, _ := json.Marshal(owner)
	return os.WriteFile(path, b, 0o600)
}

// daemonConfig derives a tenant's daemon.json from the base config. Everything that must differ
// between tenants (endpoint, storage, containerd namespace) or that the gateway relies on is set
// here and overrides the base.
func (m *Manager) daemonConfig(t Tenant, host, execRoot string) map[string]any {
	c := make(map[string]any, len(m.base)+12)
	for k, v := range m.base {
		c[k] = v
	}
	for _, k := range []string{"hosts", "tls", "tlsverify", "tlscacert", "tlscert", "tlskey", "graph",
		"group", "fixed-cidr", "default-address-pools", "iptables", "ip-forward", "debug-addr"} {
		delete(c, k)
	}
	c["hosts"] = []string{host}
	c["data-root"] = filepath.Join(m.cfg.DataRoot, t.ID, "docker")
	c["exec-root"] = execRoot
	c["pidfile"] = filepath.Join(m.cfg.DataRoot, t.ID, "docker.pid")
	c["containerd"] = m.cfg.Containerd
	c["containerd-namespace"] = t.ID
	c["containerd-plugins-namespace"] = t.ID + ".plugins"
	// No default "nat" network: the gateway creates the tenant's own network after startup.
	c["bridge"] = "none"
	if len(m.cfg.Network.DNS) > 0 {
		c["dns"] = m.cfg.Network.DNS
	}
	var opts []any
	for _, o := range list(c["exec-opts"]) {
		if s := str(o); !strings.HasPrefix(strings.ToLower(s), "isolation=") {
			opts = append(opts, o)
		}
	}
	c["exec-opts"] = append(opts, "isolation="+m.cfg.Isolation)
	return c
}

func (d *daemon) waitReady(ctx context.Context, exited <-chan struct{}) error {
	ctx, cancel := context.WithTimeout(ctx, d.m.cfg.Tenants.StartTimeout.Duration)
	defer cancel()
	for {
		if resp, err := d.api(ctx, http.MethodGet, "/_ping", nil); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		select {
		case <-exited:
			return fmt.Errorf("dockerd for %s exited during startup; see its log lines prefixed [%s]", d.tenant.Name, d.tenant.ID)
		case <-ctx.Done():
			return fmt.Errorf("dockerd for %s did not become ready: %w", d.tenant.Name, ctx.Err())
		case <-time.After(250 * time.Millisecond):
		}
	}
}

// ensureNetwork creates the tenant's NAT network on a subnet of its own. The subnet stays
// allocated to the tenant, so the network keeps its range across restarts.
func (d *daemon) ensureNetwork(ctx context.Context) error {
	resp, err := d.api(ctx, http.MethodGet, "/networks/"+tenantNetwork, nil)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}

	tried := map[string]bool{}
	var lastErr error
	for range 16 {
		subnet, err := d.m.subnets.allocate(d.tenant.ID, tried)
		if err != nil {
			return errors.Join(err, lastErr)
		}
		body := map[string]any{
			"Name":   tenantNetwork,
			"Driver": "nat",
			"IPAM":   map[string]any{"Driver": "default", "Config": []any{map[string]any{"Subnet": subnet}}},
			"Options": map[string]string{
				"com.docker.network.windowsshim.networkname":        "docker-dind-" + d.tenant.ID,
				"com.docker.network.windowsshim.dnsservers":         strings.Join(d.m.cfg.Network.DNS, ","),
				"com.docker.network.windowsshim.disable_gatewaydns": "true",
			},
			"Labels": map[string]string{tenantLabel: d.tenant.Name},
		}
		resp, err := d.api(ctx, http.MethodPost, "/networks/create", body)
		if err != nil {
			return err
		}
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if resp.StatusCode == http.StatusCreated || resp.StatusCode == http.StatusOK {
			slog.Info("created tenant network", "tenant", d.tenant.Name, "subnet", subnet)
			return nil
		}
		// Most likely the subnet overlaps a network the gateway does not know about; try the next one.
		lastErr = fmt.Errorf("subnet %s: %s", subnet, bytes.TrimSpace(msg))
		slog.Warn("creating tenant network failed", "tenant", d.tenant.Name, "err", lastErr)
		tried[subnet] = true
	}
	return lastErr
}

func (d *daemon) api(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, rd)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return d.tr.RoundTrip(req)
}

// runningContainers counts the tenant's running containers, so a daemon serving e.g. a service
// container started with "docker run -d" is not stopped between job steps.
func (d *daemon) runningContainers(ctx context.Context) (int, error) {
	resp, err := d.api(ctx, http.MethodGet, "/containers/json", nil)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("listing containers: %s", resp.Status)
	}
	var cs []json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&cs); err != nil {
		return 0, err
	}
	return len(cs), nil
}

// idleSince reports whether the daemon is running with nothing in flight since cutoff or earlier.
func (d *daemon) idleSince(cutoff time.Time) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.running && d.inflight == 0 && !d.lastUsed.After(cutoff)
}

// stopIfIdle stops the daemon if it is still idle and has no running containers. Running
// containers keep it alive only until forceCutoff (zero: indefinitely), so they cannot hold one of
// the MaxRunning slots forever.
func (d *daemon) stopIfIdle(ctx context.Context, cutoff, forceCutoff time.Time) bool {
	d.startMu.Lock()
	defer d.startMu.Unlock()
	if !d.idleSince(cutoff) {
		return false
	}
	if forceCutoff.IsZero() || !d.idleSince(forceCutoff) {
		n, err := d.runningContainers(ctx)
		if err != nil || n > 0 {
			return false
		}
	}
	slog.Info("stopping idle tenant daemon", "tenant", d.tenant.Name)
	d.stop(30 * time.Second)
	return true
}

// stop shuts dockerd down, killing it if it does not exit within timeout. The caller holds startMu.
func (d *daemon) stop(timeout time.Duration) {
	d.mu.Lock()
	cmd, exited := d.cmd, d.exited
	d.running = false
	d.mu.Unlock()
	if cmd == nil || exited == nil {
		return
	}
	select {
	case <-exited:
		return
	default:
	}
	if err := interruptProcess(cmd.Process); err == nil {
		select {
		case <-exited:
			return
		case <-time.After(timeout):
		}
	}
	d.kill()
}

func (d *daemon) kill() {
	d.mu.Lock()
	cmd, exited := d.cmd, d.exited
	d.running = false
	d.mu.Unlock()
	if cmd == nil || exited == nil {
		return
	}
	_ = cmd.Process.Kill()
	<-exited
}

// evictIdle stops the least recently used idle daemon other than keep, to make room for keep.
func (m *Manager) evictIdle(ctx context.Context, keep *daemon) bool {
	m.mu.Lock()
	var candidates []*daemon
	for _, d := range m.daemons {
		if d != keep {
			candidates = append(candidates, d)
		}
	}
	m.mu.Unlock()
	for {
		var lru *daemon
		var lruTime time.Time
		for _, d := range candidates {
			d.mu.Lock()
			if d.running && d.inflight == 0 && (lru == nil || d.lastUsed.Before(lruTime)) {
				lru, lruTime = d, d.lastUsed
			}
			d.mu.Unlock()
		}
		if lru == nil {
			return false
		}
		if lru.stopIfIdle(ctx, time.Now(), time.Time{}) {
			return true
		}
		for i, d := range candidates {
			if d == lru {
				candidates = append(candidates[:i], candidates[i+1:]...)
				break
			}
		}
	}
}

// reap stops daemons idle for longer than the idle timeout.
func (m *Manager) reap(ctx context.Context) {
	idle := m.cfg.Tenants.IdleTimeout.Duration
	t := time.NewTicker(max(idle/4, 15*time.Second))
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		m.mu.Lock()
		ds := make([]*daemon, 0, len(m.daemons))
		for _, d := range m.daemons {
			ds = append(ds, d)
		}
		m.mu.Unlock()
		now := time.Now()
		cutoff := now.Add(-idle)
		forceCutoff := now.Add(-m.cfg.Tenants.ContainerIdleTimeout.Duration)
		for _, d := range ds {
			if d.idleSince(cutoff) {
				d.stopIfIdle(ctx, cutoff, forceCutoff)
			}
		}
	}
}

// StopAll stops every daemon, used when the gateway shuts down.
func (m *Manager) StopAll(timeout time.Duration) {
	m.mu.Lock()
	m.closing = true
	ds := make([]*daemon, 0, len(m.daemons))
	for _, d := range m.daemons {
		ds = append(ds, d)
	}
	m.mu.Unlock()
	var wg sync.WaitGroup
	for _, d := range ds {
		wg.Add(1)
		go func() {
			defer wg.Done()
			d.startMu.Lock()
			defer d.startMu.Unlock()
			d.stop(timeout)
		}()
	}
	wg.Wait()
}

// prefixWriter writes a child's output line by line with a prefix naming the tenant.
type prefixWriter struct {
	prefix string
	mu     sync.Mutex
	buf    []byte
}

func (w *prefixWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		os.Stdout.Write(append([]byte(w.prefix), w.buf[:i+1]...))
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}

func (w *prefixWriter) Flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.buf) > 0 {
		os.Stdout.Write(append(append([]byte(w.prefix), w.buf...), '\n'))
		w.buf = nil
	}
}
