package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- harness ----

func startServer(t *testing.T, configure func(*Server)) (string, *Server) {
	t.Helper()
	srv := NewServer(log.New(io.Discard, "", 0))
	srv.power = func(string) error { return nil }
	srv.powerCheck = false
	srv.powerDelay = 0
	if configure != nil {
		configure(srv)
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve(l)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	})
	return l.Addr().String(), srv
}

type client struct {
	t *testing.T
	c net.Conn
	r *bufio.Reader
}

func dial(t *testing.T, addr string) *client {
	t.Helper()
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return &client{t: t, c: c, r: bufio.NewReaderSize(c, 1<<20)}
}

func (cl *client) sendRaw(s string) {
	cl.t.Helper()
	cl.c.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if _, err := io.WriteString(cl.c, s); err != nil {
		cl.t.Fatal(err)
	}
}

func (cl *client) recv() map[string]any {
	cl.t.Helper()
	m, err := cl.tryRecv()
	if err != nil {
		cl.t.Fatal(err)
	}
	return m
}

func (cl *client) tryRecv() (map[string]any, error) {
	cl.c.SetReadDeadline(time.Now().Add(60 * time.Second))
	line, err := cl.r.ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		return nil, fmt.Errorf("response is not JSON: %v: %q", err, line)
	}
	return m, nil
}

func (cl *client) call(req map[string]any) map[string]any {
	cl.t.Helper()
	b, err := json.Marshal(req)
	if err != nil {
		cl.t.Fatal(err)
	}
	cl.sendRaw(string(b) + "\n")
	resp := cl.recv()
	if want, _ := req["id"].(string); resp["id"] != want {
		cl.t.Fatalf("response id %v, want %q", resp["id"], want)
	}
	return resp
}

func mustOK(t *testing.T, resp map[string]any) map[string]any {
	t.Helper()
	if resp["ok"] != true {
		t.Fatalf("expected ok:true, got %v", resp)
	}
	return resp
}

func mustFail(t *testing.T, resp map[string]any, code string) {
	t.Helper()
	if resp["ok"] != false {
		t.Fatalf("expected ok:false, got %v", resp)
	}
	if msg, _ := resp["error"].(string); msg == "" {
		t.Fatalf("missing error message: %v", resp)
	}
	if code != "" && resp["code"] != code {
		t.Fatalf("error code %v, want %s (%v)", resp["code"], code, resp["error"])
	}
}

func skipNoPOSIXShell(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("exec tests need a POSIX shell (bash/sh); skipped on Windows")
	}
}

// ---- protocol ----

func TestPing(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	resp := mustOK(t, cl.call(map[string]any{"id": "p1", "op": "ping"}))
	if resp["version"] != version {
		t.Errorf("version %v, want %s", resp["version"], version)
	}
	if resp["protocol"] != float64(protocolVersion) {
		t.Errorf("protocol %v", resp["protocol"])
	}
	if up, ok := resp["uptime"].(float64); !ok || up < 0 {
		t.Errorf("uptime %v", resp["uptime"])
	}
	ops, _ := resp["ops"].([]any)
	have := map[string]bool{}
	for _, o := range ops {
		have[o.(string)] = true
	}
	for _, want := range []string{"ping", "sysinfo", "exec", "read_file", "write_file", "list_dir", "screenshot", "input", "shutdown", "reboot"} {
		if !have[want] {
			t.Errorf("ops is missing %q: %v", want, ops)
		}
	}
}

func TestResponseShape(t *testing.T) {
	// id and ok come first, op fields follow at the top level.
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	cl.sendRaw(`{"id":"shape","op":"ping"}` + "\n")
	cl.c.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := cl.r.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(line, `{"id":"shape","ok":true,"version":`) {
		t.Fatalf("unexpected response line: %s", line)
	}
}

func TestIDOptional(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	cl.sendRaw(`{"op":"ping"}` + "\n")
	resp := mustOK(t, cl.recv())
	if resp["id"] != "" {
		t.Fatalf("id %v, want empty string", resp["id"])
	}
}

