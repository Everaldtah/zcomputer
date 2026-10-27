package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"runtime/debug"
	"sort"
	"sync"
	"time"
)

const (
	// DefaultMaxLineBytes is the longest accepted request line (64 MiB, enough
	// for a base64 payload of ~48 MiB). The trailing newline is not counted.
	DefaultMaxLineBytes = 64 << 20
	// DefaultMaxOutputBytes caps each of stdout and stderr captured by exec.
	DefaultMaxOutputBytes = 8 << 20
)

// ErrServerClosed is returned by Serve after Shutdown.
var ErrServerClosed = errors.New("zguest: server closed")

// handlerFunc runs one op. raw is the complete request line.
type handlerFunc func(ctx context.Context, s *Server, raw []byte) (any, error)

// handlers is filled in init() (a map literal would create an initialization
// cycle because ping lists the ops).
var handlers map[string]handlerFunc

func init() {
	handlers = map[string]handlerFunc{
		"ping":       opPing,
		"sysinfo":    opSysinfo,
		"exec":       opExec,
		"read_file":  opReadFile,
		"write_file": opWriteFile,
		"list_dir":   opListDir,
		"screenshot": opScreenshot,
		"input":      opInput,
		"shutdown":   opShutdown,
		"reboot":     opReboot,
	}
}

func opNames() []string {
	names := make([]string, 0, len(handlers))
	for n := range handlers {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Server accepts connections and answers newline-delimited JSON requests.
// Connections are served concurrently; requests on one connection are
// handled one after another, so responses come back in request order.
type Server struct {
	MaxLineBytes   int
	MaxOutputBytes int
	Log            *log.Logger

	// power performs "poweroff" / "reboot" after powerDelay; powerCheck
	// verifies up front that a power command exists. Replaced in tests.
	power      func(action string) error
	powerCheck bool
	powerDelay time.Duration

	started time.Time
	ctx     context.Context // cancelled when shutdown gives up waiting
	cancel  context.CancelFunc
	desk    sessionCache

	mu        sync.Mutex
	closing   bool
	listeners map[net.Listener]struct{}
	conns     map[net.Conn]struct{}
	wg        sync.WaitGroup
}

// NewServer returns a server with default limits.
func NewServer(logger *log.Logger) *Server {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		MaxLineBytes:   DefaultMaxLineBytes,
		MaxOutputBytes: DefaultMaxOutputBytes,
		Log:            logger,
		power:          systemPower,
		powerCheck:     true,
		powerDelay:     500 * time.Millisecond,
		started:        time.Now(),
		ctx:            ctx,
		cancel:         cancel,
		listeners:      map[net.Listener]struct{}{},
		conns:          map[net.Conn]struct{}{},
	}
}

// Serve accepts connections on l until Shutdown is called or l fails.
func (s *Server) Serve(l net.Listener) error {
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		l.Close()
		return ErrServerClosed
	}
	s.listeners[l] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.listeners, l)
		s.mu.Unlock()
	}()

	var backoff time.Duration
	for {
		c, err := l.Accept()
		if err != nil {
			if s.isClosing() {
				return ErrServerClosed
			}
			if errors.Is(err, net.ErrClosed) {
				return err
			}
			// EMFILE, ECONNABORTED, ...: wait a little and keep accepting.
			if backoff == 0 {
				backoff = 5 * time.Millisecond
			} else if backoff *= 2; backoff > time.Second {
				backoff = time.Second
			}
			s.Log.Printf("accept: %v; retrying in %v", err, backoff)
			time.Sleep(backoff)
			continue
		}
		backoff = 0
		if !s.track(c) {
			c.Close()
			continue
		}
		go s.serveConn(c)
	}
}

// track registers a connection; false when the server is shutting down.
func (s *Server) track(c net.Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return false
	}
	s.conns[c] = struct{}{}
	s.wg.Add(1) // under mu and before closing is set, so never races with Wait
	return true
}

func (s *Server) untrack(c net.Conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
	s.wg.Done()
}

func (s *Server) isClosing() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closing
}

