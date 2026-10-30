package main

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"strings"
)

// Tenant is one GitHub repository; each tenant gets its own dockerd.
type Tenant struct {
	// Name is the lower-cased "owner/repo" identity.
	Name string
	// ID is a short, filesystem- and containerd-safe name derived from Name.
	ID string
}

func newTenant(name string) Tenant { return Tenant{Name: name, ID: tenantID(name)} }

// identityFromCert reads the owner/repo identity from a verified client certificate.
// It is taken from URI SANs and the subject CN; every value present must name the same repository.
func identityFromCert(c *x509.Certificate) (string, error) {
	var candidates []string
	for _, u := range c.URIs {
		candidates = append(candidates, u.String())
	}
	if c.Subject.CommonName != "" {
		candidates = append(candidates, c.Subject.CommonName)
	}
	if len(candidates) == 0 {
		return "", errors.New("client certificate carries no identity (expected CN or URI SAN \"owner/repo\")")
	}
	var name string
	for _, cand := range candidates {
		n, err := parseRepo(cand)
		if err != nil {
			return "", err
		}
		if name != "" && n != name {
			return "", fmt.Errorf("client certificate names more than one repository (%q, %q)", name, n)
		}
		name = n
	}
	return name, nil
}

// parseRepo validates a GitHub "owner/repo" name and returns it lower-cased (GitHub names are
// case-insensitive, so two spellings must not get two daemons).
func parseRepo(s string) (string, error) {
	owner, repo, ok := strings.Cut(s, "/")
	if !ok || !validOwner(owner) || !validRepo(repo) {
		return "", fmt.Errorf("identity %q is not a valid GitHub owner/repo name", s)
	}
	return strings.ToLower(s), nil
}

// validOwner follows GitHub's rules for user and organization names: 1-39 alphanumerics or
// hyphens, not starting or ending with a hyphen.
func validOwner(s string) bool {
	if len(s) < 1 || len(s) > 39 || s[0] == '-' || s[len(s)-1] == '-' {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isAlnum(s[i]) && s[i] != '-' {
			return false
		}
	}
	return true
}

// validRepo follows GitHub's rules for repository names: 1-100 of alphanumerics, '.', '-' or '_',
// other than "." and "..".
func validRepo(s string) bool {
	if len(s) < 1 || len(s) > 100 || s == "." || s == ".." {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isAlnum(s[i]) && s[i] != '.' && s[i] != '-' && s[i] != '_' {
			return false
		}
	}
	return true
}

func isAlnum(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// tenantID maps a validated name to "<slug>-<hash>": a readable slug of at most 12 characters
// plus 96 bits of its SHA-256, so distinct names do not collide (e.g. "a-b/c" and "a/b-c") and
// no one can search for a repository name whose ID matches another's.
// The result matches containerd's namespace syntax and is safe in paths and pipe names.
func tenantID(name string) string {
	var b strings.Builder
	dash := false
	for i := 0; i < len(name) && b.Len() < 12; i++ {
		c := name[i]
		if isAlnum(c) {
			b.WriteByte(c)
			dash = false
		} else if b.Len() > 0 && !dash {
			b.WriteByte('-')
			dash = true
		}
	}
	slug := strings.TrimRight(b.String(), "-")
	if slug == "" {
		slug = "t"
	}
	sum := sha256.Sum256([]byte(name))
	return slug + "-" + hex.EncodeToString(sum[:12])
}

// allowedTenant reports whether name matches one of the patterns; no patterns allows everyone.
func allowedTenant(patterns []string, name string) bool {
	if len(patterns) == 0 {
		return true
	}
	for _, p := range patterns {
		if ok, _ := matchPattern(p, name); ok {
			return true
		}
	}
	return false
}

func matchPattern(pattern, name string) (bool, error) {
	return path.Match(strings.ToLower(pattern), name)
}