func TestMalformedJSON(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	for _, bad := range []string{
		`{not json`,
		`[1,2,3]`,
		`"just a string"`,
		`{"id":"x","op":"ping"`,
		`{"id":7,"op":"ping"}`,
		`{"id":"x","op":42}`,
	} {
		cl.sendRaw(bad + "\n")
		resp := cl.recv()
		mustFail(t, resp, codeBadRequest)
		if resp["id"] != "" {
			t.Errorf("%s: id %v, want empty", bad, resp["id"])
		}
	}
	// The connection is still usable.
	mustOK(t, cl.call(map[string]any{"id": "after", "op": "ping"}))
}

func TestMissingAndUnknownOp(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	mustFail(t, cl.call(map[string]any{"id": "m1"}), codeBadRequest)
	resp := cl.call(map[string]any{"id": "u1", "op": "teleport"})
	mustFail(t, resp, codeUnknownOp)
	if !strings.Contains(resp["error"].(string), "teleport") {
		t.Errorf("error should name the op: %v", resp["error"])
	}
}

func TestBlankLinesAndCRLF(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	cl.sendRaw("\n\r\n   \n" + `{"id":"crlf","op":"ping"}` + "\r\n")
	resp := mustOK(t, cl.recv())
	if resp["id"] != "crlf" {
		t.Fatalf("got %v", resp)
	}
}

func TestPipelinedRequestsAnsweredInOrder(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	var b strings.Builder
	for i := 0; i < 5; i++ {
		fmt.Fprintf(&b, `{"id":"r%d","op":"ping"}`+"\n", i)
	}
	cl.sendRaw(b.String())
	for i := 0; i < 5; i++ {
		resp := mustOK(t, cl.recv())
		if want := fmt.Sprintf("r%d", i); resp["id"] != want {
			t.Fatalf("response %d has id %v, want %s", i, resp["id"], want)
		}
	}
}

func TestOversizedLineRejected(t *testing.T) {
	addr, _ := startServer(t, func(s *Server) { s.MaxLineBytes = 1024 })
	cl := dial(t, addr)

	// Exactly at the limit: accepted.
	prefix, suffix := `{"id":"edge","op":"ping","pad":"`, `"}`
	edge := prefix + strings.Repeat("x", 1024-len(prefix)-len(suffix)) + suffix
	if len(edge) != 1024 {
		t.Fatalf("bad test line length %d", len(edge))
	}
	cl.sendRaw(edge + "\n")
	mustOK(t, cl.recv())

	// One byte over: rejected, connection survives.
	over := prefix + strings.Repeat("x", 1025-len(prefix)-len(suffix)) + suffix
	cl.sendRaw(over + "\n")
	resp := cl.recv()
	mustFail(t, resp, codeTooLarge)
	if resp["id"] != "" {
		t.Errorf("id %v, want empty", resp["id"])
	}

	// Much larger than the read buffer.
	cl.sendRaw(`{"id":"big","op":"ping","pad":"` + strings.Repeat("y", 300_000) + "\"}\n")
	mustFail(t, cl.recv(), codeTooLarge)

	mustOK(t, cl.call(map[string]any{"id": "still-alive", "op": "ping"}))
}

func TestDefaultLineLimitIs64MiB(t *testing.T) {
	if DefaultMaxLineBytes != 64<<20 {
		t.Fatalf("DefaultMaxLineBytes = %d", DefaultMaxLineBytes)
	}
	if testing.Short() {
		t.Skip("sends 64 MiB")
	}
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	go func() {
		w := bufio.NewWriterSize(cl.c, 1<<20)
		w.WriteString(`{"id":"huge","op":"ping","pad":"`)
		chunk := strings.Repeat("z", 1<<20)
		for i := 0; i < 64; i++ {
			w.WriteString(chunk)
		}
		w.WriteString("\"}\n")
		w.Flush()
	}()
	mustFail(t, cl.recv(), codeTooLarge)
	mustOK(t, cl.call(map[string]any{"id": "after-huge", "op": "ping"}))
}

func TestFinalLineWithoutNewline(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	cl.sendRaw(`{"id":"eof","op":"ping"}`)
	cl.c.(*net.TCPConn).CloseWrite()
	resp := mustOK(t, cl.recv())
	if resp["id"] != "eof" {
		t.Fatalf("got %v", resp)
	}
}

