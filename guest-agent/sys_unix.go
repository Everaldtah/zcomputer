//go:build linux || darwin || freebsd || netbsd || openbsd || dragonfly

package main

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"syscall"
)

// configureCmd puts the command in its own process group (so a timeout can
// kill everything it spawned) and, when cred is non-nil, runs it as that user.
func configureCmd(cmd *exec.Cmd, cred *procCred) {
	attr := &syscall.SysProcAttr{Setpgid: true}
	if cred != nil {
		attr.Credential = &syscall.Credential{Uid: cred.uid, Gid: cred.gid, Groups: cred.groups}
	}
	cmd.SysProcAttr = attr
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		// A negative pid signals the whole process group.
		if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
			if err == syscall.ESRCH {
				return os.ErrProcessDone
			}
			return err
		}
		return nil
	}
}

// fileOwner returns the uid/gid of a file.
func fileOwner(fi fs.FileInfo) (uid, gid int, ok bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return int(st.Uid), int(st.Gid), true
}

// signalName returns e.g. "SIGKILL" when the process was killed by a signal.
func signalName(ps *os.ProcessState) string {
	if ps == nil {
		return ""
	}
	ws, ok := ps.Sys().(syscall.WaitStatus)
	if !ok || !ws.Signaled() {
		return ""
	}
	switch sig := ws.Signal(); sig {
	case syscall.SIGKILL:
		return "SIGKILL"
	case syscall.SIGTERM:
		return "SIGTERM"
	case syscall.SIGINT:
		return "SIGINT"
	case syscall.SIGHUP:
		return "SIGHUP"
	case syscall.SIGQUIT:
		return "SIGQUIT"
	case syscall.SIGABRT:
		return "SIGABRT"
	case syscall.SIGSEGV:
		return "SIGSEGV"
	case syscall.SIGBUS:
		return "SIGBUS"
	case syscall.SIGFPE:
		return "SIGFPE"
	case syscall.SIGILL:
		return "SIGILL"
	case syscall.SIGPIPE:
		return "SIGPIPE"
	default:
		return fmt.Sprintf("SIG%d", int(sig))
	}
}
