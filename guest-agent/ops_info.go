package main

import (
	"context"
	"math"
	"os"
	"os/user"
	"runtime"
	"strconv"
	"strings"
)

type pingResult struct {
	Version  string   `json:"version"`
	Protocol int      `json:"protocol"`
	Uptime   float64  `json:"uptime"` // seconds since the agent started
	Ops      []string `json:"ops"`
}

func opPing(ctx context.Context, s *Server, raw []byte) (any, error) {
	return pingResult{
		Version:  version,
		Protocol: protocolVersion,
		Uptime:   round3(s.uptime().Seconds()),
		Ops:      opNames(),
	}, nil
}

type displayInfo struct {
	Wayland bool              `json:"wayland"`
	X11     bool              `json:"x11"`
	Type    string            `json:"type"`
	User    string            `json:"user"`
	UID     int               `json:"uid"`
	Session string            `json:"session"`
	Desktop string            `json:"desktop"`
	Source  string            `json:"source"`
	Env     map[string]string `json:"env"`
	Error   string            `json:"error,omitempty"`
}

type sysinfoResult struct {
	Version   string          `json:"version"`
	Hostname  string          `json:"hostname"`
	OS        string          `json:"os"`
	OSID      string          `json:"osId"`
	OSVersion string          `json:"osVersion"`
	Kernel    string          `json:"kernel"`
	Arch      string          `json:"arch"`
	CPUs      int             `json:"cpus"`
	MemTotal  uint64          `json:"memTotal"`
	MemFree   uint64          `json:"memFree"`
	Uptime    float64         `json:"uptime"`
	AgentUser string          `json:"agentUser"`
	Display   displayInfo     `json:"display"`
	Tools     map[string]bool `json:"tools"`
}

// probedTools are reported in sysinfo.tools.
var probedTools = []string{
	"grim", "spectacle", "gnome-screenshot", "scrot", "import", "xwd", "convert", "magick",
	"xdotool", "ydotool", "wtype", "loginctl", "systemctl", "bash",
}

func opSysinfo(ctx context.Context, s *Server, raw []byte) (any, error) {
	r := sysinfoResult{
		Version: version,
		Arch:    unameArch(runtime.GOARCH),
		CPUs:    runtime.NumCPU(),
		Tools:   map[string]bool{},
	}
	r.Hostname, _ = os.Hostname()

	osr := map[string]string{}
	for _, p := range []string{"/etc/os-release", "/usr/lib/os-release"} {
		if b, err := os.ReadFile(p); err == nil {
			osr = parseOSRelease(string(b))
			break
		}
	}
	r.OS = osr["PRETTY_NAME"]
	if r.OS == "" {
		r.OS = strings.TrimSpace(osr["NAME"] + " " + osr["VERSION"])
	}
	if r.OS == "" {
		r.OS = runtime.GOOS
	}
	r.OSID, r.OSVersion = osr["ID"], osr["VERSION_ID"]

	if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		r.Kernel = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		r.MemTotal, r.MemFree = parseMeminfo(string(b))
	}
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		if f := strings.Fields(string(b)); len(f) > 0 {
			if v, err := strconv.ParseFloat(f[0], 64); err == nil {
				r.Uptime = v
			}
		}
	}
	if u, err := user.Current(); err == nil {
		r.AgentUser = u.Username
	} else {
		r.AgentUser = strconv.Itoa(os.Geteuid())
	}

	r.Display = displayInfo{UID: -1, Env: map[string]string{}}
	if sess, err := s.desktop(); err != nil {
		_, r.Display.Error = classify(err)
	} else {
		r.Display = displayInfo{
			Wayland: sess.wayland(),
			X11:     sess.x11(),
			Type:    sess.Type,
			User:    sess.User,
			UID:     sess.UID,
			Session: sess.ID,
			Desktop: sess.Env["XDG_CURRENT_DESKTOP"],
			Source:  sess.Source,
			Env:     map[string]string{},
		}
		for k, v := range sess.Env {
			if k != "LANG" {
				r.Display.Env[k] = v
			}
		}
	}

	for _, t := range probedTools {
		r.Tools[t] = haveTool(t)
	}
	return r, nil
}

// parseOSRelease parses os-release(5) KEY=VALUE lines.
func parseOSRelease(data string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			q := v[0]
			v = v[1 : len(v)-1]
			if q == '"' {
				v = strings.NewReplacer(`\"`, `"`, `\\`, `\`, `\$`, `$`, "\\`", "`").Replace(v)
			}
		}
		m[k] = v
	}
	return m
}

// parseMeminfo returns MemTotal and MemAvailable (MemFree on old kernels) in bytes.
func parseMeminfo(data string) (total, free uint64) {
	var memFree, avail uint64
	haveAvail := false
	for _, line := range strings.Split(data, "\n") {
		k, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		if len(f) == 0 {
			continue
		}
		n, err := strconv.ParseUint(f[0], 10, 64)
		if err != nil {
			continue
		}
		if len(f) > 1 && strings.EqualFold(f[1], "kB") {
			n *= 1024
		}
		switch k {
		case "MemTotal":
			total = n
		case "MemFree":
			memFree = n
		case "MemAvailable":
			avail, haveAvail = n, true
		}
	}
	if haveAvail {
		return total, avail
	}
	return total, memFree
}

// unameArch maps GOARCH to the `uname -m` spelling.
func unameArch(goarch string) string {
	switch goarch {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	case "386":
		return "i686"
	case "arm":
		return "armv7l"
	case "loong64":
		return "loongarch64"
	default:
		return goarch
	}
}

func round3(f float64) float64 { return math.Round(f*1000) / 1000 }
