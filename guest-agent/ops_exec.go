package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultExecTimeout = 60 * time.Second
	maxExecTimeout     = 24 * time.Hour
	// execWaitDelay bounds how long exec waits for the output pipes after the
	// shell has exited (a background child that did not redirect its output
	// keeps them open).
	execWaitDelay = 2 * time.Second
)

type execParams struct {
	Cmd       string            `json:"cmd"`
	TimeoutMS int64             `json:"timeout_ms"`
	Cwd       string            `json:"cwd"`
	Env       map[string]string `json:"env"`
	Stdin     string            `json:"stdin"`
	Desktop   bool              `json:"desktop"`
}

type execResult struct {
	Stdout          string `json:"stdout"`
	Stderr          string `json:"stderr"`
	ExitCode        int    `json:"exit_code"`
	Signal          string `json:"signal,omitempty"`
	TimedOut        bool   `json:"timed_out"`
	Truncated       bool   `json:"truncated"`
	StdoutTruncated bool   `json:"stdout_truncated"`
	StderrTruncated bool   `json:"stderr_truncated"`
	DurationMS      int64  `json:"duration_ms"`
	Shell           string `json:"shell"`
	User            string `json:"user,omitempty"`
}

func opExec(ctx context.Context, s *Server, raw []byte) (any, error) {
	var p execParams
	if err := decodeParams(raw, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Cmd) == "" {
		return nil, errf(codeBadRequest, `"cmd" is required`)
	}
	timeout := defaultExecTimeout
	switch {
	case p.TimeoutMS < 0:
		return nil, errf(codeBadRequest, `"timeout_ms" must not be negative`)
	case p.TimeoutMS > 0:
		timeout = time.Duration(p.TimeoutMS) * time.Millisecond
		if timeout > maxExecTimeout {
			timeout = maxExecTimeout
		}
	}

	var sess *desktopSession
	if p.Desktop {
		var err error
		if sess, err = s.desktop(); err != nil {
			return nil, err
		}
	}

	argv, shell, err := shellArgv(p.Cmd)
	if err != nil {
		return nil, err
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(tctx, argv[0], argv[1:]...)

	var cred *procCred
	var base []string
	if sess != nil {
		base = sess.environ(nil)
		cmd.Dir = sess.workDir()
		cred = sess.cred()
	} else {
		base = os.Environ()
		if home := os.Getenv("HOME"); home != "" && isDir(home) {
			cmd.Dir = home
		}
	}
	cmd.Env = mergeEnv(mergeEnv(base, execEnvDefaults(base)), p.Env)
	if p.Cwd != "" {
		if !filepath.IsAbs(p.Cwd) {
			return nil, errf(codeBadRequest, "cwd must be an absolute path: %q", p.Cwd)
		}
		st, err := os.Stat(p.Cwd)
		if err != nil {
			return nil, err
		}
		if !st.IsDir() {
			return nil, errf(codeBadRequest, "cwd is not a directory: %q", p.Cwd)
		}
		cmd.Dir = p.Cwd
	}
	if p.Stdin != "" {
		cmd.Stdin = strings.NewReader(p.Stdin)
	}
	stdout := &capBuffer{max: s.MaxOutputBytes}
	stderr := &capBuffer{max: s.MaxOutputBytes}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	configureCmd(cmd, cred)
	cmd.WaitDelay = execWaitDelay

	start := time.Now()
	runErr := cmd.Run()
	res := execResult{
		DurationMS: time.Since(start).Milliseconds(),
		Shell:      shell,
	}
	if cmd.ProcessState == nil {
		return nil, errf(codeFailed, "cannot start %s: %v", shell, runErr)
	}
	if ctx.Err() != nil {
		return nil, errf(codeFailed, "agent is shutting down; command was killed")
	}
	// From here runErr is an *exec.ExitError (non-zero exit or signal) or
	// exec.ErrWaitDelay (a background child kept the pipes open); the process
	// state tells the client everything either way.
	res.ExitCode = cmd.ProcessState.ExitCode()
	res.Signal = signalName(cmd.ProcessState)
	// Timed out = the deadline passed and the shell did not exit on its own
	// (it was killed with its process group).
	res.TimedOut = errors.Is(tctx.Err(), context.DeadlineExceeded) && !cmd.ProcessState.Exited()
	res.Stdout, res.Stderr = stdout.String(), stderr.String()
	res.StdoutTruncated, res.StderrTruncated = stdout.truncated, stderr.truncated
	res.Truncated = stdout.truncated || stderr.truncated
	if sess != nil {
		res.User = sess.User
	}
	return res, nil
}

// execEnvDefaults returns variables that keep non-interactive commands from
// waiting for a terminal or a prompt, for those not already set.
func execEnvDefaults(base []string) map[string]string {
	defaults := map[string]string{"TERM": "dumb", "DEBIAN_FRONTEND": "noninteractive"}
	for _, kv := range base {
		if k, _, ok := strings.Cut(kv, "="); ok {
			delete(defaults, k)
		}
	}
	return defaults
}

// shellArgv wraps cmd in `bash -lc` (login shell, so PATH and profile
// settings match an interactive login), falling back to `sh -c`.
func shellArgv(cmd string) (argv []string, shell string, err error) {
	if p, err := exec.LookPath("bash"); err == nil {
		return []string{p, "-lc", cmd}, "bash", nil
	}
	if p, err := exec.LookPath("sh"); err == nil {
		return []string{p, "-c", cmd}, "sh", nil
	}
	return nil, "", errf(codeUnavailable, "neither bash nor sh is installed")
}

// capBuffer keeps the first max bytes written to it and drops the rest, so a
// chatty command never blocks on a full pipe or exhausts memory.
type capBuffer struct {
	buf       bytes.Buffer
	max       int
	truncated bool
}

func (c *capBuffer) Write(p []byte) (int, error) {
	room := c.max - c.buf.Len()
	switch {
	case room <= 0:
		if len(p) > 0 {
			c.truncated = true
		}
	case len(p) > room:
		c.buf.Write(p[:room])
		c.truncated = true
	default:
		c.buf.Write(p)
	}
	return len(p), nil
}

func (c *capBuffer) Bytes() []byte  { return c.buf.Bytes() }
func (c *capBuffer) String() string { return c.buf.String() }
