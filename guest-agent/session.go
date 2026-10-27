package main

// Finding the graphical desktop session. zguest runs as root from systemd and
// has no DISPLAY of its own; screenshot, input and exec{desktop:true} have to
// run inside the logged-in user's session with that session's DISPLAY /
// WAYLAND_DISPLAY / XAUTHORITY / XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS.
//
// Order of discovery:
//  1. the agent's own environment, when it was started by hand inside a desktop;
//  2. logind (`loginctl`): the first graphical (x11/wayland) session, user
//     sessions before greeters, active before online;
//  3. a scan of /proc/*/environ for any process with DISPLAY/WAYLAND_DISPLAY
//     (covers systems without logind and Xvfb displays).
// For the chosen user the environment of the best process (the compositor or
// desktop shell when it can be recognised) is copied, and missing pieces are
// derived from /run/user/<uid> and /tmp/.X11-unix.

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// procCred is an identity to run a helper as.
type procCred struct {
	uid, gid uint32
	groups   []uint32
}

// desktopSession is the graphical login session that screenshot, input and
// exec{desktop:true} run in.
type desktopSession struct {
	ID     string // logind session id ("" when not found through logind)
	Type   string // "wayland" | "x11"
	Class  string // logind class: "user" | "greeter" | ""
	User   string
	UID    int
	GID    int
	Groups []uint32
	Home   string
	Env    map[string]string // display-related variables, see sessionEnvKeys
	Source string            // "self" | "loginctl" | "proc"
}

// sessionEnvKeys are copied from the session's processes.
var sessionEnvKeys = []string{
	"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
	"XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION",
	"SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE", "YDOTOOL_SOCKET", "LANG",
}

// sessionLeaders are process names (as in /proc/<pid>/comm, max 15 chars)
// whose environment is the authoritative one for a desktop session.
var sessionLeaders = []string{
	"gnome-shell", "gnome-session-b", "kwin_wayland", "kwin_x11", "plasmashell", "ksmserver",
	"sway", "Hyprland", "weston", "labwc", "wayfire", "river", "niri", "cage", "mutter",
	"xfce4-session", "xfwm4", "mate-session", "cinnamon", "lxsession", "lxqt-session",
	"openbox", "i3", "budgie-wm", "enlightenment", "icewm", "fluxbox",
}

func (d *desktopSession) wayland() bool { return d.Env["WAYLAND_DISPLAY"] != "" }
func (d *desktopSession) x11() bool     { return d.Env["DISPLAY"] != "" }

func isRoot() bool { return os.Geteuid() == 0 }

// cred returns the identity to switch to, or nil when no switch is needed
// (the agent is not root, or already is the session user).
func (d *desktopSession) cred() *procCred {
	if !isRoot() || d.UID == os.Geteuid() || d.UID < 0 {
		return nil
	}
	return &procCred{uid: uint32(d.UID), gid: uint32(d.GID), groups: d.Groups}
}

