package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Duration is a time.Duration that reads from JSON strings such as "15m".
type Duration struct{ time.Duration }

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return fmt.Errorf("duration must be a string like \"15m\": %w", err)
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	d.Duration = v
	return nil
}

func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

// Config is the gateway configuration, read from gateway.json.
// Relative paths resolve against the HostProcess sandbox mount point (CONTAINER_SANDBOX_MOUNT_POINT),
// or against the system drive root when that is not set.
type Config struct {
	// Listen is the mutual-TLS listener address, e.g. ":2376".
	Listen string `json:"listen"`
	TLS    struct {
		Cert     string `json:"cert"`
		Key      string `json:"key"`
		ClientCA string `json:"clientCA"`
		// ReloadInterval is how often the certificate files are checked for changes.
		ReloadInterval Duration `json:"reloadInterval"`
	} `json:"tls"`

	// Dockerd is the dockerd.exe started for each tenant.
	Dockerd string `json:"dockerd"`
	// Containerd is the host containerd endpoint shared by all tenant daemons.
	Containerd string `json:"containerd"`
	// BaseDaemonConfig is a daemon.json whose settings every tenant daemon inherits.
	BaseDaemonConfig string `json:"baseDaemonConfig"`
	// DataRoot holds one directory per tenant (data-root, daemon.json, pidfile).
	DataRoot string `json:"dataRoot"`
	// ExecRoot holds one exec-root per tenant.
	ExecRoot string `json:"execRoot"`
	// Isolation is the default isolation of tenant containers: "process" or "hyperv".
	// With "hyperv", requests for process isolation are refused.
	Isolation string `json:"isolation"`

	Tenants struct {
		// Allowed restricts which owner/repo identities may connect (path.Match patterns, e.g. "matfax/*").
		// Empty allows every identity whose certificate chains to the client CA.
		Allowed []string `json:"allowed"`
		// IdleTimeout stops a tenant daemon after this long without requests and running containers.
		IdleTimeout Duration `json:"idleTimeout"`
		// ContainerIdleTimeout stops a daemon without requests for this long even if containers still run.
		ContainerIdleTimeout Duration `json:"containerIdleTimeout"`
		// StartTimeout bounds how long a tenant daemon may take to answer its first ping.
		StartTimeout Duration `json:"startTimeout"`
		// MaxRunning caps the number of tenant daemons running at once.
		MaxRunning int `json:"maxRunning"`
	} `json:"tenants"`

	Network struct {
		// Pool is split into one NAT subnet per tenant.
		Pool string `json:"pool"`
		// PrefixLength is the size of each tenant subnet.
		PrefixLength int `json:"prefixLength"`
		// DNS servers handed to build containers (the NAT gateway DNS proxy is disabled).
		DNS []string `json:"dns"`
		// Egress lists the IPv4 ranges build containers may not reach (Block) and exceptions (Allow).
		// The tenant pool and the node's own addresses are always blocked; the DNS servers are allowed.
		Egress struct {
			Block []string `json:"block"`
			Allow []string `json:"allow"`
		} `json:"egress"`
	} `json:"network"`
}

func defaultConfig() *Config {
	c := &Config{Listen: ":2376", Isolation: "process"}
	c.TLS.Cert = "dind-tls/server/tls.crt"
	c.TLS.Key = "dind-tls/server/tls.key"
	c.TLS.ClientCA = "dind-tls/client-ca/ca.crt"
	c.TLS.ReloadInterval = Duration{30 * time.Second}
	c.Dockerd = "Program Files/docker/dockerd.exe"
	c.Containerd = `\\.\pipe\containerd-containerd`
	c.BaseDaemonConfig = "docker-config/daemon.json"
	c.DataRoot = "C:/docker-data/tenants"
	c.ExecRoot = "C:/ProgramData/docker-dind/exec"
	c.Tenants.IdleTimeout = Duration{15 * time.Minute}
	c.Tenants.ContainerIdleTimeout = Duration{4 * time.Hour}
	c.Tenants.StartTimeout = Duration{2 * time.Minute}
	c.Tenants.MaxRunning = 8
	c.Network.Pool = "172.30.0.0/16"
	c.Network.PrefixLength = 24
	c.Network.DNS = []string{"1.1.1.1", "8.8.8.8"}
	c.Network.Egress.Block = []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
	}
	return c
}

func loadConfig(path string) (*Config, error) {
	c := defaultConfig()
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	root := sandboxRoot()
	for _, p := range []*string{&c.TLS.Cert, &c.TLS.Key, &c.TLS.ClientCA, &c.Dockerd, &c.BaseDaemonConfig, &c.DataRoot, &c.ExecRoot} {
		*p = resolvePath(root, *p)
	}
	return c, c.validate()
}

func (c *Config) validate() error {
	var errs []error
	if c.Isolation != "process" && c.Isolation != "hyperv" {
		errs = append(errs, fmt.Errorf("isolation must be \"process\" or \"hyperv\", got %q", c.Isolation))
	}
	if c.Tenants.MaxRunning < 1 {
		errs = append(errs, errors.New("tenants.maxRunning must be at least 1"))
	}
	if c.Tenants.IdleTimeout.Duration < time.Minute {
		errs = append(errs, errors.New("tenants.idleTimeout must be at least 1m"))
	}
	if c.Tenants.ContainerIdleTimeout.Duration < c.Tenants.IdleTimeout.Duration {
		errs = append(errs, errors.New("tenants.containerIdleTimeout must not be shorter than tenants.idleTimeout"))
	}
	if c.TLS.ReloadInterval.Duration < time.Second {
		errs = append(errs, errors.New("tls.reloadInterval must be at least 1s"))
	}
	pool, err := netip.ParsePrefix(c.Network.Pool)
	switch {
	case err != nil:
		errs = append(errs, fmt.Errorf("network.pool: %w", err))
	case !pool.Addr().Is4():
		errs = append(errs, errors.New("network.pool must be IPv4 (Windows NAT networks are IPv4 only)"))
	case pool.Masked() != pool:
		errs = append(errs, fmt.Errorf("network.pool %s is not a network address (use %s)", pool, pool.Masked()))
	case c.Network.PrefixLength < pool.Bits() || c.Network.PrefixLength > 29:
		errs = append(errs, fmt.Errorf("network.prefixLength must be between %d and 29", pool.Bits()))
	}
	for _, d := range c.Network.DNS {
		if _, err := netip.ParseAddr(d); err != nil {
			errs = append(errs, fmt.Errorf("network.dns: %w", err))
		}
	}
	if _, err := parseRanges(c.Network.Egress.Block); err != nil {
		errs = append(errs, fmt.Errorf("network.egress.block: %w", err))
	}
	if _, err := parseRanges(c.Network.Egress.Allow); err != nil {
		errs = append(errs, fmt.Errorf("network.egress.allow: %w", err))
	}
	for _, p := range c.Tenants.Allowed {
		if _, err := matchPattern(p, "x/y"); err != nil {
			errs = append(errs, fmt.Errorf("tenants.allowed %q: %w", p, err))
		}
	}
	return errors.Join(errs...)
}

func sandboxRoot() string {
	if r := os.Getenv("CONTAINER_SANDBOX_MOUNT_POINT"); r != "" {
		return r
	}
	if runtime.GOOS == "windows" {
		return `C:\`
	}
	return "/"
}

func resolvePath(root, p string) string {
	if p == "" || filepath.IsAbs(p) || strings.HasPrefix(p, `\\`) {
		return filepath.FromSlash(p)
	}
	return filepath.Join(root, filepath.FromSlash(p))
}