func TestConcurrentConnections(t *testing.T) {
	addr, _ := startServer(t, nil)
	dir := t.TempDir()
	file := filepath.Join(dir, "shared.txt")
	if err := os.WriteFile(file, []byte("shared"), 0o644); err != nil {
		t.Fatal(err)
	}
	const conns, perConn = 16, 25
	var wg sync.WaitGroup
	errs := make(chan error, conns)
	for c := 0; c < conns; c++ {
		wg.Add(1)
		go func(c int) {
			defer wg.Done()
			conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
			if err != nil {
				errs <- err
				return
			}
			defer conn.Close()
			r := bufio.NewReader(conn)
			for i := 0; i < perConn; i++ {
				id := fmt.Sprintf("c%d-%d", c, i)
				op := "ping"
				extra := ""
				if i%5 == 0 {
					op = "read_file"
					b, _ := json.Marshal(file)
					extra = `,"path":` + string(b)
				}
				if _, err := fmt.Fprintf(conn, `{"id":%q,"op":%q%s}`+"\n", id, op, extra); err != nil {
					errs <- err
					return
				}
				conn.SetReadDeadline(time.Now().Add(30 * time.Second))
				line, err := r.ReadBytes('\n')
				if err != nil {
					errs <- err
					return
				}
				var resp map[string]any
				if err := json.Unmarshal(line, &resp); err != nil {
					errs <- err
					return
				}
				if resp["id"] != id || resp["ok"] != true {
					errs <- fmt.Errorf("conn %d: got %v for %s", c, resp, id)
					return
				}
			}
		}(c)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

func TestShutdownClosesListenerAndIdleConnections(t *testing.T) {
	srv := NewServer(nil)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(l) }()
	cl := dial(t, l.Addr().String())
	mustOK(t, cl.call(map[string]any{"id": "before", "op": "ping"}))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	start := time.Now()
	if err := srv.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("Shutdown took %v", d)
	}
	select {
	case err := <-served:
		if err != ErrServerClosed {
			t.Errorf("Serve returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Serve did not return")
	}
	if _, err := cl.tryRecv(); err == nil {
		t.Error("idle connection should be closed")
	}
	if c, err := net.DialTimeout("tcp", l.Addr().String(), time.Second); err == nil {
		c.Close()
		t.Error("listener still accepting")
	}
}

func TestPowerOpsScheduleAndRespond(t *testing.T) {
	calls := make(chan string, 2)
	addr, _ := startServer(t, func(s *Server) {
		s.power = func(a string) error { calls <- a; return nil }
	})
	cl := dial(t, addr)
	for op, action := range map[string]string{"shutdown": "poweroff", "reboot": "reboot"} {
		resp := mustOK(t, cl.call(map[string]any{"id": op, "op": op}))
		if resp["action"] != action {
			t.Errorf("%s: action %v", op, resp["action"])
		}
		select {
		case got := <-calls:
			if got != action {
				t.Errorf("%s: power(%q)", op, got)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: power hook not called", op)
		}
	}
}

func TestSysinfo(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	resp := mustOK(t, cl.call(map[string]any{"id": "si", "op": "sysinfo"}))
	for _, k := range []string{"hostname", "os", "kernel", "arch", "cpus", "memTotal", "memFree", "display", "tools"} {
		if _, ok := resp[k]; !ok {
			t.Errorf("sysinfo is missing %q", k)
		}
	}
	if resp["cpus"].(float64) < 1 {
		t.Errorf("cpus %v", resp["cpus"])
	}
	disp := resp["display"].(map[string]any)
	for _, k := range []string{"wayland", "x11", "env", "uid"} {
		if _, ok := disp[k]; !ok {
			t.Errorf("display is missing %q: %v", k, disp)
		}
	}
	tools := resp["tools"].(map[string]any)
	for _, k := range []string{"grim", "spectacle", "gnome-screenshot", "scrot", "import", "xwd", "xdotool", "ydotool", "wtype"} {
		if _, ok := tools[k].(bool); !ok {
			t.Errorf("tools is missing %q", k)
		}
	}
	if runtime.GOOS == "linux" {
		if resp["kernel"] == "" || resp["memTotal"].(float64) <= 0 {
			t.Errorf("kernel/memTotal not filled on Linux: %v %v", resp["kernel"], resp["memTotal"])
		}
	}
}

func TestScreenshotWithoutDesktopFailsHelpfully(t *testing.T) {
	if os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != "" {
		t.Skip("a desktop is present")
	}
	if _, err := findDesktopSession(); err == nil {
		t.Skip("a desktop session exists on this machine")
	}
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	resp := cl.call(map[string]any{"id": "shot", "op": "screenshot"})
	mustFail(t, resp, codeUnavailable)
	resp = cl.call(map[string]any{"id": "in", "op": "input", "actions": []any{map[string]any{"type": "click", "x": 1, "y": 1}}})
	mustFail(t, resp, codeUnavailable)
}

// ---- exec ----

func TestExecEcho(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	resp := mustOK(t, cl.call(map[string]any{
		"id": "e1", "op": "exec", "cmd": "echo hello; echo oops 1>&2; exit 3", "timeout_ms": 10000,
	}))
	if resp["stdout"] != "hello\n" || resp["stderr"] != "oops\n" {
		t.Errorf("stdout %q stderr %q", resp["stdout"], resp["stderr"])
	}
	if resp["exit_code"] != float64(3) || resp["timed_out"] != false || resp["truncated"] != false {
		t.Errorf("unexpected result: %v", resp)
	}
	if _, ok := resp["duration_ms"].(float64); !ok {
		t.Errorf("missing duration_ms: %v", resp)
	}
	if sh := resp["shell"]; sh != "bash" && sh != "sh" {
		t.Errorf("shell %v", sh)
	}
}

func TestExecCwdEnvStdin(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	dir := t.TempDir()
	resp := mustOK(t, cl.call(map[string]any{
		"id": "e2", "op": "exec", "cmd": `pwd; echo "$ZG_TEST"; cat`,
		"cwd": dir, "env": map[string]string{"ZG_TEST": "forty-two"}, "stdin": "from-stdin",
	}))
	lines := strings.Split(resp["stdout"].(string), "\n")
	if len(lines) < 3 {
		t.Fatalf("stdout %q", resp["stdout"])
	}
	wantDir, _ := filepath.EvalSymlinks(dir)
	gotDir, _ := filepath.EvalSymlinks(lines[0])
	if gotDir != wantDir {
		t.Errorf("pwd %q, want %q", lines[0], dir)
	}
	if lines[1] != "forty-two" || lines[2] != "from-stdin" {
		t.Errorf("stdout %q", resp["stdout"])
	}
	mustFail(t, cl.call(map[string]any{"id": "e3", "op": "exec", "cmd": "true", "cwd": filepath.Join(dir, "nope")}), codeNotFound)
	mustFail(t, cl.call(map[string]any{"id": "e4", "op": "exec", "cmd": "true", "cwd": "relative/dir"}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "e5", "op": "exec", "cmd": "  "}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "e6", "op": "exec", "cmd": "true", "timeout_ms": -1}), codeBadRequest)
}

