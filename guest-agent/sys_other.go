//go:build !(linux || darwin || freebsd || netbsd || openbsd || dragonfly)

package main

import (
	"io/fs"
	"os"
	"os/exec"
)

// configureCmd: no process groups or credential switching on this platform;
// the default Cancel (kill the direct child) applies. The agent itself only
// targets Linux; this file exists so the package builds and its tests run
// elsewhere.
func configureCmd(cmd *exec.Cmd, cred *procCred) {}

func fileOwner(fi fs.FileInfo) (uid, gid int, ok bool) { return 0, 0, false }

func signalName(ps *os.ProcessState) string { return "" }
