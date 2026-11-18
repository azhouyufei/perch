package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func rootDir() string {
	if runtime.GOOS == "windows" {
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "perch")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "perch")
}
func helperPath() string {
	name := "PerchAgent"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(rootDir(), "hooks", name)
}
func configPath(agent string) string {
	env, base, file := "CLAUDE_CONFIG_DIR", ".claude", "settings.json"
	if agent == "codex" {
		env, base, file = "CODEX_HOME", ".codex", "hooks.json"
	}
	dir := os.Getenv(env)
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, base)
	}
	return filepath.Join(dir, file)
}
func command(agent string) string {
	if runtime.GOOS == "windows" {
		if agent == "claude" {
			return `& "$env:LOCALAPPDATA/perch/hooks/PerchAgent.exe" event claude`
		}
		return `"%LOCALAPPDATA%\perch\hooks\PerchAgent.exe" event codex`
	}
	return "'" + strings.ReplaceAll(helperPath(), "'", "'\\''") + "' event " + agent
}

type eventSpec struct{ name, matcher string }

func specs(agent string) []eventSpec {
	all := []eventSpec{{"UserPromptSubmit", ""}, {"PermissionRequest", ""}, {"PostToolUse", ""}, {"Stop", ""}, {"SessionEnd", ""}}
	if agent == "claude" {
		return append(all, eventSpec{"PreToolUse", "AskUserQuestion"}, eventSpec{"Notification", "elicitation_dialog"}, eventSpec{"PostToolUseFailure", ""}, eventSpec{"StopFailure", ""})
	}
	return append(all, eventSpec{"PreToolUse", "request_user_input"}, eventSpec{"Interrupt", ""})
}
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".perch-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(data)
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

type object = map[string]any

func loadConfig(raw []byte) (object, error) {
	var doc object
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	if err := d.Decode(&doc); err != nil {
		return nil, err
	}
	if doc == nil {
		return nil, errors.New("expected JSON object")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, errors.New("unexpected trailing JSON")
	}
	return doc, nil
}
func configure(action, agent string) (bool, error) {
	path := configPath(agent)
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	if action != "status" {
		if action == "disable" {
			if _, e := os.Stat(path); os.IsNotExist(e) {
				return false, nil
			}
		}
		if err := os.MkdirAll(rootDir(), 0700); err != nil {
			return false, err
		}
		lock, err := configLock(filepath.Join(rootDir(), "agent-config.lock"))
		if err != nil {
			return false, fmt.Errorf("agent configuration is busy or inaccessible: %w", err)
		}
		defer lock.Close()
	}
	raw, err := os.ReadFile(path)
	exists := err == nil
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	doc := object{}
	mode := os.FileMode(0600)
	if exists {
		doc, err = loadConfig(raw)
		if err != nil {
			return false, fmt.Errorf("%s: %w", path, err)
		}
		info, e := os.Stat(path)
		if e != nil {
			return false, e
		}
		mode = info.Mode().Perm()
	}
	hooks, ok := doc["hooks"].(object)
	if !ok {
		if _, set := doc["hooks"]; set {
			return false, errors.New("expected an object at hooks")
		}
		hooks = object{}
	}
	found := 0
	changed := false
	for _, spec := range specs(agent) {
		groups, ok := hooks[spec.name].([]any)
		if !ok && hooks[spec.name] != nil {
			return false, fmt.Errorf("invalid %s hooks", spec.name)
		}
		remaining := []any{}
		has := false
		for _, group := range groups {
			g, _ := group.(object)
			list, _ := g["hooks"].([]any)
			keep := []any{}
			removed := false
			for _, entry := range list {
				h, _ := entry.(object)
				if h["type"] == "command" && h["command"] == command(agent) {
					has = true
					if action == "disable" {
						removed = true
						changed = true
						continue
					}
				}
				keep = append(keep, entry)
			}
			if removed {
				if len(keep) == 0 {
					continue
				}
				g["hooks"] = keep
			}
			remaining = append(remaining, group)
		}
		if has {
			found++
		}
		if action == "enable" && !has {
			h := object{"type": "command", "command": command(agent), "timeout": 3}
			if runtime.GOOS == "windows" && agent == "claude" {
				h["shell"] = "powershell"
			}
			group := object{"hooks": []any{h}}
			if spec.matcher != "" {
				group["matcher"] = spec.matcher
			}
			remaining = append(remaining, group)
			changed = true
		}
		if len(remaining) > 0 {
			hooks[spec.name] = remaining
		} else {
			delete(hooks, spec.name)
		}
	}
	if action == "status" {
		return found > 0, nil
	}
	if action == "enable" {
		exe, e := os.Executable()
		if e != nil {
			return false, e
		}
		b, e := os.ReadFile(exe)
		if e != nil {
			return false, e
		}
		old, _ := os.ReadFile(helperPath())
		if !bytes.Equal(b, old) {
			if e = atomicWrite(helperPath(), b, 0700); e != nil {
				return false, e
			}
		}
	}
	if !changed {
		return action == "enable", nil
	}
	doc["hooks"] = hooks
	current, e := os.ReadFile(path)
	if e != nil && !os.IsNotExist(e) {
		return false, e
	}
	if !bytes.Equal(raw, current) || exists != (e == nil) {
		return false, errors.New("configuration changed; please retry")
	}
	if exists {
		backup := path + ".before-perch-agent"
		if _, e := os.Stat(backup); os.IsNotExist(e) {
			if e = atomicWrite(backup, raw, 0600); e != nil {
				return false, e
			}
		}
	}
	out, e := json.MarshalIndent(doc, "", "  ")
	if e == nil {
		e = atomicWrite(path, append(out, '\n'), mode)
	}
	return action == "enable", e
}
