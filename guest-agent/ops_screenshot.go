package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const screenshotToolTimeout = 30 * time.Second

type screenshotParams struct {
	Display string `json:"display"`
}

type screenshotResult struct {
	PNGB64  string `json:"png_b64"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	Tool    string `json:"tool"`
	Session string `json:"session"`
	Warning string `json:"warning,omitempty"`
}

// shotTool is one way of taking a screenshot into a PNG file.
type shotTool struct {
	name    string   // reported in the "tool" field
	bins    []string // executables that must be installed
	wayland bool     // needs a Wayland session
	x11     bool     // needs an X display
	argv    func(out string) []string
}

// screenshotTools lists the capture tools in the order they are tried.
// output is a Wayland output name for grim ("" = all outputs).
func screenshotTools(output string) []shotTool {
	return []shotTool{
		{name: "grim", bins: []string{"grim"}, wayland: true, argv: func(out string) []string {
			if output != "" {
				return []string{"grim", "-o", output, out}
			}
			return []string{"grim", out}
		}},
		{name: "spectacle", bins: []string{"spectacle"}, argv: func(out string) []string {
			return []string{"spectacle", "-b", "-n", "-f", "-o", out}
		}},
		{name: "gnome-screenshot", bins: []string{"gnome-screenshot"}, argv: func(out string) []string {
			return []string{"gnome-screenshot", "-f", out}
		}},
		{name: "scrot", bins: []string{"scrot"}, x11: true, argv: func(out string) []string {
			return []string{"scrot", out}
		}},
		{name: "import", bins: []string{"import"}, x11: true, argv: func(out string) []string {
			return []string{"import", "-window", "root", out}
		}},
		{name: "xwd", bins: []string{"xwd", "convert"}, x11: true, argv: func(out string) []string {
			return []string{"sh", "-c", `xwd -root -silent | convert xwd:- "png:$1"`, "sh", out}
		}},
		{name: "xwd", bins: []string{"xwd", "magick"}, x11: true, argv: func(out string) []string {
			return []string{"sh", "-c", `xwd -root -silent | magick xwd:- "png:$1"`, "sh", out}
		}},
	}
}

const screenshotInstallHint = "install a screenshot tool in the guest: `sudo apt install grim` (Wayland: sway/wlroots), " +
	"`sudo apt install gnome-screenshot` (GNOME), `sudo apt install kde-spectacle` (KDE) or " +
	"`sudo apt install scrot` (X11); use your distribution's package manager elsewhere"

func opScreenshot(ctx context.Context, s *Server, raw []byte) (any, error) {
	var p screenshotParams
	if err := decodeParams(raw, &p); err != nil {
		return nil, err
	}
	// display ":N" selects an X display (X11 tools only); any other value is a
	// Wayland output name passed to grim -o.
	xOnly := strings.HasPrefix(p.Display, ":")
	output := ""
	if !xOnly {
		output = p.Display
	}

	sess, err := s.desktop()
	if err != nil {
		if !xOnly {
			return nil, err
		}
		sess = selfSession()
	}
	extraEnv := map[string]string{}
	if xOnly {
		extraEnv["DISPLAY"] = p.Display
		extraEnv["WAYLAND_DISPLAY"] = ""
	}
	haveWayland := sess.wayland() && !xOnly
	haveX := sess.x11() || xOnly

	dir, err := os.MkdirTemp("", "zguest-shot-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	if cred := sess.cred(); cred != nil {
		// The tool runs as the session user and writes into this 0700 dir.
		if err := os.Chown(dir, int(cred.uid), int(cred.gid)); err != nil {
			return nil, err
		}
	}
	out := filepath.Join(dir, "screen.png")

	var failures, missing []string
	for _, t := range screenshotTools(output) {
		switch {
		case t.wayland && !haveWayland:
			continue
		case t.x11 && !haveX:
			continue
		case !t.wayland && !t.x11 && (xOnly || !(haveWayland || haveX)):
			continue
		}
		if m := firstMissing(t.bins); m != "" {
			missing = append(missing, m)
			continue
		}
		os.Remove(out)
		if _, err := s.runTool(ctx, sess, true, extraEnv, screenshotToolTimeout, nil, t.argv(out)...); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", t.name, err))
			continue
		}
		data, err := os.ReadFile(out)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: exited 0 but wrote no image", t.name))
			continue
		}
		cfg, err := png.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: output is not a PNG: %v", t.name, err))
			continue
		}
		res := screenshotResult{
			PNGB64:  base64.StdEncoding.EncodeToString(data),
			Width:   cfg.Width,
			Height:  cfg.Height,
			Tool:    t.name,
			Session: sess.Type,
		}
		if xOnly {
			res.Session = "x11"
		}
		if haveWayland && t.x11 {
			res.Warning = "captured through XWayland: native Wayland windows may be missing or black; " +
				"install grim (wlroots), gnome-screenshot (GNOME) or spectacle (KDE)"
		}
		return res, nil
	}

	var b strings.Builder
	fmt.Fprintf(&b, "no screenshot tool worked (session %s, user %s)", orDash(sess.Type), orDash(sess.User))
	if len(failures) > 0 {
		fmt.Fprintf(&b, "; failed: %s", strings.Join(failures, "; "))
	}
	if len(missing) > 0 {
		fmt.Fprintf(&b, "; not installed: %s", strings.Join(dedupe(missing), ", "))
	}
	b.WriteString(". " + screenshotInstallHint)
	return nil, errf(codeUnavailable, "%s", b.String())
}

// firstMissing returns the first executable in bins that is not installed.
func firstMissing(bins []string) string {
	for _, b := range bins {
		if !haveTool(b) {
			return b
		}
	}
	return ""
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