func TestExecStdinDefaultsToEOF(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	resp := mustOK(t, cl.call(map[string]any{"id": "cat", "op": "exec", "cmd": "cat; echo done", "timeout_ms": 5000}))
	if resp["stdout"] != "done\n" || resp["timed_out"] != false {
		t.Fatalf("cat should see EOF immediately: %v", resp)
	}
}

func TestExecTimeoutKillsProcessGroup(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	start := time.Now()
	resp := mustOK(t, cl.call(map[string]any{
		"id": "slow", "op": "exec", "cmd": "sleep 30 & echo $!; sleep 30", "timeout_ms": 500,
	}))
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("exec took %v despite a 500 ms timeout", d)
	}
	if resp["timed_out"] != true {
		t.Fatalf("timed_out not set: %v", resp)
	}
	if resp["exit_code"] != float64(-1) || resp["signal"] != "SIGKILL" {
		t.Errorf("exit_code %v signal %v", resp["exit_code"], resp["signal"])
	}
	pid, err := strconv.Atoi(strings.TrimSpace(resp["stdout"].(string)))
	if err != nil {
		t.Fatalf("background pid not printed: %q", resp["stdout"])
	}
	// The background child was in the same process group and must be gone.
	deadline := time.Now().Add(5 * time.Second)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("background process %d survived the timeout", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestExecBackgroundChildDoesNotBlock(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	start := time.Now()
	// The child inherits stdout; exec returns shortly after the shell exits.
	resp := mustOK(t, cl.call(map[string]any{"id": "bg", "op": "exec", "cmd": "sleep 20 & echo started", "timeout_ms": 15000}))
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("exec waited %v for a background child", d)
	}
	if resp["stdout"] != "started\n" || resp["exit_code"] != float64(0) || resp["timed_out"] != false {
		t.Fatalf("unexpected: %v", resp)
	}
}