// environ builds the environment for a helper running in the session.
func (d *desktopSession) environ(extra map[string]string) []string {
	path := os.Getenv("PATH")
	if path == "" {
		path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	lang := os.Getenv("LANG")
	if lang == "" {
		lang = "C.UTF-8"
	}
	m := map[string]string{"PATH": path, "LANG": lang}
	if d.Home != "" {
		m["HOME"] = d.Home
	}
	if d.User != "" {
		m["USER"], m["LOGNAME"] = d.User, d.User
	}
	for k, v := range d.Env {
		if v != "" {
			m[k] = v
		}
	}
	for k, v := range extra {
		m[k] = v
	}
	return envList(m)
}

// workDir is the session user's home, or / when it does not exist.
func (d *desktopSession) workDir() string {
	if d.Home != "" && isDir(d.Home) {
		return d.Home
	}
	return "/"
}

func envList(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

// mergeEnv overlays extra onto a KEY=VALUE list.
func mergeEnv(base []string, extra map[string]string) []string {
	if len(extra) == 0 {
		return base
	}
	m := make(map[string]string, len(base)+len(extra))
	for _, kv := range base {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	for k, v := range extra {
		m[k] = v
	}
	return envList(m)
}

// sessionCache memoises detection for a few seconds: screenshots are taken
// after every agent step and detection runs loginctl and scans /proc.
type sessionCache struct {
	mu   sync.Mutex
	at   time.Time
	sess *desktopSession
	err  error
}

const sessionCacheTTL = 5 * time.Second

// desktop returns the current graphical session (cached briefly).
func (s *Server) desktop() (*desktopSession, error) {
	c := &s.desk
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < sessionCacheTTL {
		return c.sess, c.err
	}
	c.sess, c.err = findDesktopSession()
	c.at = time.Now()
	return c.sess, c.err
}

func findDesktopSession() (*desktopSession, error) {
	// 1. Started by hand inside a desktop.
	if os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != "" {
		d := &desktopSession{UID: os.Geteuid(), GID: os.Getegid(), Env: map[string]string{}, Source: "self"}
		for _, k := range sessionEnvKeys {
			if v := os.Getenv(k); v != "" {
				d.Env[k] = v
			}
		}
		d.fillDefaults()
		return d, nil
	}
	// 2. logind.
	for _, ls := range loginctlSessions() {
		env, _ := scanProcEnv(ls.uid)
		if env == nil {
			env = map[string]string{}
		}
		if ls.display != "" && env["DISPLAY"] == "" {
			env["DISPLAY"] = ls.display
		}
		d := &desktopSession{ID: ls.id, Type: ls.typ, Class: ls.class, User: ls.user, UID: ls.uid, Env: env, Source: "loginctl"}
		d.fillDefaults()
		if d.wayland() || d.x11() {
			return d, nil
		}
	}
	// 3. Any process with a display.
	if env, uid := scanProcEnv(-1); env != nil {
		d := &desktopSession{UID: uid, Env: env, Source: "proc"}
		d.fillDefaults()
		return d, nil
	}
	return nil, errf(codeUnavailable, "no graphical desktop session found: no logind x11/wayland session and no process "+
		"with DISPLAY or WAYLAND_DISPLAY. Log in to the desktop (or enable auto-login), or start a display such as Xvfb")
}

// selfSession is used when the caller names an X display explicitly but no
// session was detected (e.g. an Xvfb display owned by the agent's user).
func selfSession() *desktopSession {
	d := &desktopSession{UID: os.Geteuid(), GID: os.Getegid(), Env: map[string]string{}, Source: "self"}
	d.fillDefaults()
	return d
}

// fillDefaults completes user details and derives missing variables.
func (d *desktopSession) fillDefaults() {
	if d.Env == nil {
		d.Env = map[string]string{}
	}
	if u, err := user.LookupId(strconv.Itoa(d.UID)); err == nil {
		if d.User == "" {
			d.User = u.Username
		}
		d.Home = u.HomeDir
		if gid, err := strconv.Atoi(u.Gid); err == nil {
			d.GID = gid
		}
		if ids, err := u.GroupIds(); err == nil {
			for _, s := range ids {
				if g, err := strconv.ParseUint(s, 10, 32); err == nil {
					d.Groups = append(d.Groups, uint32(g))
				}
			}
		}
	}
	rt := d.Env["XDG_RUNTIME_DIR"]
	if rt == "" {
		if cand := fmt.Sprintf("/run/user/%d", d.UID); isDir(cand) {
			d.Env["XDG_RUNTIME_DIR"], rt = cand, cand
		}
	}
	if d.Env["WAYLAND_DISPLAY"] == "" && rt != "" && (d.Type == "wayland" || d.Source == "loginctl" && d.Type == "") {
		if m, _ := filepath.Glob(filepath.Join(rt, "wayland-*")); len(m) > 0 {
			sort.Strings(m)
			for _, p := range m {
				if !strings.HasSuffix(p, ".lock") {
					d.Env["WAYLAND_DISPLAY"] = filepath.Base(p)
					break
				}
			}
		}
	}
	if d.Env["DISPLAY"] == "" && d.Type == "x11" {
		if m, _ := filepath.Glob("/tmp/.X11-unix/X*"); len(m) > 0 {
			sort.Strings(m)
			d.Env["DISPLAY"] = ":" + strings.TrimPrefix(filepath.Base(m[0]), "X")
		}
	}
	if d.Env["DISPLAY"] != "" && d.Env["XAUTHORITY"] == "" {
		cands := []string{}
		if d.Home != "" {
			cands = append(cands, filepath.Join(d.Home, ".Xauthority"))
		}
		if rt != "" {
			cands = append(cands, filepath.Join(rt, "gdm", "Xauthority"))
		}
		cands = append(cands, xServerAuthFiles(d.Env["DISPLAY"])...)
		for _, c := range cands {
			if isFile(c) {
				d.Env["XAUTHORITY"] = c
				break
			}
		}
	}
	if d.Env["DBUS_SESSION_BUS_ADDRESS"] == "" && rt != "" {
		if _, err := os.Stat(filepath.Join(rt, "bus")); err == nil {
			d.Env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + filepath.Join(rt, "bus")
		}
	}
	if d.Type == "" {
		switch {
		case d.wayland():
			d.Type = "wayland"
		case d.x11():
			d.Type = "x11"
		}
	}
}

type logindSession struct {
	id, user, typ, class, state, display string
	uid                                  int
	active, remote                       bool
}

// loginctlSessions lists graphical logind sessions, best first.
func loginctlSessions() []logindSession {
	if _, err := exec.LookPath("loginctl"); err != nil {
		return nil
	}
	out, err := runQuick(5*time.Second, "loginctl", "list-sessions", "--no-legend")
	if err != nil {
		return nil
	}
	var res []logindSession
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		props, err := runQuick(5*time.Second, "loginctl", "show-session", f[0],
			"-p", "Id", "-p", "Name", "-p", "User", "-p", "Type", "-p", "Class",
			"-p", "State", "-p", "Active", "-p", "Remote", "-p", "Display")
		if err != nil {
			continue
		}
		ls, ok := parseLoginctlSession(string(props))
		if ok {
			res = append(res, ls)
		}
	}
	sortLogindSessions(res)
	return res
}

// parseLoginctlSession parses `loginctl show-session` KEY=VALUE output and
// reports whether it is a graphical session.
func parseLoginctlSession(props string) (logindSession, bool) {
	var ls logindSession
	ls.uid = -1
	for _, line := range strings.Split(props, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch k {
		case "Id":
			ls.id = v
		case "Name":
			ls.user = v
		case "User":
			if n, err := strconv.Atoi(v); err == nil {
				ls.uid = n
			}
		case "Type":
			ls.typ = v
		case "Class":
			ls.class = v
		case "State":
			ls.state = v
		case "Active":
			ls.active = v == "yes"
		case "Remote":
			ls.remote = v == "yes"
		case "Display":
			ls.display = v
		}
	}
	graphical := ls.typ == "x11" || ls.typ == "wayland" || ls.typ == "mir"
	return ls, graphical && ls.uid >= 0
}

func sortLogindSessions(s []logindSession) {
	rank := func(ls logindSession) int {
		r := 0
		switch ls.class {
		case "user":
		case "greeter":
			r += 100
		default:
			r += 200
		}
		if ls.remote {
			r += 50
		}
		if !ls.active {
			r += 10
		}
		switch ls.state {
		case "active":
		case "online":
			r += 1
		default:
			r += 5
		}
		return r
	}
	sort.SliceStable(s, func(i, j int) bool { return rank(s[i]) < rank(s[j]) })
}

// scanProcEnv returns the display environment of the best process owned by
// uid (any uid when uid < 0) that has DISPLAY or WAYLAND_DISPLAY set, and the
// owner's uid. nil when none is found or /proc is unavailable.
func scanProcEnv(uid int) (map[string]string, int) {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil, -1
	}
	self := os.Getpid()
	var (
		best      map[string]string
		bestUID   = -1
		bestScore = 0
	)
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == self {
			continue
		}
		dir := filepath.Join("/proc", e.Name())
		raw, err := os.ReadFile(filepath.Join(dir, "environ"))
		if err != nil || len(raw) == 0 {
			continue
		}
		env := parseEnviron(raw)
		if env["DISPLAY"] == "" && env["WAYLAND_DISPLAY"] == "" {
			continue
		}
		owner := procUID(dir)
		if owner < 0 || (uid >= 0 && owner != uid) {
			continue
		}
		score := 0
		if env["WAYLAND_DISPLAY"] != "" {
			score += 2
		}
		if env["DISPLAY"] != "" {
			score += 2
		}
		for _, k := range []string{"XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"} {
			if env[k] != "" {
				score++
			}
		}
		if comm, err := os.ReadFile(filepath.Join(dir, "comm")); err == nil && isSessionLeader(strings.TrimSpace(string(comm))) {
			score += 10
		}
		if score > bestScore {
			best, bestUID, bestScore = env, owner, score
		}
	}
	if best == nil {
		return nil, -1
	}
	out := map[string]string{}
	for _, k := range sessionEnvKeys {
		if v := best[k]; v != "" {
			out[k] = v
		}
	}
	return out, bestUID
}

