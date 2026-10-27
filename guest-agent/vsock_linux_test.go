//go:build linux && !386

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestSockaddrVMLayout(t *testing.T) {
	if s := unsafe.Sizeof(rawSockaddrVM{}); s != 16 {
		t.Fatalf("sizeof(sockaddr_vm) = %d, want 16", s)
	}
	var sa rawSockaddrVM
	if off := unsafe.Offsetof(sa.Port); off != 4 {
		t.Fatalf("svm_port offset %d", off)
	}
	if off := unsafe.Offsetof(sa.CID); off != 8 {
		t.Fatalf("svm_cid offset %d", off)
	}
}

// listenTestVsock listens on a free-ish port or skips when the kernel has no
// AF_VSOCK support (common on CI runners and containers).
func listenTestVsock(t *testing.T) (net.Listener, uint32) {
	t.Helper()
	port := uint32(40000 + os.Getpid()%20000)
	l, err := listenVsock(port)
	if err != nil {
		t.Skipf("AF_VSOCK unavailable here: %v", err)
	}
	return l, port
}

func TestVsockListenerCloseUnblocksAccept(t *testing.T) {
	l, port := listenTestVsock(t)
	if a, ok := l.Addr().(vsockAddr); !ok || a.Port != port || a.CID != vmaddrCIDAny {
		t.Fatalf("Addr() = %v", l.Addr())
	}
	done := make(chan error, 1)
	go func() {
		_, err := l.Accept()
		done <- err
	}()
	time.Sleep(100 * time.Millisecond)
	l.Close()
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("Accept after Close returned %v, want net.ErrClosed", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Accept did not return after Close")
	}
}

// dialVsockLocal connects to the local CID (needs the vsock_loopback transport).
func dialVsockLocal(port uint32) (net.Conn, error) {
	const vmaddrCIDLocal = 1
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	sa := rawSockaddrVM{Family: afVsock, Port: port, CID: vmaddrCIDLocal}
	if _, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa)); errno != 0 {
		syscall.Close(fd)
		return nil, errno
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	return &vsockConn{File: os.NewFile(uintptr(fd), "vsock-test"), remote: vsockAddr{vmaddrCIDLocal, port}}, nil
}

func TestVsockPingOverLoopback(t *testing.T) {
	l, port := listenTestVsock(t)
	srv := NewServer(nil)
	go srv.Serve(l)
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()

	type result struct {
		c   net.Conn
		err error
	}
	ch := make(chan result, 1)
	go func() { c, err := dialVsockLocal(port); ch <- result{c, err} }()
	var c net.Conn
	select {
	case r := <-ch:
		if r.err != nil {
			t.Skipf("no vsock loopback transport (modprobe vsock_loopback): %v", r.err)
		}
		c = r.c
	case <-time.After(5 * time.Second):
		t.Skip("vsock connect to the local CID timed out")
	}
	defer c.Close()

	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := c.Write([]byte(`{"id":"v1","op":"ping"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var resp map[string]any
	if err := json.Unmarshal(line, &resp); err != nil || resp["id"] != "v1" || resp["ok"] != true {
		t.Fatalf("response %s (%v)", line, err)
	}
}