func TestExecOutputTruncated(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, func(s *Server) { s.MaxOutputBytes = 100 })
	cl := dial(t, addr)
	resp := mustOK(t, cl.call(map[string]any{
		"id": "big", "op": "exec",
		"cmd": `i=0; while [ $i -lt 50 ]; do echo 0123456789; echo e >&2; i=$((i+1)); done`,
	}))
	if out := resp["stdout"].(string); len(out) != 100 || !strings.HasPrefix(out, "0123456789\n") {
		t.Errorf("stdout length %d: %q", len(out), out)
	}
	if resp["stdout_truncated"] != true || resp["stderr_truncated"] != false || resp["truncated"] != true {
		t.Errorf("truncation flags: %v", resp)
	}
	if resp["exit_code"] != float64(0) {
		t.Errorf("exit_code %v", resp["exit_code"])
	}
}

func TestSlowRequestDoesNotBlockOtherConnections(t *testing.T) {
	skipNoPOSIXShell(t)
	addr, _ := startServer(t, nil)
	slow := dial(t, addr)
	fast := dial(t, addr)
	slow.sendRaw(`{"id":"slow","op":"exec","cmd":"sleep 2"}` + "\n")
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	mustOK(t, fast.call(map[string]any{"id": "fast", "op": "ping"}))
	if d := time.Since(start); d > time.Second {
		t.Errorf("ping on another connection took %v", d)
	}
	resp := mustOK(t, slow.recv())
	if resp["id"] != "slow" {
		t.Fatalf("got %v", resp)
	}
}

// ---- files ----

