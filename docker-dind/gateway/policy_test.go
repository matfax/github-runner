package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func apply(t *testing.T, p *Policy, method, target, body string) (*http.Request, *policyError) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	r := httptest.NewRequest(method, target, rd)
	return r, p.Apply(r)
}

func TestPolicyRoutes(t *testing.T) {
	p := &Policy{Network: "build", Isolation: "process"}
	cases := []struct {
		method, target string
		allowed        bool
	}{
		{"GET", "/_ping", true},
		{"GET", "/v1.47/info", true},
		{"POST", "/v1.47/images/create?fromImage=mcr.microsoft.com/windows/servercore", true},
		{"POST", "/v1.47/swarm/init", false},
		{"GET", "/swarm", false},
		{"POST", "/services/create", false},
		{"GET", "/plugins", true},
		{"POST", "/plugins/pull?remote=x", false},
		{"POST", "/v1.47/grpc", false},
		{"POST", "/session", false},
		{"GET", "/networks", true},
		{"GET", "/networks/build", true},
		{"POST", "/networks/create", false},
		{"POST", "/v1.47/networks/prune", false},
		{"DELETE", "/networks/abc", false},
		{"POST", "/networks/abc/connect", false},
		{"POST", "/v1.47/../swarm/init", false},
		{"POST", "/v1.47//swarm/init", false},
		{"POST", "/build/prune", true},
		// dockerd's version route is /v{version:[0-9.]+}
		{"POST", "/v1.44.0/swarm/init", false},
		{"POST", "/v1.44.0/networks/create", false},
		{"POST", "/v1..44/plugins/pull", false},
		{"GET", "/v1.47/unknown", false},
		{"POST", "/v1.47/images/create?fromImage=x&fromSrc=-", true},
		{"POST", "/v1.47/images/create?fromSrc=-&fromSrc=http://169.254.169.254/x", false},
		{"POST", "/build?remote=http://10.43.0.1/ctx.tar", false},
		{"POST", "/build?remote=&remote=http://10.43.0.1/ctx.tar", false},
		{"POST", "/build?version=2", false},
		{"GET", "/networks/Calico", false},
		{"GET", "/networks/docker-dind-other", false},
	}
	for _, c := range cases {
		_, err := apply(t, p, c.method, c.target, "")
		if (err == nil) != c.allowed {
			t.Errorf("%s %s: allowed=%v, want %v (%v)", c.method, c.target, err == nil, c.allowed, err)
		}
	}
}

func TestPolicyBuild(t *testing.T) {
	p := &Policy{Network: "build", Isolation: "process"}
	for in, want := range map[string]string{"": "build", "default": "build", "nat": "build", "build": "build", "none": "none"} {
		r, err := apply(t, p, "POST", "/v1.47/build?t=x&networkmode="+in, "")
		if err != nil {
			t.Fatalf("networkmode=%q: %v", in, err)
		}
		if got := r.URL.Query().Get("networkmode"); got != want {
			t.Errorf("networkmode=%q became %q, want %q", in, got, want)
		}
		if r.URL.Query().Get("t") != "x" {
			t.Error("other build parameters must be kept")
		}
	}
	for _, q := range []string{"networkmode=host", "networkmode=Calico", "isolation=bogus"} {
		if _, err := apply(t, p, "POST", "/build?"+q, ""); err == nil {
			t.Errorf("%s: allowed", q)
		}
	}
	// The first value decides (as in dockerd) and the rewrite leaves a single one.
	r, err := apply(t, p, "POST", "/build?networkmode=nat&networkmode=Calico", "")
	if err != nil || len(r.URL.Query()["networkmode"]) != 1 || r.URL.Query().Get("networkmode") != "build" {
		t.Errorf("duplicate networkmode: %v %v", r.URL.Query()["networkmode"], err)
	}

	for _, ct := range []string{"Application/X-WWW-Form-Urlencoded; charset=utf-8", "multipart/form-data; boundary=x"} {
		r = httptest.NewRequest("POST", "/build?networkmode=build", strings.NewReader("isolation=process"))
		r.Header.Set("Content-Type", ct)
		if err := p.Apply(r); err == nil {
			t.Errorf("%s bodies must be refused, dockerd reads parameters from them", ct)
		}
	}
	r, err = apply(t, p, "POST", "/build?isolation=hyperv&isolation=process", "")
	if err != nil || len(r.URL.Query()["isolation"]) != 1 {
		t.Errorf("duplicate isolation: %v %v", r.URL.Query()["isolation"], err)
	}

	hv := &Policy{Network: "build", Isolation: "hyperv"}
	if _, err := apply(t, hv, "POST", "/build?isolation=process", ""); err == nil {
		t.Error("process isolation must be refused when Hyper-V is enforced")
	}
	if _, err := apply(t, hv, "POST", "/build?isolation=hyperv", ""); err != nil {
		t.Error(err)
	}
}

