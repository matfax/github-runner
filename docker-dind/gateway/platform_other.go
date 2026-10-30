//go:build !windows

package main

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

// The gateway only runs on Windows; this file lets its tests run anywhere, with Unix sockets
// standing in for named pipes.

func tenantEndpoint(execRoot, id string) (host, addr string) {
	addr = filepath.Join(execRoot, id+".sock")
	return "unix://" + addr, addr
}

func dialTenant(ctx context.Context, addr string) (net.Conn, error) {
	var d net.Dialer
	return d.DialContext(ctx, "unix", addr)
}

func startProcess(cmd *exec.Cmd) error { return cmd.Start() }

func interruptProcess(p *os.Process) error { return p.Signal(syscall.SIGINT) }