func isSessionLeader(comm string) bool {
	for _, n := range sessionLeaders {
		if comm == n {
			return true
		}
	}
	return false
}

// parseEnviron splits a NUL-separated /proc/<pid>/environ.
func parseEnviron(raw []byte) map[string]string {
	m := map[string]string{}
	for _, kv := range bytes.Split(raw, []byte{0}) {
		if k, v, ok := strings.Cut(string(kv), "="); ok && k != "" {
			m[k] = v
		}
	}
	return m
}

// procUID returns the real uid of a /proc/<pid> entry, or -1.
func procUID(dir string) int {
	raw, err := os.ReadFile(filepath.Join(dir, "status"))
	if err != nil {
		return -1
	}
	return parseStatusUID(string(raw))
}

func parseStatusUID(status string) int {
	for _, line := range strings.Split(status, "\n") {
		if rest, ok := strings.CutPrefix(line, "Uid:"); ok {
			f := strings.Fields(rest)
			if len(f) > 0 {
				if n, err := strconv.Atoi(f[0]); err == nil {
					return n
				}
			}
		}
	}
	return -1
}

// xServerAuthFiles returns the -auth files of running X servers, those
// serving the given display first.
func xServerAuthFiles(display string) []string {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var match, other []string
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		raw, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		if err != nil || len(raw) == 0 {
			continue
		}
		args := strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
		base := filepath.Base(args[0])
		if base != "Xorg" && base != "X" && base != "Xwayland" && base != "Xvfb" {
			continue
		}
		auth, served := "", false
		for i, a := range args {
			if a == "-auth" && i+1 < len(args) {
				auth = args[i+1]
			}
			if a == display {
				served = true
			}
		}
		if auth == "" {
			continue
		}
		if served {
			match = append(match, auth)
		} else {
			other = append(other, auth)
		}
	}
	return append(match, other...)
}

