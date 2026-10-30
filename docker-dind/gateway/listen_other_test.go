//go:build !windows

package main

import (
	"net"
	"testing"
)

func listenTenant(t *testing.T, addr string) net.Listener {
	t.Helper()
	ln, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func listenFake(addr string) (net.Listener, error) { return net.Listen("unix", addr) }