// Shutdown stops accepting, lets in-flight requests finish and closes idle
// connections. When ctx expires first, running commands are killed and all
// connections are closed.
func (s *Server) Shutdown(ctx context.Context) error {
	s.mu.Lock()
	s.closing = true
	for l := range s.listeners {
		l.Close()
	}
	for c := range s.conns {
		// Wakes connections blocked reading the next request; a connection
		// in the middle of a request finishes it first.
		c.SetReadDeadline(time.Now())
	}
	s.mu.Unlock()

	done := make(chan struct{})
	go func() { s.wg.Wait(); close(done) }()
	select {
	case <-done:
		s.cancel()
		return nil
	case <-ctx.Done():
	}
	s.cancel()
	s.mu.Lock()
	for c := range s.conns {
		c.Close()
	}
	s.mu.Unlock()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
	return ctx.Err()
}

func (s *Server) serveConn(c net.Conn) {
	defer s.untrack(c)
	defer c.Close()
	remote := c.RemoteAddr().String()
	s.Log.Printf("connection from %s", remote)
	r := bufio.NewReaderSize(c, 64<<10)
	w := bufio.NewWriterSize(c, 64<<10)
	for {
		line, tooLong, err := readLine(r, s.MaxLineBytes)
		if err == nil || err == io.EOF {
			var resp []byte
			if tooLong {
				resp = encodeError("", errf(codeTooLarge, "request line exceeds %d bytes", s.MaxLineBytes))
				s.Log.Printf("%s: rejected request line over %d bytes", remote, s.MaxLineBytes)
			} else {
				resp = s.handleLine(remote, line)
			}
			if resp != nil {
				if _, werr := w.Write(append(resp, '\n')); werr != nil {
					s.Log.Printf("%s: write: %v", remote, werr)
					return
				}
				if werr := w.Flush(); werr != nil {
					s.Log.Printf("%s: write: %v", remote, werr)
					return
				}
			}
		}
		if err != nil {
			if err != io.EOF && !s.isClosing() {
				s.Log.Printf("%s: read: %v", remote, err)
			}
			s.Log.Printf("connection from %s closed", remote)
			return
		}
		if s.isClosing() {
			return
		}
	}
}

// readLine reads one '\n'-terminated line. Lines longer than max bytes
// (excluding the newline) are consumed and discarded and reported with
// tooLong=true so the connection can continue with the next line. At EOF the
// final unterminated line, if any, is returned together with io.EOF.
func readLine(r *bufio.Reader, max int) (line []byte, tooLong bool, err error) {
	for {
		frag, err := r.ReadSlice('\n')
		if !tooLong {
			n := len(frag)
			if err == nil {
				n-- // the newline itself does not count
			}
			if len(line)+n > max {
				tooLong, line = true, nil
			} else {
				line = append(line, frag...)
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		return line, tooLong, err
	}
}

// handleLine decodes and runs one request and returns the response line
// (without newline), or nil for a blank line.
func (s *Server) handleLine(remote string, line []byte) (resp []byte) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil
	}
	var hdr requestHeader
	if err := decodeHeader(line, &hdr); err != nil {
		s.Log.Printf("%s: bad request: %v", remote, err)
		return encodeError("", err)
	}
	id, err := parseID(hdr.ID)
	if err != nil {
		return encodeError("", err)
	}
	if hdr.Op == "" {
		return encodeError(id, errf(codeBadRequest, `missing "op"`))
	}
	h, ok := handlers[hdr.Op]
	if !ok {
		return encodeError(id, errf(codeUnknownOp, "unknown op %q (known: %v)", hdr.Op, opNames()))
	}

	start := time.Now()
	defer func() {
		if p := recover(); p != nil {
			s.Log.Printf("%s: panic in %s: %v\n%s", remote, hdr.Op, p, debug.Stack())
			resp = encodeError(id, errf(codeInternal, "internal error in %s: %v", hdr.Op, p))
		}
	}()
	result, err := h(s.ctx, s, line)
	dur := time.Since(start).Round(time.Millisecond)
	if err != nil {
		s.Log.Printf("%s: %s id=%q failed after %v: %v", remote, hdr.Op, id, dur, err)
		return encodeError(id, err)
	}
	if hdr.Op != "ping" {
		s.Log.Printf("%s: %s id=%q ok (%v)", remote, hdr.Op, id, dur)
	}
	return encodeSuccess(id, result)
}

func decodeHeader(line []byte, hdr *requestHeader) error {
	if line[0] != '{' {
		return errf(codeBadRequest, "malformed request: expected a JSON object")
	}
	if err := json.Unmarshal(line, hdr); err != nil {
		return errf(codeBadRequest, "malformed JSON request: %v", err)
	}
	return nil
}

// uptime returns how long the agent has been running.
func (s *Server) uptime() time.Duration { return time.Since(s.started) }
