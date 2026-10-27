//go:build linux && !386

package main

// AF_VSOCK listener built on the standard syscall package only.
//
// The syscall package has no SockaddrVM, and syscall.Accept closes any
// accepted socket whose address family it does not know, so bind and accept4
// are issued as raw syscalls with a hand-packed sockaddr_vm. net.FileListener
// and net.FileConn cannot be used either: they reject every family other than
// AF_INET/AF_INET6/AF_UNIX with EPROTONOSUPPORT. Instead the non-blocking
// sockets are wrapped in *os.File, which registers them with the runtime
// poller, so Read/Write block without tying up OS threads and the deadline
// methods work (net.Conn is satisfied by *os.File plus two address methods).
//
// linux/386 is excluded because it multiplexes socket calls through
// socketcall(2) and has no SYS_BIND/SYS_ACCEPT4.

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sync/atomic"
	"syscall"
	"unsafe"
)

const (
	afVsock      = 40         // AF_VSOCK
	vmaddrCIDAny = 0xFFFFFFFF // VMADDR_CID_ANY
)

// rawSockaddrVM mirrors struct sockaddr_vm from <linux/vm_sockets.h>:
// family, reserved, port, cid, then 4 bytes that must be zero (newer kernels
// name the first of them svm_flags). 16 bytes, host byte order.
type rawSockaddrVM struct {
	Family    uint16
	Reserved1 uint16
	Port      uint32
	CID       uint32
	Zero      [4]uint8
}

// vsockAddr is a net.Addr for AF_VSOCK endpoints.
type vsockAddr struct {
	CID  uint32
	Port uint32
}

func (a vsockAddr) Network() string { return "vsock" }

func (a vsockAddr) String() string {
	if a.CID == vmaddrCIDAny {
		return fmt.Sprintf("vsock:any:%d", a.Port)
	}
	return fmt.Sprintf("vsock:%d:%d", a.CID, a.Port)
}

type vsockListener struct {
	f      *os.File
	rc     syscall.RawConn
	addr   vsockAddr
	closed atomic.Bool
}

// listenVsock listens on the given AF_VSOCK port for any CID.
func listenVsock(port uint32) (net.Listener, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, os.NewSyscallError("socket(AF_VSOCK)", err)
	}
	sa := rawSockaddrVM{Family: afVsock, Port: port, CID: vmaddrCIDAny}
	if _, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa)); errno != 0 {
		syscall.Close(fd)
		return nil, os.NewSyscallError("bind", errno)
	}
	if err := syscall.Listen(fd, syscall.SOMAXCONN); err != nil {
		syscall.Close(fd)
		return nil, os.NewSyscallError("listen", err)
	}
	addr := vsockAddr{CID: vmaddrCIDAny, Port: port}
	f := os.NewFile(uintptr(fd), addr.String())
	rc, err := f.SyscallConn()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &vsockListener{f: f, rc: rc, addr: addr}, nil
}

func (l *vsockListener) Accept() (net.Conn, error) {
	var (
		nfd   int
		peer  rawSockaddrVM
		errno syscall.Errno
	)
	err := l.rc.Read(func(fd uintptr) bool {
		for {
			var sa rawSockaddrVM
			salen := uint32(unsafe.Sizeof(sa))
			r, _, e := syscall.Syscall6(syscall.SYS_ACCEPT4, fd,
				uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&salen)),
				syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC, 0, 0)
			switch e {
			case syscall.EINTR:
				continue
			case syscall.EAGAIN:
				return false // not ready: let the poller wait for the next connection
			}
			nfd, peer, errno = int(r), sa, e
			return true
		}
	})
	if err != nil {
		// A closed *os.File reports "use of closed file"; net.Listener
		// callers expect net.ErrClosed.
		if l.closed.Load() || errors.Is(err, os.ErrClosed) {
			err = net.ErrClosed
		}
		return nil, &net.OpError{Op: "accept", Net: "vsock", Addr: l.addr, Err: err}
	}
	if errno != 0 {
		return nil, &net.OpError{Op: "accept", Net: "vsock", Addr: l.addr, Err: os.NewSyscallError("accept4", errno)}
	}
	remote := vsockAddr{CID: peer.CID, Port: peer.Port}
	return &vsockConn{File: os.NewFile(uintptr(nfd), remote.String()), local: l.addr, remote: remote}, nil
}

func (l *vsockListener) Close() error {
	l.closed.Store(true)
	return l.f.Close()
}

func (l *vsockListener) Addr() net.Addr { return l.addr }

// vsockConn is an accepted AF_VSOCK stream. *os.File provides Read, Write,
// Close and the deadline methods.
type vsockConn struct {
	*os.File
	local, remote vsockAddr
}

func (c *vsockConn) LocalAddr() net.Addr  { return c.local }
func (c *vsockConn) RemoteAddr() net.Addr { return c.remote }