func TestFileRoundtrip(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "deeper", "hello.txt")
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

	// Parent missing without mkdir.
	mustFail(t, cl.call(map[string]any{"id": "w0", "op": "write_file", "path": path, "data_b64": b64("x")}), codeNotFound)

	resp := mustOK(t, cl.call(map[string]any{
		"id": "w1", "op": "write_file", "path": path, "data_b64": b64("hello world"), "mode": "0600", "mkdir": true,
	}))
	if resp["written"] != float64(11) || resp["size"] != float64(11) {
		t.Errorf("write result %v", resp)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("mode %v, want 0600", st.Mode().Perm())
		}
	}

	resp = mustOK(t, cl.call(map[string]any{"id": "r1", "op": "read_file", "path": path}))
	if data, _ := base64.StdEncoding.DecodeString(resp["data_b64"].(string)); string(data) != "hello world" {
		t.Errorf("read %q", data)
	}
	if resp["size"] != float64(11) || resp["truncated"] != false {
		t.Errorf("read result %v", resp)
	}

	resp = mustOK(t, cl.call(map[string]any{"id": "r2", "op": "read_file", "path": path, "max_bytes": 5}))
	if data, _ := base64.StdEncoding.DecodeString(resp["data_b64"].(string)); string(data) != "hello" || resp["truncated"] != true {
		t.Errorf("truncated read %q %v", data, resp)
	}
	resp = mustOK(t, cl.call(map[string]any{"id": "r3", "op": "read_file", "path": path, "offset": 6}))
	if data, _ := base64.StdEncoding.DecodeString(resp["data_b64"].(string)); string(data) != "world" || resp["truncated"] != false {
		t.Errorf("offset read %q %v", data, resp)
	}

	mustOK(t, cl.call(map[string]any{"id": "w2", "op": "write_file", "path": path, "data_b64": b64("!"), "append": true}))
	if b, _ := os.ReadFile(path); string(b) != "hello world!" {
		t.Errorf("after append: %q", b)
	}
	mustOK(t, cl.call(map[string]any{"id": "w3", "op": "write_file", "path": path, "data_b64": b64("new"), "mode": 420}))
	if b, _ := os.ReadFile(path); string(b) != "new" {
		t.Errorf("after overwrite: %q", b)
	}
	empty := filepath.Join(dir, "empty")
	mustOK(t, cl.call(map[string]any{"id": "w4", "op": "write_file", "path": empty, "data_b64": ""}))
	if st, err := os.Stat(empty); err != nil || st.Size() != 0 {
		t.Errorf("empty file: %v %v", st, err)
	}

	resp = mustOK(t, cl.call(map[string]any{"id": "l1", "op": "list_dir", "path": filepath.Join(dir, "sub")}))
	ents := resp["entries"].([]any)
	if len(ents) != 1 {
		t.Fatalf("entries %v", ents)
	}
	e := ents[0].(map[string]any)
	if e["name"] != "deeper" || e["isDir"] != true || e["isSymlink"] != false {
		t.Errorf("entry %v", e)
	}
	resp = mustOK(t, cl.call(map[string]any{"id": "l2", "op": "list_dir", "path": filepath.Dir(path)}))
	e = resp["entries"].([]any)[0].(map[string]any)
	if e["name"] != "hello.txt" || e["isDir"] != false || e["size"] != float64(3) {
		t.Errorf("entry %v", e)
	}
	if m, _ := e["mode"].(string); !strings.HasPrefix(m, "-") {
		t.Errorf("mode %q", m)
	}
	if mt, _ := e["mtime"].(float64); mt < float64(time.Now().Add(-time.Hour).Unix()) {
		t.Errorf("mtime %v", e["mtime"])
	}
	resp = mustOK(t, cl.call(map[string]any{"id": "l3", "op": "list_dir", "path": t.TempDir()}))
	if ents, ok := resp["entries"].([]any); !ok || len(ents) != 0 {
		t.Errorf("empty dir should give entries: [] (got %v)", resp["entries"])
	}
}

func TestFileErrors(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing.txt")
	mustFail(t, cl.call(map[string]any{"id": "1", "op": "read_file", "path": missing}), codeNotFound)
	mustFail(t, cl.call(map[string]any{"id": "2", "op": "read_file", "path": dir}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "3", "op": "read_file", "path": "relative.txt"}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "4", "op": "read_file"}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "5", "op": "write_file", "path": missing, "data_b64": "!!!not base64"}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "6", "op": "write_file", "path": missing}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "7", "op": "write_file", "path": missing, "data_b64": "", "mode": "rwx"}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "8", "op": "list_dir", "path": missing}), codeNotFound)
	file := filepath.Join(dir, "f")
	os.WriteFile(file, []byte("x"), 0o644)
	mustFail(t, cl.call(map[string]any{"id": "9", "op": "list_dir", "path": file}), codeBadRequest)
	mustFail(t, cl.call(map[string]any{"id": "10", "op": "read_file", "path": file, "max_bytes": -1}), codeBadRequest)
}

func TestLargeFileRoundtrip(t *testing.T) {
	addr, _ := startServer(t, nil)
	cl := dial(t, addr)
	path := filepath.Join(t.TempDir(), "big.bin")
	data := make([]byte, 5<<20)
	for i := range data {
		data[i] = byte(i * 7)
	}
	mustOK(t, cl.call(map[string]any{"id": "wb", "op": "write_file", "path": path, "data_b64": base64.StdEncoding.EncodeToString(data)}))
	resp := mustOK(t, cl.call(map[string]any{"id": "rb", "op": "read_file", "path": path}))
	got, err := base64.StdEncoding.DecodeString(resp["data_b64"].(string))
	if err != nil || len(got) != len(data) || string(got) != string(data) {
		t.Fatalf("large roundtrip mismatch (len %d, err %v)", len(got), err)
	}
}
