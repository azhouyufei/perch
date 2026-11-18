// Perch's local agent hook. The event command never writes an approval decision.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

type endpoint struct {
	Port int
	Key  string
}
type hookInput struct {
	Session      string `json:"session_id"`
	Event        string `json:"hook_event_name"`
	Tool         string `json:"tool_name"`
	ID           string `json:"tool_use_id"`
	Cwd          string `json:"cwd"`
	Notification string `json:"notification_type"`
	AgentID      string `json:"agent_id"`
}
type signal struct{ Key, Agent, Session, Event, Tool, ID, Project, Reason string }
type reminder struct {
	Agent, Project, Reason, Tool, Resume string
	Sequence                             int
}
type pending struct {
	signal
	reminder reminder
}

func classify(agent string, h hookInput) (signal, bool) {
	if h.Session == "" || len(h.Session) > 256 {
		return signal{}, false
	}
	s := signal{Agent: agent, Session: h.Session, Event: h.Event, Tool: h.Tool, ID: h.ID, Project: filepath.Base(h.Cwd)}
	switch h.Event {
	case "PermissionRequest":
		s.Reason = "permission"
	case "PreToolUse":
		if (agent == "claude" && h.Tool == "AskUserQuestion") || (agent == "codex" && h.Tool == "request_user_input") {
			s.Reason = "question"
		} else {
			return signal{}, false
		}
	case "Notification":
		if agent != "claude" || (h.Notification != "elicitation_dialog") {
			return signal{}, false
		}
		s.Reason = "input"
	case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "SessionEnd", "Interrupt":
	default:
		return signal{}, false
	}
	if h.AgentID != "" {
		s.Session += "\x00" + h.AgentID
	}
	return s, true
}
func display(s string) string {
	chars := []rune(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf) {
			return -1
		}
		return r
	}, s))
	if len(chars) > 90 {
		return string(chars[:90])
	}
	return string(chars)
}

var sessionID = regexp.MustCompile(`^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$`)

func resumeCommand(s signal) string {
	id, _, _ := strings.Cut(s.Session, "\x00")
	if !sessionID.MatchString(id) {
		return ""
	}
	if s.Agent == "claude" {
		return "claude --resume " + id
	}
	return "codex resume " + id
}

func apply(list map[string]pending, s signal, seq int) bool {
	changed := false
	for k, p := range list {
		if p.Agent != s.Agent || (s.Event != "Disabled" && p.Session != s.Session) {
			continue
		}
		if s.Reason != "" {
			if s.Reason == "input" || (p.Tool == s.Tool && (p.ID == s.ID || p.ID == "" || s.ID == "")) {
				return false
			}
		} else {
			if (s.Event == "PostToolUse" || s.Event == "PostToolUseFailure") && p.Reason != "input" && (p.Tool != s.Tool || (p.ID != "" && s.ID != "" && p.ID != s.ID)) {
				continue
			}
			delete(list, k)
			changed = true
		}
	}
	if s.Reason != "" {
		list[fmt.Sprint(seq)] = pending{s, reminder{s.Agent, display(s.Project), s.Reason, display(s.Tool), resumeCommand(s), seq}}
		return true
	}
	return changed
}
func endpointPath() string { return filepath.Join(rootDir(), "agent-endpoint.json") }
func event(agent string) {
	var ep endpoint
	data, err := os.ReadFile(endpointPath())
	if err != nil || json.Unmarshal(data, &ep) != nil {
		return
	}
	var h hookInput
	if json.NewDecoder(io.LimitReader(os.Stdin, 16<<20)).Decode(&h) != nil {
		return
	}
	s, ok := classify(agent, h)
	if !ok {
		return
	}
	send(ep, s)
}
func send(ep endpoint, s signal) {
	s.Key = ep.Key
	c, err := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", ep.Port), 200*time.Millisecond)
	if err != nil {
		return
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(350 * time.Millisecond))
	if json.NewEncoder(c).Encode(s) == nil {
		var ack [1]byte
		c.Read(ack[:])
	}
}
func watch() error {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer l.Close()
	var secret [32]byte
	if _, err = rand.Read(secret[:]); err != nil {
		return err
	}
	ep := endpoint{l.Addr().(*net.TCPAddr).Port, hex.EncodeToString(secret[:])}
	raw, _ := json.Marshal(ep)
	if err = atomicWrite(endpointPath(), raw, 0600); err != nil {
		return err
	}
	defer func() {
		if b, _ := os.ReadFile(endpointPath()); string(b) == string(raw) {
			os.Remove(endpointPath())
		}
	}()
	go func() { io.Copy(io.Discard, os.Stdin); l.Close() }()
	list := map[string]pending{}
	seq := 0
	for {
		c, e := l.Accept()
		if e != nil {
			return nil
		}
		c.SetDeadline(time.Now().Add(500 * time.Millisecond))
		var s signal
		if json.NewDecoder(bufio.NewReader(io.LimitReader(c, 8192))).Decode(&s) == nil && s.Key == ep.Key {
			seq++
			if apply(list, s, seq) {
				rows := make([]reminder, 0, len(list))
				for _, p := range list {
					rows = append(rows, p.reminder)
				}
				sort.Slice(rows, func(i, j int) bool { return rows[i].Sequence < rows[j].Sequence })
				if err = json.NewEncoder(os.Stdout).Encode(rows); err != nil {
					c.Close()
					return err
				}
			}
			c.Write([]byte{1})
		}
		c.Close()
	}
}
func main() {
	a := os.Args[1:]
	if len(a) == 1 && a[0] == "watch" {
		if e := watch(); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		return
	}
	if len(a) != 2 || (a[1] != "claude" && a[1] != "codex") {
		os.Exit(2)
	}
	switch a[0] {
	case "event":
		event(a[1])
	case "enable", "disable", "status":
		on, e := configure(a[0], a[1])
		if e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		if a[0] == "disable" {
			var ep endpoint
			if data, e := os.ReadFile(endpointPath()); e == nil && json.Unmarshal(data, &ep) == nil {
				send(ep, signal{Agent: a[1], Event: "Disabled"})
			}
		}
		fmt.Println(on)
	default:
		os.Exit(2)
	}
}
