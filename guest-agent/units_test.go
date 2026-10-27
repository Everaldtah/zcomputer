package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"reflect"
	"strings"
	"testing"
)

func TestReadLine(t *testing.T) {
	// A 16-byte buffer forces the ErrBufferFull path.
	in := "short\n" + strings.Repeat("a", 40) + "\n" + strings.Repeat("b", 41) + "\nlast"
	r := bufio.NewReaderSize(strings.NewReader(in), 16)
	type res struct {
		line    string
		tooLong bool
		err     error
	}
	var got []res
	for {
		line, tooLong, err := readLine(r, 40)
		got = append(got, res{strings.TrimRight(string(line), "\n"), tooLong, err})
		if err != nil {
			break
		}
	}
	want := []res{
		{"short", false, nil},
		{strings.Repeat("a", 40), false, nil},
		{"", true, nil},
		{"last", false, io.EOF},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestEncodeSuccessFlattensResult(t *testing.T) {
	got := string(encodeSuccess("a\"b", struct {
		X int    `json:"x"`
		S string `json:"s"`
	}{1, "<&>"}))
	if want := `{"id":"a\"b","ok":true,"x":1,"s":"<&>"}`; got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	if got := string(encodeSuccess("e", struct{}{})); got != `{"id":"e","ok":true}` {
		t.Fatalf("empty result: %s", got)
	}
	if got := string(encodeSuccess("n", nil)); got != `{"id":"n","ok":true}` {
		t.Fatalf("nil result: %s", got)
	}
	// Non-object results are an internal error, not invalid JSON.
	var m map[string]any
	if err := json.Unmarshal(encodeSuccess("bad", []int{1}), &m); err != nil || m["ok"] != false || m["code"] != codeInternal {
		t.Fatalf("non-object result: %v %v", m, err)
	}
}

func TestEncodeErrorCodes(t *testing.T) {
	cases := []struct {
		err  error
		code string
	}{
		{errf(codeBadRequest, "x"), codeBadRequest},
		{&fs.PathError{Op: "open", Path: "/x", Err: fs.ErrNotExist}, codeNotFound},
		{&fs.PathError{Op: "open", Path: "/x", Err: fs.ErrPermission}, codePermission},
		{errors.New("boom"), codeFailed},
	}
	for _, c := range cases {
		var m map[string]any
		if err := json.Unmarshal(encodeError("i", c.err), &m); err != nil {
			t.Fatal(err)
		}
		if m["id"] != "i" || m["ok"] != false || m["code"] != c.code || m["error"] == "" {
			t.Errorf("%v: got %v", c.err, m)
		}
	}
}

func TestCapBuffer(t *testing.T) {
	c := &capBuffer{max: 10}
	for _, s := range []string{"12345", "67890", "x"} {
		if n, err := c.Write([]byte(s)); n != len(s) || err != nil {
			t.Fatalf("Write returned %d, %v", n, err)
		}
	}
	if c.String() != "1234567890" || !c.truncated {
		t.Fatalf("%q truncated=%v", c.String(), c.truncated)
	}
	c = &capBuffer{max: 4}
	c.Write([]byte("abcdef"))
	if c.String() != "abcd" || !c.truncated {
		t.Fatalf("%q truncated=%v", c.String(), c.truncated)
	}
	c = &capBuffer{max: 4}
	c.Write([]byte("abcd"))
	if c.truncated {
		t.Fatal("exactly full is not truncated")
	}
}

func TestParseMode(t *testing.T) {
	cases := []struct {
		in   string
		want fs.FileMode
		ok   bool
		err  bool
	}{
		{``, 0, false, false},
		{`null`, 0, false, false},
		{`"0644"`, 0o644, true, false},
		{`"644"`, 0o644, true, false},
		{`"0o755"`, 0o755, true, false},
		{`420`, 0o644, true, false},
		{`"4755"`, 0o755 | fs.ModeSetuid, true, false},
		{`"1777"`, 0o777 | fs.ModeSticky, true, false},
		{`"rwx"`, 0, false, true},
		{`"99999"`, 0, false, true},
		{`5000`, 0, false, true},
		{`-1`, 0, false, true},
	}
	for _, c := range cases {
		m, ok, err := parseMode(json.RawMessage(c.in))
		if (err != nil) != c.err || ok != c.ok || m != c.want {
			t.Errorf("parseMode(%s) = %v, %v, %v", c.in, m, ok, err)
		}
	}
}

func TestParseOSRelease(t *testing.T) {
	m := parseOSRelease(`# comment
NAME="Ubuntu"
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04.1 LTS"
ID=ubuntu
QUOTED='single quoted'
ESCAPED="say \"hi\""
`)
	if m["PRETTY_NAME"] != "Ubuntu 24.04.1 LTS" || m["ID"] != "ubuntu" || m["VERSION_ID"] != "24.04" ||
		m["QUOTED"] != "single quoted" || m["ESCAPED"] != `say "hi"` {
		t.Fatalf("%v", m)
	}
}

func TestParseMeminfo(t *testing.T) {
	total, free := parseMeminfo("MemTotal:       16337052 kB\nMemFree:          100000 kB\nMemAvailable:    8000000 kB\n")
	if total != 16337052*1024 || free != 8000000*1024 {
		t.Fatalf("%d %d", total, free)
	}
	_, free = parseMeminfo("MemTotal: 2048 kB\nMemFree: 1024 kB\n")
	if free != 1024*1024 {
		t.Fatalf("fallback to MemFree: %d", free)
	}
}

func TestParseEnvironAndStatus(t *testing.T) {
	env := parseEnviron([]byte("DISPLAY=:0\x00WAYLAND_DISPLAY=wayland-0\x00EMPTY=\x00junk\x00A=b=c\x00"))
	if env["DISPLAY"] != ":0" || env["WAYLAND_DISPLAY"] != "wayland-0" || env["A"] != "b=c" {
		t.Fatalf("%v", env)
	}
	if _, ok := env["EMPTY"]; !ok {
		t.Fatal("EMPTY should be present")
	}
	if uid := parseStatusUID("Name:\tbash\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\n"); uid != 1000 {
		t.Fatalf("uid %d", uid)
	}
	if uid := parseStatusUID("Name: x\n"); uid != -1 {
		t.Fatalf("uid %d", uid)
	}
}

func TestParseLoginctlSession(t *testing.T) {
	ls, ok := parseLoginctlSession("Id=2\nName=alice\nUser=1000\nType=wayland\nClass=user\nState=active\nActive=yes\nRemote=no\nDisplay=\n")
	if !ok || ls.id != "2" || ls.user != "alice" || ls.uid != 1000 || ls.typ != "wayland" || !ls.active {
		t.Fatalf("%+v %v", ls, ok)
	}
	if _, ok := parseLoginctlSession("Id=c1\nName=alice\nUser=1000\nType=tty\nClass=user\n"); ok {
		t.Fatal("tty session is not graphical")
	}
	sessions := []logindSession{
		{id: "greeter", class: "greeter", state: "active", active: true},
		{id: "bg", class: "user", state: "online"},
		{id: "fg", class: "user", state: "active", active: true},
	}
	sortLogindSessions(sessions)
	if sessions[0].id != "fg" || sessions[1].id != "bg" || sessions[2].id != "greeter" {
		t.Fatalf("order %v", sessions)
	}
}

func TestParseKeys(t *testing.T) {
	cases := map[string][][]string{
		"Return":         {{"Return"}},
		"enter":          {{"Return"}},
		"ctrl+c":         {{"ctrl", "c"}},
		"Ctrl+Shift+T":   {{"ctrl", "shift", "T"}},
		"cmd+space":      {{"super", "space"}},
		"alt+F4":         {{"alt", "F4"}},
		"ctrl+a Delete":  {{"ctrl", "a"}, {"Delete"}},
		"ctrl++":         {{"ctrl", "plus"}},
		"ctrl+/":         {{"ctrl", "slash"}},
		"pgdn":           {{"Page_Down"}},
		"XF86AudioMute":  {{"XF86AudioMute"}},
		"super":          {{"super"}},
		"esc":            {{"Escape"}},
		"shift+tab":      {{"shift", "Tab"}},
		"f12":            {{"F12"}},
		"BackSpace":      {{"BackSpace"}},
		"  Escape  Tab ": {{"Escape"}, {"Tab"}},
	}
	for in, want := range cases {
		got, err := parseKeys(in)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("parseKeys(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "   ", "ctrl+", "+a"} {
		if _, err := parseKeys(bad); err == nil {
			t.Errorf("parseKeys(%q) should fail", bad)
		}
	}
}

func ip(n int) *int { return &n }

func TestNormalizeActions(t *testing.T) {
	acts, err := normalizeActions([]inputAction{
		{Type: "click", X: ip(10), Y: ip(20)},
		{Type: "double_click", X: ip(1), Y: ip(2)},
		{Type: "right_click"},
		{Type: "click", Button: "middle", Count: 3},
		{Type: "drag", X: ip(5), Y: ip(5), ToX: ip(50), ToY: ip(60)},
		{Type: "drag", X: ip(5), Y: ip(5), DX: 10, DY: -2},
		{Type: "scroll", DY: 3},
		{Type: "type", Text: "hi"},
		{Type: "key", Key: "ctrl+c"},
		{Type: "mouse_down", Button: "right"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if a := acts[0]; a.kind != "click" || !a.hasPos || a.x != 10 || a.y != 20 || a.count != 1 || a.button != "left" {
		t.Errorf("click %+v", a)
	}
	if a := acts[1]; a.count != 2 || a.button != "left" {
		t.Errorf("double %+v", a)
	}
	if a := acts[2]; a.button != "right" || a.hasPos {
		t.Errorf("right %+v", a)
	}
	if a := acts[3]; a.button != "middle" || a.count != 3 {
		t.Errorf("middle %+v", a)
	}
	if a := acts[4]; a.x2 != 50 || a.y2 != 60 {
		t.Errorf("drag %+v", a)
	}
	if a := acts[5]; a.x2 != 15 || a.y2 != 3 {
		t.Errorf("drag dx %+v", a)
	}
	if a := acts[9]; a.kind != "down" || a.button != "right" {
		t.Errorf("down %+v", a)
	}

	for _, bad := range [][]inputAction{
		nil,
		{{Type: "mouse_move"}},
		{{Type: "mouse_move", X: ip(1)}},
		{{Type: "click", X: ip(-1), Y: ip(1)}},
		{{Type: "click", Button: "side"}},
		{{Type: "drag", X: ip(1), Y: ip(1)}},
		{{Type: "scroll"}},
		{{Type: "type"}},
		{{Type: "key"}},
		{{Type: "teleport"}},
		{{}},
	} {
		if _, err := normalizeActions(bad); err == nil {
			t.Errorf("normalizeActions(%+v) should fail", bad)
		} else if code, _ := classify(err); code != codeBadRequest {
			t.Errorf("code %s", code)
		}
	}
}

func mustAct(t *testing.T, a inputAction) act {
	t.Helper()
	acts, err := normalizeActions([]inputAction{a})
	if err != nil {
		t.Fatal(err)
	}
	return acts[0]
}

func TestXdotoolArgv(t *testing.T) {
	cases := []struct {
		a    inputAction
		want string
	}{
		{inputAction{Type: "mouse_move", X: ip(5), Y: ip(6)}, "xdotool mousemove 5 6"},
		{inputAction{Type: "click", X: ip(5), Y: ip(6)}, "xdotool mousemove 5 6 click 1"},
		{inputAction{Type: "click"}, "xdotool click 1"},
		{inputAction{Type: "double_click", X: ip(1), Y: ip(2)}, "xdotool mousemove 1 2 click --repeat 2 --delay 80 1"},
		{inputAction{Type: "right_click", X: ip(1), Y: ip(2)}, "xdotool mousemove 1 2 click 3"},
		{inputAction{Type: "mouse_down", Button: "middle"}, "xdotool mousedown 2"},
		{inputAction{Type: "mouse_up", X: ip(3), Y: ip(4)}, "xdotool mousemove 3 4 mouseup 1"},
		{inputAction{Type: "drag", X: ip(0), Y: ip(0), ToX: ip(100), ToY: ip(50)},
			"xdotool mousemove 0 0 mousedown 1 sleep 0.1 mousemove 50 25 sleep 0.05 mousemove 100 50 sleep 0.1 mouseup 1"},
		{inputAction{Type: "scroll", X: ip(9), Y: ip(9), DY: 3}, "xdotool mousemove 9 9 click --repeat 3 --delay 30 5"},
		{inputAction{Type: "scroll", DY: -2, DX: 1}, "xdotool click --repeat 2 --delay 30 4 click --repeat 1 --delay 30 7"},
		{inputAction{Type: "scroll", DX: -4}, "xdotool click --repeat 4 --delay 30 6"},
		{inputAction{Type: "type", Text: "-rf"}, "xdotool type --delay 12 -- -rf"},
		{inputAction{Type: "key", Key: "ctrl+shift+t Return"}, "xdotool key --delay 40 -- ctrl+shift+t Return"},
	}
	for _, c := range cases {
		if got := strings.Join(xdotoolArgv(mustAct(t, c.a)), " "); got != c.want {
			t.Errorf("%+v:\n got %s\nwant %s", c.a, got, c.want)
		}
	}
}

func TestYdotoolCalls(t *testing.T) {
	join := func(calls [][]string) string {
		var parts []string
		for _, c := range calls {
			parts = append(parts, strings.Join(c, " "))
		}
		return strings.Join(parts, " | ")
	}
	cases := []struct {
		a    inputAction
		want string
	}{
		{inputAction{Type: "mouse_move", X: ip(5), Y: ip(6)}, "ydotool mousemove --absolute -x 5 -y 6"},
		{inputAction{Type: "click", X: ip(5), Y: ip(6)}, "ydotool mousemove --absolute -x 5 -y 6 | ydotool click 0xC0"},
		{inputAction{Type: "double_click"}, "ydotool click 0xC0 0xC0"},
		{inputAction{Type: "right_click"}, "ydotool click 0xC1"},
		{inputAction{Type: "mouse_down", Button: "middle"}, "ydotool click 0x42"},
		{inputAction{Type: "mouse_up"}, "ydotool click 0x80"},
		{inputAction{Type: "drag", X: ip(0), Y: ip(0), ToX: ip(10), ToY: ip(20)},
			"ydotool mousemove --absolute -x 0 -y 0 | ydotool click 0x40 | ydotool mousemove --absolute -x 5 -y 10 | " +
				"ydotool mousemove --absolute -x 10 -y 20 | ydotool click 0x80"},
		{inputAction{Type: "scroll", DY: 3, DX: -1}, "ydotool mousemove --wheel -x -1 -y -3"},
	}
	for _, c := range cases {
		if got := join(ydotoolMouseCalls(mustAct(t, c.a))); got != c.want {
			t.Errorf("%+v:\n got %s\nwant %s", c.a, got, c.want)
		}
	}
	seq, err := ydotoolKeySeq([][]string{{"ctrl", "c"}, {"Return"}, {"A"}, {"F11"}, {"exclam"}})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Join(seq, " "), "29:1 46:1 46:0 29:0 28:1 28:0 42:1 30:1 30:0 42:0 87:1 87:0 42:1 2:1 2:0 42:0"; got != want {
		t.Errorf("key seq\n got %s\nwant %s", got, want)
	}
	if _, err := ydotoolKeySeq([][]string{{"XF86AudioMute"}}); err == nil {
		t.Error("unknown keysym should fail for ydotool")
	}
	if got := strings.Join(ydotoolTypeArgv("-x"), " "); got != "ydotool type -- -x" {
		t.Errorf("type argv %s", got)
	}
}

func TestWtypeArgv(t *testing.T) {
	combos, _ := parseKeys("ctrl+shift+t super Return")
	got := strings.Join(wtypeKeyArgv(combos), " ")
	if want := "wtype -M ctrl -M shift -k t -m shift -m ctrl -k Super_L -k Return"; got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
	if got := strings.Join(wtypeTextArgv("hello"), " "); got != "wtype hello" {
		t.Errorf("text %s", got)
	}
	if got := strings.Join(wtypeTextArgv("-n"), " "); got != "wtype -- -n" {
		t.Errorf("text %s", got)
	}
}

func TestChooseInputPlan(t *testing.T) {
	x11 := &desktopSession{Env: map[string]string{"DISPLAY": ":0"}}
	wl := &desktopSession{Env: map[string]string{"WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"}}
	none := &desktopSession{Env: map[string]string{}}
	have := func(names ...string) func(string) bool {
		return func(n string) bool {
			for _, x := range names {
				if x == n {
					return true
				}
			}
			return false
		}
	}
	if pl, _, err := chooseInputPlan(x11, "", have("xdotool")); err != nil || !pl.x11 {
		t.Errorf("x11: %+v %v", pl, err)
	}
	if _, _, err := chooseInputPlan(x11, "", have()); err == nil || !strings.Contains(err.Error(), "xdotool") {
		t.Errorf("x11 without xdotool: %v", err)
	}
	if pl, _, err := chooseInputPlan(wl, "", have("ydotool", "wtype", "xdotool")); err != nil || pl.x11 || !pl.ydotool || !pl.wtype {
		t.Errorf("wayland: %+v %v", pl, err)
	}
	if pl, warn, err := chooseInputPlan(wl, "", have("xdotool")); err != nil || !pl.x11 || warn == "" {
		t.Errorf("wayland via xwayland: %+v %q %v", pl, warn, err)
	}
	if _, _, err := chooseInputPlan(wl, "", have()); err == nil {
		t.Error("wayland without tools should fail")
	}
	if pl, _, err := chooseInputPlan(wl, "xdotool", have("xdotool", "ydotool")); err != nil || !pl.x11 {
		t.Errorf("forced xdotool: %+v %v", pl, err)
	}
	if _, _, err := chooseInputPlan(none, "", have("xdotool")); err == nil {
		t.Error("no display should fail")
	}
	if _, _, err := chooseInputPlan(x11, "bogus", have("xdotool")); err == nil {
		t.Error("unknown backend should fail")
	}

	// wtype only: keys work, mouse needs ydotool.
	pl := inputPlan{wtype: true}
	if calls, err := pl.calls(mustAct(t, inputAction{Type: "key", Key: "ctrl+l"})); err != nil || calls[0].tool != "wtype" || !calls[0].asUser {
		t.Errorf("wtype key: %+v %v", calls, err)
	}
	if _, err := pl.calls(mustAct(t, inputAction{Type: "click"})); err == nil {
		t.Error("mouse without ydotool should fail")
	}
	// ydotool only: runs as the agent (root), keys via evdev codes.
	pl = inputPlan{ydotool: true}
	calls, err := pl.calls(mustAct(t, inputAction{Type: "key", Key: "ctrl+l"}))
	if err != nil || calls[0].tool != "ydotool" || calls[0].asUser || strings.Join(calls[0].argv, " ") != "ydotool key 29:1 38:1 38:0 29:0" {
		t.Errorf("ydotool key: %+v %v", calls, err)
	}
}

func TestScreenshotToolOrder(t *testing.T) {
	var names []string
	for _, tool := range screenshotTools("") {
		names = append(names, tool.name)
	}
	if got := strings.Join(names, ","); got != "grim,spectacle,gnome-screenshot,scrot,import,xwd,xwd" {
		t.Fatalf("order %s", got)
	}
	if got := strings.Join(screenshotTools("HDMI-A-1")[0].argv("/tmp/o.png"), " "); got != "grim -o HDMI-A-1 /tmp/o.png" {
		t.Fatalf("grim argv %s", got)
	}
}

func TestSessionEnviron(t *testing.T) {
	d := &desktopSession{User: "alice", Home: "/home/alice", Env: map[string]string{"DISPLAY": ":1", "WAYLAND_DISPLAY": ""}}
	env := d.environ(map[string]string{"EXTRA": "1", "DISPLAY": ":2"})
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	if m["DISPLAY"] != ":2" || m["HOME"] != "/home/alice" || m["USER"] != "alice" || m["EXTRA"] != "1" || m["PATH"] == "" {
		t.Fatalf("%v", m)
	}
	if _, ok := m["WAYLAND_DISPLAY"]; ok {
		t.Fatal("empty session values are dropped")
	}
	merged := mergeEnv([]string{"A=1", "B=2"}, map[string]string{"B": "3", "C": "4"})
	if strings.Join(merged, ",") != "A=1,B=3,C=4" {
		t.Fatalf("mergeEnv %v", merged)
	}
}
