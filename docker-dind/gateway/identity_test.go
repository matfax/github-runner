package main

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"net/url"
	"regexp"
	"testing"
)

func TestParseRepo(t *testing.T) {
	valid := map[string]string{
		"matfax/github-runner": "matfax/github-runner",
		"MatFax/Repo.Name_1":   "matfax/repo.name_1",
		"a/b":                  "a/b",
		"octo-org/.github":     "octo-org/.github",
	}
	for in, want := range valid {
		got, err := parseRepo(in)
		if err != nil || got != want {
			t.Errorf("parseRepo(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{
		"", "owner", "owner/", "/repo", "owner/repo/extra", "-owner/repo", "owner-/repo",
		"own_er/repo", "owner/..", "owner/.", "owner/re po", `owner/re\po`, "owner/repo:tag",
		"ow.ner/repo", "owner/rëpo", "0123456789012345678901234567890123456789/repo",
	} {
		if got, err := parseRepo(in); err == nil {
			t.Errorf("parseRepo(%q) = %q; want an error", in, got)
		}
	}
}

func TestTenantID(t *testing.T) {
	containerdNamespace := regexp.MustCompile(`^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$`)
	seen := map[string]string{}
	for _, name := range []string{"a-b/c", "a/b-c", "matfax/github-runner", "x/...", "x/___", "octo-org/.github",
		"averyveryveryverylongownername/averyveryveryverylongreponame"} {
		id := tenantID(name)
		if !containerdNamespace.MatchString(id) || len(id) > 37 {
			t.Errorf("tenantID(%q) = %q is not a safe containerd namespace", name, id)
		}
		if prev, ok := seen[id]; ok {
			t.Errorf("tenantID(%q) = tenantID(%q) = %q", name, prev, id)
		}
		seen[id] = name
	}
	if tenantID("matfax/github-runner") != tenantID("matfax/github-runner") {
		t.Error("tenantID is not deterministic")
	}
}

func TestIdentityFromCert(t *testing.T) {
	uri := func(s string) *url.URL {
		u, err := url.Parse(s)
		if err != nil {
			t.Fatal(err)
		}
		return u
	}
	cases := []struct {
		name string
		cert x509.Certificate
		want string
	}{
		{"cn", x509.Certificate{Subject: pkix.Name{CommonName: "Owner/Repo"}}, "owner/repo"},
		{"uri", x509.Certificate{URIs: []*url.URL{uri("owner/repo")}}, "owner/repo"},
		{"both agree", x509.Certificate{Subject: pkix.Name{CommonName: "owner/repo"}, URIs: []*url.URL{uri("OWNER/repo")}}, "owner/repo"},
		{"both disagree", x509.Certificate{Subject: pkix.Name{CommonName: "owner/repo"}, URIs: []*url.URL{uri("owner/other")}}, ""},
		{"none", x509.Certificate{}, ""},
		{"invalid cn", x509.Certificate{Subject: pkix.Name{CommonName: "docker-dind.ci.svc"}}, ""},
		{"uri with scheme", x509.Certificate{URIs: []*url.URL{uri("spiffe://cluster/owner/repo")}}, ""},
	}
	for _, c := range cases {
		got, err := identityFromCert(&c.cert)
		if c.want == "" {
			if err == nil {
				t.Errorf("%s: got %q, want an error", c.name, got)
			}
		} else if err != nil || got != c.want {
			t.Errorf("%s: got %q, %v; want %q", c.name, got, err, c.want)
		}
	}
}

func TestAllowedTenant(t *testing.T) {
	if !allowedTenant(nil, "a/b") {
		t.Error("no patterns must allow everyone")
	}
	pats := []string{"MatFax/*", "org/one"}
	for name, want := range map[string]bool{"matfax/x": true, "org/one": true, "org/two": false, "matfaxx/x": false} {
		if got := allowedTenant(pats, name); got != want {
			t.Errorf("allowedTenant(%q) = %v, want %v", name, got, want)
		}
	}
}
