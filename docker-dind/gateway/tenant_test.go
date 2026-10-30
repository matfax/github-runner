package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestMain lets the test binary stand in for dockerd: started with FAKE_DOCKERD=1 it reads the
// config file the gateway wrote and serves a minimal Docker API on its "hosts" endpoint.
func TestMain(m *testing.M) {
	if os.Getenv("FAKE_DOCKERD") == "1" {
		fakeDockerd()
		return
	}
	os.Exit(m.Run())
}

func fakeDockerd() {
	var cfgPath string
	for i, a := range os.Args {
		if a == "--config-file" && i+1 < len(os.Args) {
			cfgPath = os.Args[i+1]
		}
	}
	var cfg map[string]any
	b, err := os.ReadFile(cfgPath)
	if err != nil || json.Unmarshal(b, &cfg) != nil {
		os.Exit(2)
	}
	host := str(list(cfg["hosts"])[0])
	addr := strings.TrimPrefix(host, "unix://")
	if name, ok := strings.CutPrefix(host, "npipe:////./pipe/"); ok {
		addr = `\\.\pipe\` + name
	}
	ln, err := listenFake(addr)
	if err != nil {
		os.Exit(4)
	}
	var networkCreated atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/_ping", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "OK") })
	mux.HandleFunc("/networks/build", func(w http.ResponseWriter, _ *http.Request) {
		if !networkCreated.Load() {
			http.Error(w, `{"message":"network build not found"}`, http.StatusNotFound)
		}
	})
	mux.HandleFunc("/networks/create", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		subnet := str(obj(list(obj(body["IPAM"])["Config"])[0])["Subnet"])
		if subnet == "172.30.0.0/24" { // pretend something else on the host already uses it
			http.Error(w, `{"message":"Pool overlaps with other one on this address space"}`, http.StatusForbidden)
			return
		}
		networkCreated.Store(true)
		w.WriteHeader(http.StatusCreated)
	})
	mux.HandleFunc("/containers/json", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "[]") })
	http.Serve(ln, mux)
}

func TestDaemonConfig(t *testing.T) {
	cfg := defaultConfig()
	cfg.DataRoot, cfg.ExecRoot, cfg.Isolation = "D:/data", "D:/exec", "hyperv"
	m := &Manager{cfg: cfg, base: map[string]any{
		"hosts":               []any{"tcp://0.0.0.0:2375"},
		"tlsverify":           false,
		"insecure-registries": []any{"10.0.0.0/8"},
		"exec-opts":           []any{"isolation=process", "foo=bar"},
	}}
	tn := newTenant("matfax/repo")
	c := m.daemonConfig(tn, "npipe:////./pipe/x", "D:/exec/"+tn.ID)
	if h := c["hosts"].([]string); len(h) != 1 || h[0] != "npipe:////./pipe/x" {
		t.Errorf("hosts = %v", h)
	}
	if _, ok := c["tlsverify"]; ok {
		t.Error("TLS settings of the base config must not reach tenant daemons")
	}
	if c["containerd-namespace"] != tn.ID || c["containerd"] != `\\.\pipe\containerd-containerd` || c["bridge"] != "none" {
		t.Errorf("unexpected config %v", c)
	}
	if opts := c["exec-opts"].([]any); len(opts) != 2 || opts[1] != "isolation=hyperv" {
		t.Errorf("exec-opts = %v", opts)
	}
	if c["insecure-registries"] == nil {
		t.Error("base settings must be kept")
	}
}

func TestManagerLifecycle(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_DOCKERD", "1")
	dir := t.TempDir()
	cfg := defaultConfig()
	cfg.Dockerd = exe
	cfg.DataRoot = filepath.Join(dir, "data")
	cfg.ExecRoot = filepath.Join(dir, "exec")
	cfg.BaseDaemonConfig = filepath.Join(dir, "missing.json")
	cfg.Tenants.MaxRunning = 1
	cfg.Tenants.StartTimeout = Duration{20 * time.Second}
	m, err := newManager(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer m.StopAll(5 * time.Second)
	ctx := context.Background()

	a := newTenant("matfax/a")
	d, release, err := m.Acquire(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	if !d.isRunning() {
		t.Fatal("daemon not running after Acquire")
	}
	if sn, _ := m.subnets.allocate(a.ID, nil); sn != "172.30.1.0/24" {
		t.Errorf("tenant subnet %s; want the next one after the conflicting 172.30.0.0/24", sn)
	}

	// A second tenant must wait for a slot while the first is busy...
	if _, _, err := m.Acquire(ctx, newTenant("matfax/b")); err != errBusy {
		t.Errorf("second tenant while the first is busy: %v, want errBusy", err)
	}
	release()
	// ...and gets the first one's slot once that is idle.
	db, releaseB, err := m.Acquire(ctx, newTenant("matfax/b"))
	if err != nil {
		t.Fatal(err)
	}
	releaseB()
	if d.isRunning() {
		t.Error("idle tenant a was not evicted for b")
	}
	if !db.stopIfIdle(ctx, time.Now().Add(time.Second), time.Time{}) || db.isRunning() {
		t.Error("idle daemon b was not stopped")
	}

	// A different name that maps to the same ID must not get the daemon or its directory.
	if _, _, err := m.Acquire(ctx, Tenant{Name: "evil/a", ID: a.ID}); err == nil {
		t.Error("an ID collision must be refused")
	}
	impostor := m.newDaemon(Tenant{Name: "evil/a", ID: a.ID})
	if err := impostor.claimDir(); err == nil {
		t.Error("a tenant directory must not be reused for another repository")
	}

	// Starting again reuses the tenant's data and subnet.
	d2, release2, err := m.Acquire(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	release2()
	if d2 != d || !d2.isRunning() {
		t.Error("tenant a did not restart on its own daemon entry")
	}
}
