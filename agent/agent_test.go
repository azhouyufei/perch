package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWaiting(t *testing.T) {
	list := map[string]pending{}
	run := func(agent, event, session, tool, id string) bool {
		s, ok := classify(agent, hookInput{Session: session, Event: event, Tool: tool, ID: id, Cwd: "/workspace/demo"})
		return ok && apply(list, s, 100+len(list))
	}
	if run("codex", "UserPromptSubmit", "a", "", "") {
		t.Fatal("alert on work")
	}
	if !run("claude", "PreToolUse", "a", "AskUserQuestion", "q") {
		t.Fatal("missing question")
	}
	if run("claude", "PermissionRequest", "a", "AskUserQuestion", "q") {
		t.Fatal("duplicate question")
	}
	if !run("codex", "PermissionRequest", "a", "Bash", "b") {
		t.Fatal("missing approval")
	}
	if run("claude", "PostToolUse", "a", "Bash", "x") {
		t.Fatal("unrelated tool cleared an alert")
	}
	if run("codex", "Stop", "other", "", "") {
		t.Fatal("unrelated session")
	}
	if !run("codex", "Interrupt", "a", "", "") || len(list) != 1 {
		t.Fatal("interrupt did not isolate sessions")
	}
	if !run("claude", "PostToolUse", "a", "AskUserQuestion", "q") || len(list) != 0 {
		t.Fatal("question not resolved")
	}
	if run("codex", "Stop", "a", "", "") {
		t.Fatal("alert on completion")
	}
}
func TestConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("LOCALAPPDATA", dir)
	for _, agent := range []string{"claude", "codex"} {
		cfg := filepath.Join(dir, agent)
		os.MkdirAll(cfg, 0700)
		if agent == "claude" {
			t.Setenv("CLAUDE_CONFIG_DIR", cfg)
		} else {
			t.Setenv("CODEX_HOME", cfg)
		}
		path := configPath(agent)
		raw := []byte(`{"extra":9007199254740993,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]}}`)
		os.WriteFile(path, raw, 0600)
		for _, action := range []string{"enable", "enable", "status", "disable", "disable", "status"} {
			on, err := configure(action, agent)
			if err != nil {
				t.Fatal(err)
			}
			if action == "enable" && !on {
				t.Fatal("disabled")
			}
		}
		data, _ := os.ReadFile(path)
		doc, err := loadConfig(data)
		if err != nil {
			t.Fatal(err)
		}
		if doc["extra"].(json.Number).String() != "9007199254740993" || len(doc["hooks"].(object)) != 1 {
			t.Fatal("unrelated data changed")
		}
		copy, _ := os.ReadFile(path + ".before-perch-agent")
		if string(copy) != string(raw) {
			t.Fatal("original backup missing")
		}
		os.WriteFile(path, []byte("{broken"), 0600)
		if _, err := configure("enable", agent); err == nil {
			t.Fatal("modified malformed settings")
		}
	}
}

func TestResumeAndDisable(t *testing.T) {
	id := "01234567-89ab-cdef-0123-456789abcdef"
	if got := resumeCommand(signal{Agent: "claude", Session: id + "\x00helper"}); got != "claude --resume "+id {
		t.Fatal(got)
	}
	if got := resumeCommand(signal{Agent: "codex", Session: id}); got != "codex resume "+id {
		t.Fatal(got)
	}
	if got := resumeCommand(signal{Agent: "codex", Session: "a; anything"}); got != "" {
		t.Fatal(got)
	}
	list := map[string]pending{}
	for i, agent := range []string{"claude", "codex", "claude"} {
		apply(list, signal{Agent: agent, Session: string(rune('a' + i)), Tool: "Bash", Reason: "permission"}, i)
	}
	if !apply(list, signal{Agent: "claude", Event: "Disabled"}, 4) || len(list) != 1 {
		t.Fatal("disabled agent still pending")
	}
	for _, p := range list {
		if p.Agent != "codex" {
			t.Fatal("wrong session removed")
		}
	}
}
