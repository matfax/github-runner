//go:build windows

package main

import (
	"net"
	"testing"

	"github.com/Microsoft/go-winio"
)

// listenTenant listens where a tenant dockerd would, in message mode as dockerd does.
func listenTenant(t *testing.T, addr string) net.Listener {
	t.Helper()
	ln, err := winio.ListenPipe(addr, &winio.PipeConfig{MessageMode: true, InputBufferSize: 65536, OutputBufferSize: 65536})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func listenFake(addr string) (net.Listener, error) {
	return winio.ListenPipe(addr, &winio.PipeConfig{MessageMode: true})
}
