// Command zguest is the Z Computer guest agent: a small daemon inside the
// Linux VM that lets the macOS host app run commands, move files, take
// screenshots and inject input. It listens on AF_VSOCK port 5555 (or TCP
// with --tcp) and speaks newline-delimited JSON; see PROTOCOL.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

// version is overridable at build time: -ldflags "-X main.version=1.2.3".
var version = "0.1.0"

func main() {
	var (
		tcpAddr     = flag.String("tcp", "", "listen on this TCP address instead of AF_VSOCK, e.g. 127.0.0.1:5555 (unauthenticated: never expose it outside a private network)")
		port        = flag.Uint("port", 5555, "AF_VSOCK port to listen on")
		showVersion = flag.Bool("version", false, "print the version and exit")
	)
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "usage: zguest [--port N | --tcp HOST:PORT] [--version]\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() > 0 {
		flag.Usage()
		os.Exit(2)
	}
	if *showVersion {
		fmt.Printf("zguest %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}

	logFlags := log.LstdFlags
	if os.Getenv("JOURNAL_STREAM") != "" {
		logFlags = 0 // journald timestamps every line already
	}
	logger := log.New(os.Stderr, "", logFlags)

	var (
		l   net.Listener
		err error
	)
	if *tcpAddr != "" {
		l, err = net.Listen("tcp", *tcpAddr)
	} else {
		l, err = listenVsockRetry(uint32(*port), logger)
	}
	if err != nil {
		logger.Printf("listen: %v", err)
		os.Exit(1)
	}
	logger.Printf("zguest %s listening on %s (pid %d, euid %d)", version, l.Addr(), os.Getpid(), os.Geteuid())

	srv := NewServer(logger)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, os.Interrupt)
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(l) }()

	select {
	case sig := <-sigs:
		logger.Printf("received %v, shutting down", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			logger.Printf("shutdown: %v (running commands were killed)", err)
		}
		logger.Printf("stopped")
	case err := <-errc:
		if !errors.Is(err, ErrServerClosed) {
			logger.Printf("serve: %v", err)
			os.Exit(1)
		}
	}
}

// listenVsockRetry retries for a while: the virtio vsock transport can come
// up after early-boot services have started.
func listenVsockRetry(port uint32, logger *log.Logger) (net.Listener, error) {
	deadline := time.Now().Add(30 * time.Second)
	for {
		l, err := listenVsock(port)
		if err == nil || runtime.GOOS != "linux" || time.Now().After(deadline) {
			return l, err
		}
		logger.Printf("vsock port %d: %v; retrying", port, err)
		time.Sleep(2 * time.Second)
	}
}
