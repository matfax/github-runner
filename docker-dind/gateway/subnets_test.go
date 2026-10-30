package main

import (
	"path/filepath"
	"testing"
)

func TestSubnetStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "subnets.json")
	s, err := openSubnetStore(path, "172.30.0.0/22", 24)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := s.allocate("a", nil)
	b, _ := s.allocate("b", nil)
	if a != "172.30.0.0/24" || b != "172.30.1.0/24" {
		t.Fatalf("got %s, %s", a, b)
	}
	if again, _ := s.allocate("a", nil); again != a {
		t.Errorf("a moved from %s to %s", a, again)
	}
	moved, _ := s.allocate("a", map[string]bool{a: true})
	if moved != "172.30.2.0/24" {
		t.Errorf("a skipping its subnet got %s", moved)
	}

	reopened, err := openSubnetStore(path, "172.30.0.0/22", 24)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := reopened.allocate("b", nil); got != b {
		t.Errorf("b after reopening got %s, want %s", got, b)
	}
	if got, _ := reopened.allocate("c", nil); got != "172.30.0.0/24" {
		t.Errorf("c got %s, want the subnet a gave up", got)
	}
	if got, _ := reopened.allocate("d", nil); got != "172.30.3.0/24" {
		t.Errorf("d got %s, want the last subnet", got)
	}
	if _, err := reopened.allocate("e", nil); err == nil {
		t.Error("a full pool must fail")
	}
}
