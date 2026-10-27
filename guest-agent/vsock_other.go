//go:build !linux || 386

package main

import (
	"fmt"
	"net"
	"runtime"
)

// listenVsock is unavailable off Linux (the agent only ships for linux/amd64
// and linux/arm64); use --tcp instead.
func listenVsock(port uint32) (net.Listener, error) {
	return nil, fmt.Errorf("AF_VSOCK is not supported on %s/%s; use --tcp", runtime.GOOS, runtime.GOARCH)
}