func TestPolicyContainerCreate(t *testing.T) {
	p := &Policy{Network: "build", Isolation: "process"}
	denied := []string{
		`{"HostConfig":{"Binds":["C:\\:C:\\host"]}}`,
		`{"HostConfig":{"Binds":["c:\\Users:c:\\u:ro"]}}`,
		`{"HostConfig":{"Binds":["\\\\.\\pipe\\docker_engine:\\\\.\\pipe\\docker_engine"]}}`,
		`{"HostConfig":{"Binds":["/var/run:/x"]}}`,
		`{"HostConfig":{"Mounts":[{"Type":"bind","Source":"C:\\","Target":"C:\\h"}]}}`,
		`{"HostConfig":{"Mounts":[{"Type":"npipe","Source":"\\\\.\\pipe\\containerd-containerd","Target":"\\\\.\\pipe\\c"}]}}`,
		`{"HostConfig":{"Mounts":[{"Type":"volume","Source":"v","Target":"C:\\v","VolumeOptions":{"DriverConfig":{"Name":"local","Options":{"device":"C:\\"}}}}]}}`,
		`{"HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}`,
		`{"HostConfig":{"PublishAllPorts":true}}`,
		`{"HostConfig":{"Devices":[{"PathOnHost":"class/5B45201D-F2F2-4F3B-85BB-30FF1F953599"}]}}`,
		`{"HostConfig":{"Privileged":true}}`,
		`{"HostConfig":{"NetworkMode":"host"}}`,
		`{"HostConfig":{"NetworkMode":"Calico"}}`,
		`{"HostConfig":{"NetworkMode":"docker-dind-other-0123456789"}}`,
		`{"HostConfig":{},"NetworkingConfig":{"EndpointsConfig":{"Calico":{}}}}`,
		`{"HostConfig":{"SecurityOpt":["credentialspec=file://x.json"]}}`,
		`{"HostConfig":{"Runtime":"runhcs"}}`,
		`{"HostConfig":{"VolumeDriver":"evil"}}`,
		`not json`,
		// dockerd matches JSON field names case-insensitively, including Unicode folding (U+017F folds to s)
		`{"hostconfig":{"binds":["C:\\:C:\\host"]}}`,
		`{"HostConfig":{"MOUNTS":[{"type":"bind","source":"C:\\","target":"C:\\h"}]}}`,
		`{"HostConfig":{"Binds":[],"binds":["C:\\:C:\\host"]}}`,
		`{"HostConfig":{"networkmode":"Calico"}}`,
		`{"HostConfig":{"Publi\u017fhAllPorts":true}}`,
		`{"HostConfig":{"Mounts":[{"Type":"volume","Source":"v","Target":"C:\\v","volumeoptions":{"driverconfig":{"options":{"device":"C:\\"}}}}]}}`,
		`{"HostConfig":{},"networkingconfig":{"endpointsconfig":{"Calico":{}}}}`,
		`{"HostConfig":{"LogConfig":{"Type":"gelf","Config":{"gelf-address":"udp://10.42.0.5:12201"}}}}`,
		`{"HostConfig":{"logconfig":{"type":"syslog"}}}`,
		`{"HostConfig":{"Annotations":{"io.microsoft.container.processdumplocation":"C:\"}}}`,
	}
	for _, b := range denied {
		if _, err := apply(t, p, "POST", "/v1.47/containers/create", b); err == nil {
			t.Errorf("allowed: %s", b)
		}
	}

	r, err := apply(t, p, "POST", "/v1.47/containers/create?name=x",
		`{"Image":"img","Memory":9007199254740993,"HostConfig":{"Binds":["cache:C:\\cache"],"Mounts":[{"Type":"volume","Source":"v2","Target":"C:\\v2"}]},"NetworkingConfig":{"EndpointsConfig":{"default":{"Aliases":["a"]}}}}`)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	dec := json.NewDecoder(r.Body)
	dec.UseNumber()
	if err := dec.Decode(&got); err != nil {
		t.Fatal(err)
	}
	if nm := got["HostConfig"].(map[string]any)["NetworkMode"]; nm != "build" {
		t.Errorf("NetworkMode = %v, want build", nm)
	}
	eps := got["NetworkingConfig"].(map[string]any)["EndpointsConfig"].(map[string]any)
	if _, ok := eps["build"]; !ok || len(eps) != 1 {
		t.Errorf("EndpointsConfig = %v, want only build", eps)
	}
	if got["Memory"].(json.Number).String() != "9007199254740993" {
		t.Errorf("large numbers must survive the rewrite, got %v", got["Memory"])
	}
	if r.ContentLength <= 0 {
		t.Error("Content-Length must be set on the rewritten body")
	}

	// A differently cased NetworkMode is replaced, not left next to the rewritten one.
	r, err = apply(t, p, "POST", "/containers/create", `{"hostConfig":{"networkMode":"nat"}}`)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r.Body)
	if s := string(b); !strings.Contains(s, `"NetworkMode":"build"`) || strings.Contains(s, "networkMode") || strings.Contains(s, "hostConfig") {
		t.Errorf("rewritten body %s", s)
	}

	if _, err := apply(t, p, "POST", "/containers/create", `{"HostConfig":{"NetworkMode":"none"}}`); err != nil {
		t.Error(err)
	}
	if _, err := apply(t, &Policy{Network: "build", Isolation: "hyperv"}, "POST", "/containers/create", `{"HostConfig":{"Isolation":"Process"}}`); err == nil {
		t.Error("process isolation must be refused when Hyper-V is enforced")
	}
}

