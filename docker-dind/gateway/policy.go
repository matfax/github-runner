package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	pathpkg "path"
	"regexp"
	"strconv"
	"strings"
)

// Policy screens Docker API requests before they reach a tenant daemon. Tenant daemons run as
// SYSTEM on the node and see every HNS network on it, so the gateway refuses anything that would
// reach the host or other tenants: host bind mounts and named pipes, published ports, devices,
// swarm, plugins, network management, and networks other than the tenant's own.
type Policy struct {
	// Network is the tenant's NAT network; containers and builds asking for the default network get it.
	Network string
	// Isolation is the daemon default; with "hyperv", explicit process isolation is refused.
	Isolation string
	// Tenant is the owner/repo name the tenant's network is labelled with.
	Tenant string
}

// tenantLabel marks the network the gateway created for a tenant.
const tenantLabel = "fyi.actions.docker-dind.tenant"

// maxCreateBody bounds the container-create bodies the policy reads into memory.
const maxCreateBody = 4 << 20

var (
	// versionPrefix matches dockerd's route prefix /v{version:[0-9.]+}.
	versionPrefix = regexp.MustCompile(`^/v[0-9.]+(/.*)$`)
	// volumeName is Docker's named-volume syntax, at least two characters so a drive letter ("C:")
	// never passes as a volume.
	volumeName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`)
)

type policyError struct {
	status int
	msg    string
}

func (e *policyError) Error() string { return e.msg }

func deny(format string, a ...any) *policyError {
	return &policyError{status: http.StatusForbidden, msg: "docker-dind: " + fmt.Sprintf(format, a...)}
}

func badRequest(format string, a ...any) *policyError {
	return &policyError{status: http.StatusBadRequest, msg: "docker-dind: " + fmt.Sprintf(format, a...)}
}

// Apply checks r and rewrites it in place where the default network must become the tenant's.
func (p *Policy) Apply(r *http.Request) *policyError {
	if r.URL.Path == "" || pathpkg.Clean(r.URL.Path) != r.URL.Path {
		return badRequest("request path %q is not canonical", r.URL.Path)
	}
	api := r.URL.Path
	if m := versionPrefix.FindStringSubmatch(api); m != nil {
		api = m[1]
	}
	segs := strings.Split(strings.Trim(api, "/"), "/")
	read := r.Method == http.MethodGet || r.Method == http.MethodHead
	// dockerd reads parameters from form bodies (urlencoded and multipart) as well as the query
	// string, which would let a client override the parameters checked here. The Docker API never
	// sends such bodies.
	ct, _, _ := strings.Cut(strings.ToLower(r.Header.Get("Content-Type")), ";")
	if ct = strings.TrimSpace(ct); ct == "application/x-www-form-urlencoded" || strings.HasPrefix(ct, "multipart/") {
		return badRequest("form request bodies are not supported")
	}

	switch segs[0] {
	case "_ping", "version", "info", "events", "system", "auth", "commit", "exec", "distribution":
	case "swarm", "nodes", "services", "tasks", "secrets", "configs":
		return deny("swarm mode is not available")
	case "grpc", "session":
		return deny("BuildKit sessions are not available; Windows images build with the classic builder")
	case "plugins":
		if !read {
			return deny("plugins cannot be installed or changed")
		}
	case "networks":
		if !read {
			return deny("networks are managed by the gateway; containers use %q", p.Network)
		}
		return p.checkNetworkRead(r, segs)
	case "volumes":
		if r.Method == http.MethodPost && len(segs) == 2 && segs[1] == "create" {
			return p.checkJSON(r, p.checkVolumeCreate)
		}
	case "containers":
		if r.Method == http.MethodPost && len(segs) == 2 && segs[1] == "create" {
			return p.checkJSON(r, p.checkContainerCreate)
		}
		if r.Method == http.MethodPost && len(segs) == 3 && segs[2] == "exec" {
			return p.checkJSON(r, checkExecCreate)
		}
	case "images":
		if r.Method == http.MethodPost && len(segs) == 2 && segs[1] == "create" {
			for _, src := range r.URL.Query()["fromSrc"] {
				if src != "-" {
					return deny("importing images from a URL is not available; send the archive in the request body")
				}
			}
		}
	case "build":
		if r.Method == http.MethodPost && len(segs) == 1 {
			return p.checkBuild(r)
		}
	default:
		// Includes paths whose version prefix dockerd would accept but versionPrefix did not strip.
		return deny("API endpoint %q is not available", r.URL.Path)
	}
	return nil
}

// checkNetworkRead hides the other tenants' and the cluster's networks, which every tenant daemon
// lists because HNS networks are host-wide.
func (p *Policy) checkNetworkRead(r *http.Request, segs []string) *policyError {
	switch {
	case len(segs) == 1:
		q := r.URL.Query()
		filters, _ := json.Marshal(map[string]map[string]bool{"label": {tenantLabel + "=" + p.Tenant: true}})
		q.Set("filters", string(filters))
		r.URL.RawQuery = q.Encode()
		return nil
	case len(segs) == 2 && segs[1] == p.Network:
		return nil
	}
	return deny("only the network %q can be inspected", p.Network)
}

// checkBuild applies the network and isolation rules to the classic builder's RUN containers.
func (p *Policy) checkBuild(r *http.Request) *policyError {
	q := r.URL.Query()
	for _, v := range q["remote"] {
		if v != "" {
			return deny("remote build contexts are not available; send the context as a tar body")
		}
	}
	if v := q.Get("version"); v != "" && v != "1" {
		return deny("BuildKit is not available; Windows images build with the classic builder")
	}
	nm, err := p.network(q.Get("networkmode"))
	if err != nil {
		return err
	}
	q.Set("networkmode", nm)
	iso := q.Get("isolation")
	if err := p.checkIsolation(iso); err != nil {
		return err
	}
	q.Set("isolation", iso)
	r.URL.RawQuery = q.Encode()
	return nil
}

// network maps a requested network mode to the one the container gets.
func (p *Policy) network(mode string) (string, *policyError) {
	switch {
	case mode == "" || mode == "default" || mode == "nat" || mode == "bridge" || mode == p.Network:
		return p.Network, nil
	case mode == "none" || strings.HasPrefix(mode, "container:"):
		return mode, nil
	}
	return "", deny("network %q is not available; containers use %q", mode, p.Network)
}

func (p *Policy) checkIsolation(iso string) *policyError {
	switch strings.ToLower(iso) {
	case "", "default", "hyperv":
		return nil
	case "process":
		if p.Isolation == "hyperv" {
			return deny("this service enforces Hyper-V isolation")
		}
		return nil
	}
	return deny("isolation %q is not supported", iso)
}

// checkJSON decodes a JSON object body, lets check inspect and change it, and puts it back.
func (p *Policy) checkJSON(r *http.Request, check func(map[string]any) *policyError) *policyError {
	var body map[string]any
	if r.Body != nil && r.Body != http.NoBody {
		raw, err := io.ReadAll(io.LimitReader(r.Body, maxCreateBody+1))
		r.Body.Close()
		if err != nil {
			return badRequest("reading request body: %v", err)
		}
		if len(raw) > maxCreateBody {
			return badRequest("request body is larger than %d bytes", maxCreateBody)
		}
		if len(bytes.TrimSpace(raw)) > 0 {
			dec := json.NewDecoder(bytes.NewReader(raw))
			dec.UseNumber()
			if err := dec.Decode(&body); err != nil {
				return badRequest("request body is not a JSON object: %v", err)
			}
		}
	}
	if body == nil {
		body = map[string]any{}
	}
	if err := check(body); err != nil {
		return err
	}
	out, err := json.Marshal(body)
	if err != nil {
		return badRequest("encoding request body: %v", err)
	}
	r.Body = io.NopCloser(bytes.NewReader(out))
	r.ContentLength = int64(len(out))
	r.Header.Set("Content-Length", strconv.Itoa(len(out)))
	r.Header.Set("Content-Type", "application/json")
	r.TransferEncoding = nil
	return nil
}

func (p *Policy) checkVolumeCreate(body map[string]any) *policyError {
	if err := canon(body, "Driver", "DriverOpts"); err != nil {
		return err
	}
	if d := str(body["Driver"]); d != "" && d != "local" {
		return deny("volume driver %q is not available", d)
	}
	if len(obj(body["DriverOpts"])) > 0 {
		return deny("volume driver options are not available")
	}
	return nil
}

func checkExecCreate(body map[string]any) *policyError {
	if err := canon(body, "Privileged"); err != nil {
		return err
	}
	if truthy(body["Privileged"]) {
		return deny("privileged exec is not available")
	}
	return nil
}

func (p *Policy) checkContainerCreate(body map[string]any) *policyError {
	if err := canon(body, "HostConfig", "NetworkingConfig"); err != nil {
		return err
	}
	hc := obj(body["HostConfig"])
	if hc == nil {
		hc = map[string]any{}
	}
	if err := canon(hc, "Binds", "Mounts", "VolumeDriver", "Devices", "DeviceRequests", "Privileged", "PortBindings",
		"PublishAllPorts", "Runtime", "CgroupParent", "PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode",
		"SecurityOpt", "Isolation", "NetworkMode", "LogConfig", "Annotations"); err != nil {
		return err
	}
	if err := canon(obj(hc["LogConfig"]), "Type"); err != nil {
		return err
	}
	// Other log drivers (fluentd, gelf, syslog, ...) send logs from the node to an address of the client's choosing.
	switch t := str(obj(hc["LogConfig"])["Type"]); t {
	case "", "json-file", "local", "none", "etwlogs":
	default:
		return deny("log driver %q is not available", t)
	}
	if len(obj(hc["Annotations"])) > 0 {
		return deny("container annotations are not available")
	}

	for _, b := range list(hc["Binds"]) {
		spec := str(b)
		src, _, _ := strings.Cut(spec, ":")
		if !volumeName.MatchString(src) {
			return deny("bind mount %q is not available; only named volumes can be mounted", spec)
		}
	}
	for _, m := range list(hc["Mounts"]) {
		mo := obj(m)
		if err := canon(mo, "Type", "Source", "VolumeOptions"); err != nil {
			return err
		}
		if err := canon(obj(mo["VolumeOptions"]), "DriverConfig"); err != nil {
			return err
		}
		if err := canon(obj(obj(mo["VolumeOptions"])["DriverConfig"]), "Name", "Options"); err != nil {
			return err
		}
		if t := str(mo["Type"]); t != "volume" {
			return deny("mount type %q is not available; only named volumes can be mounted", t)
		}
		if src := str(mo["Source"]); src != "" && !volumeName.MatchString(src) {
			return deny("volume %q is not a valid volume name", src)
		}
		if dc := obj(obj(mo["VolumeOptions"])["DriverConfig"]); dc != nil {
			if n := str(dc["Name"]); (n != "" && n != "local") || len(obj(dc["Options"])) > 0 {
				return deny("volume driver configuration is not available")
			}
		}
	}
	if d := str(hc["VolumeDriver"]); d != "" && d != "local" {
		return deny("volume driver %q is not available", d)
	}
	if len(list(hc["Devices"])) > 0 || len(list(hc["DeviceRequests"])) > 0 {
		return deny("devices are not available")
	}
	if truthy(hc["Privileged"]) {
		return deny("privileged containers are not available")
	}
	if len(obj(hc["PortBindings"])) > 0 || truthy(hc["PublishAllPorts"]) {
		return deny("publishing ports is not available; nothing may connect into build containers")
	}
	if rt := str(hc["Runtime"]); rt != "" {
		return deny("runtime %q is not available", rt)
	}
	if str(hc["CgroupParent"]) != "" {
		return deny("cgroup parents are not available")
	}
	for _, k := range []string{"PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode"} {
		if strings.EqualFold(str(hc[k]), "host") {
			return deny("%s=host is not available", k)
		}
	}
	for _, o := range list(hc["SecurityOpt"]) {
		if strings.Contains(strings.ToLower(str(o)), "credentialspec") {
			return deny("credential specs (gMSA) are not available")
		}
	}
	if err := p.checkIsolation(str(hc["Isolation"])); err != nil {
		return err
	}

	nm, err := p.network(str(hc["NetworkMode"]))
	if err != nil {
		return err
	}
	hc["NetworkMode"] = nm
	if err := canon(obj(body["NetworkingConfig"]), "EndpointsConfig"); err != nil {
		return err
	}
	// Clients name the default network in EndpointsConfig too; re-key such entries to the tenant network.
	eps := obj(obj(body["NetworkingConfig"])["EndpointsConfig"])
	for name, ep := range eps {
		if name == nm {
			continue
		}
		if mapped, err := p.network(name); err != nil || mapped != nm {
			return deny("network %q is not available; containers use %q", name, p.Network)
		}
		delete(eps, name)
		eps[nm] = ep
	}

	body["HostConfig"] = hc
	return nil
}

// canon renames keys that match one of keys case-insensitively to that spelling. dockerd decodes
// bodies with encoding/json, which matches field names case-insensitively ("binds" sets Binds), so
// the policy must see them the same way; two spellings of one field are refused as ambiguous.
func canon(m map[string]any, keys ...string) *policyError {
	for _, key := range keys {
		var found []string
		for k := range m {
			if strings.EqualFold(k, key) {
				found = append(found, k)
			}
		}
		if len(found) > 1 {
			return badRequest("field %s is given more than once (%s)", key, strings.Join(found, ", "))
		}
		if len(found) == 1 && found[0] != key {
			m[key] = m[found[0]]
			delete(m, found[0])
		}
	}
	return nil
}

func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }
func list(v any) []any         { l, _ := v.([]any); return l }
func str(v any) string         { s, _ := v.(string); return s }
func truthy(v any) bool        { b, _ := v.(bool); return b }
