package main

import (
	"context"
	"os/exec"
	"time"
)

type powerResult struct {
	Action  string `json:"action"`
	DelayMS int64  `json:"delay_ms"`
}

func opShutdown(ctx context.Context, s *Server, raw []byte) (any, error) {
	return s.schedulePower("poweroff")
}

func opReboot(ctx context.Context, s *Server, raw []byte) (any, error) {
	return s.schedulePower("reboot")
}

// schedulePower answers first and acts after powerDelay, so the response
// reaches the host before the connection drops.
func (s *Server) schedulePower(action string) (any, error) {
	if _, err := powerArgv(action); err != nil && s.powerCheck {
		return nil, err
	}
	delay := s.powerDelay
	s.Log.Printf("%s requested; executing in %v", action, delay)
	go func() {
		time.Sleep(delay)
		if err := s.power(action); err != nil {
			s.Log.Printf("%s failed: %v", action, err)
		}
	}()
	return powerResult{Action: action, DelayMS: delay.Milliseconds()}, nil
}

// powerArgv picks the command for "poweroff" or "reboot".
func powerArgv(action string) ([]string, error) {
	if haveTool("systemctl") {
		return []string{"systemctl", action}, nil
	}
	flag := map[string]string{"poweroff": "-h", "reboot": "-r"}[action]
	if haveTool("shutdown") {
		return []string{"shutdown", flag, "now"}, nil
	}
	if haveTool(action) {
		return []string{action}, nil
	}
	return nil, errf(codeUnavailable, "cannot %s: neither systemctl, shutdown nor %s is installed", action, action)
}

// systemPower runs the power command.
func systemPower(action string) error {
	argv, err := powerArgv(action)
	if err != nil {
		return err
	}
	out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
	if err != nil {
		return errf(codeFailed, "%v: %v: %s", argv, err, oneLine(string(out), 300))
	}
	return nil
}
