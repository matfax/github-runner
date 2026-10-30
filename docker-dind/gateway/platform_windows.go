//go:build windows

package main

import (
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

// tenantEndpoint returns the dockerd host flag and the address the gateway dials. Named pipes
// created by dockerd only admit Administrators and SYSTEM, so no pod and no user on the node can
// reach a tenant daemon except through the gateway.
func tenantEndpoint(_ string, id string) (host, addr string) {
	addr = `\\.\pipe\docker-dind-` + id
	return "npipe:////./pipe/docker-dind-" + id, addr
}

func dialTenant(ctx context.Context, addr string) (net.Conn, error) {
	return winio.DialPipeContext(ctx, addr)
}

var (
	jobOnce sync.Once
	job     windows.Handle
	jobErr  error
)

// killOnCloseJob is a job object that terminates the tenant daemons when the gateway exits, even
// if it crashes; otherwise orphaned daemons would hold their pipes and pidfiles.
func killOnCloseJob() (windows.Handle, error) {
	jobOnce.Do(func() {
		job, jobErr = windows.CreateJobObject(nil, nil)
		if jobErr != nil {
			return
		}
		info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
		info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		_, jobErr = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
			uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
	})
	return job, jobErr
}

func startProcess(cmd *exec.Cmd) error {
	// A process group of its own lets stopProcess send CTRL_BREAK to this daemon alone.
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP}
	if err := cmd.Start(); err != nil {
		return err
	}
	j, err := killOnCloseJob()
	if err == nil {
		var h windows.Handle
		h, err = windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
		if err == nil {
			err = windows.AssignProcessToJobObject(j, h)
			windows.CloseHandle(h)
		}
	}
	if err != nil {
		_ = cmd.Process.Kill()
		return errors.Join(errors.New("assigning dockerd to the gateway job object"), err)
	}
	return nil
}

// interruptProcess asks dockerd to shut down cleanly. It fails when the gateway has no console
// to share, in which case the caller falls back to killing the process.
func interruptProcess(p *os.Process) error {
	return windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(p.Pid))
}