// runQuick runs a short helper command as the agent and returns stdout.
func runQuick(timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second
	return cmd.Output()
}

// runTool runs argv inside the desktop session and returns its stdout.
// asUser switches to the session user when the agent is root; false keeps
// the agent's identity (ydotool needs root for /dev/uinput or its socket)
// but still uses the session environment.
func (s *Server) runTool(ctx context.Context, sess *desktopSession, asUser bool, extraEnv map[string]string,
	timeout time.Duration, stdin io.Reader, argv ...string) ([]byte, error) {
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(tctx, argv[0], argv[1:]...)
	cmd.Env = sess.environ(extraEnv)
	cmd.Dir = sess.workDir()
	cmd.Stdin = stdin
	stdout := &capBuffer{max: 1 << 20}
	stderr := &capBuffer{max: 16 << 10}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	var cred *procCred
	if asUser {
		cred = sess.cred()
	}
	configureCmd(cmd, cred)
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	if err != nil && cmd.ProcessState != nil && cmd.ProcessState.Success() {
		err = nil // exited 0; a helper it spawned kept the output pipe open (ErrWaitDelay)
	}
	if err != nil {
		name := filepath.Base(argv[0])
		if tctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("%s timed out after %v", name, timeout)
		}
		if msg := oneLine(stderr.String(), 400); msg != "" {
			return nil, fmt.Errorf("%s: %v: %s", name, err, msg)
		}
		return nil, fmt.Errorf("%s: %v", name, err)
	}
	return stdout.Bytes(), nil
}

// oneLine collapses whitespace and truncates s to max bytes.
func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > max {
		s = s[:max] + "..."
	}
	return s
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

func haveTool(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
