//go:build !(linux || darwin || freebsd || netbsd || openbsd || dragonfly)

package main

// processAlive is unused here: the exec tests that call it are skipped.
func processAlive(pid int) bool { return false }