func TestPolicyNetworkList(t *testing.T) {
	p := &Policy{Network: "build", Isolation: "process", Tenant: "matfax/repo"}
	r, err := apply(t, p, "GET", `/v1.47/networks?filters={"name":{"Calico":true}}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := r.URL.Query().Get("filters"), `{"label":{"fyi.actions.docker-dind.tenant=matfax/repo":true}}`; got != want {
		t.Errorf("filters = %s, want %s", got, want)
	}
}

func TestPolicyVolumesAndExec(t *testing.T) {
	p := &Policy{Network: "build", Isolation: "process"}
	if _, err := apply(t, p, "POST", "/volumes/create", `{"Name":"v"}`); err != nil {
		t.Error(err)
	}
	for _, b := range []string{`{"Name":"v","DriverOpts":{"device":"C:\\"}}`, `{"Name":"v","driveropts":{"device":"C:\\"}}`} {
		if _, err := apply(t, p, "POST", "/volumes/create", b); err == nil {
			t.Errorf("volume driver options must be refused: %s", b)
		}
	}
	for _, b := range []string{`{"Cmd":["cmd"],"Privileged":true}`, `{"Cmd":["cmd"],"privileged":true}`} {
		if _, err := apply(t, p, "POST", "/containers/abc/exec", b); err == nil {
			t.Errorf("privileged exec must be refused: %s", b)
		}
	}
	if _, err := apply(t, p, "POST", "/containers/abc/exec", `{"Cmd":["cmd"]}`); err != nil {
		t.Error(err)
	}
}
