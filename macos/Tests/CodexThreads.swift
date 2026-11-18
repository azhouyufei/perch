import Foundation
import SQLite3
import PerchCore

func checkCodexThreads() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]!)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func database(_ file: String, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent(file).path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    database("state_5.sqlite", """
        CREATE TABLE threads(id PRIMARY KEY,source,archived,cwd,updated_at,created_at,name,title,project_id);
        CREATE TABLE projects(id,name);
        CREATE TABLE project_roots(project_id,path);
        INSERT INTO projects VALUES('outer','Outer'),('inner','Mobile app');
        INSERT INTO project_roots VALUES('outer','/work'),('inner','/work/mobile');
        INSERT INTO threads VALUES('project','vscode',0,'/work/mobile/src',1000,900,'Release checklist','Old title',NULL),
          ('outside','vscode',0,'/personal',1100,900,'Weekend plan',NULL,NULL),
          ('moved','vscode',0,'/new-location',1050,900,'Relocated',NULL,'inner'),
          ('archived','vscode',1,'/work',1200,900,'Hidden',NULL,NULL),
          ('helper','{"subagent":"review"}',0,'/work',1300,900,'Hidden',NULL,NULL);
        """)
    database("thread_history_1.sqlite", """
        CREATE TABLE thread_turns(thread_id,turn_id,rollout_ordinal,status,started_at,completed_at,first_user_item_id,final_agent_item_id);
        CREATE TABLE thread_items(thread_id,turn_id,item_id,item_type,item_json);
        INSERT INTO thread_turns VALUES('project','turn1',1,'completed',900,920,'u1','a1'),
                                       ('project','turn2',2,'completed',950,1000,'u2','a2');
        INSERT INTO thread_items VALUES('project','turn2','u2','userMessage','{"content":[{"type":"text","text":"Check the release build"}]}'),
          ('project','turn2','a2','agentMessage','{"text":"The release build passed."}'),
          ('outside','turn2','a2','agentMessage','{"text":"Unrelated answer"}');
        """)
    let scanner = SessionScanner()
    scanner.usable = { $0 == "/personal" }
    scanner.lookUpGit = { _ in nil }; scanner.lookUpBranch = { _ in nil }; scanner.lookUpRepo = { _ in nil }
    let day = root.appendingPathComponent("sessions/2026/11/17")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    for id in ["archived", "outside", "legacy"] {
        let log = """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/personal","source":"cli"}}
            {"timestamp":"2026-11-17T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the failing tests in the project"}]}}
            {"timestamp":"2026-11-17T10:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The build passed all checks."}]}}
            """
        try Data(log.utf8).write(to: day.appendingPathComponent("rollout-\(id).jsonl"))
    }
    let rows = scanner.codex(limit: .max)
    precondition(Set(rows.map(\.project.id)) == ["project", "outside", "moved", "legacy"] && rows.count == 4)
    let project = rows.first { $0.project.id == "project" }!
    precondition(project.project.name == "Mobile app" && project.project.topic == "Release checklist")
    precondition(project.digest.lastUserFull == "Check the release build")
    precondition(project.digest.lastAssistantFull == "The release build passed.")
    precondition(rows.first { $0.project.id == "moved" }?.project.name == "Mobile app")
    database("state_5.sqlite", "UPDATE threads SET archived=1 WHERE id='project'")
    precondition(!scanner.codex(limit: .max).contains { $0.project.id == "project" })

    let started = """
        {"timestamp":"2026-11-18T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"new-turn"}}
        """
    let completed = """
        {"timestamp":"2026-11-18T10:00:05Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"new-turn","last_agent_message":"The build is ready."}}
        """
    let metadata = """
        {"type":"session_meta","payload":{"id":"not-indexed","cwd":"/unavailable/project","source":"vscode"}}
        """
    let newFile = day.appendingPathComponent("rollout-not-indexed.jsonl")
    try Data((metadata + "\n" + started).utf8).write(to: newFile)
    let active = scanner.codex(limit: .max, now: Date(timeIntervalSince1970: 1794996001))
    precondition(active.first { $0.project.id == "not-indexed" }?.project.status.kind == "running")
    let digest = CodexTranscript.digest(lines: [metadata, started, completed])
    precondition(!digest.turnOpen && digest.turnId == "new-turn" && digest.lastRole == "assistant")
    precondition(digest.lastAssistantFull == "The build is ready.")
    let ended = Recap.project(digest: digest, git: nil, now: digest.lastTimestamp!, agent: .codex)!
    let working = LiveStatus.apply(HookEvent(agent: "codex", sessionId: "not-indexed",
        kind: .started, at: digest.lastTimestamp!.addingTimeInterval(-5)), to: nil)
    precondition(!working.holds(for: ended))
    precondition(Focus.inCodexApp([ended]).isEmpty)

    let hookBody = Data(#"{"session_id":"hook-first","cwd":"/unavailable/project","turn_id":"hook-turn","last_assistant_message":"Ready for review."}"#.utf8)
    let event = HookEvent.parse(agent: "codex", event: "Stop", body: hookBody, requestId: "event")!
    scanner.noteCodexEvent(event)
    scanner.noteCodexEvent(event)
    let discovered = scanner.codex(limit: .max)
    precondition(discovered.filter { $0.project.id == "hook-first" }.count == 1)
    precondition(discovered.first { $0.project.id == "hook-first" }?.project.status.kind == "done")
    precondition(discovered.first { $0.project.id == "hook-first" }?.project.turnId == "hook-turn")
    var hiddenHook = event
    hiddenHook.helper = "helper"
    let other = SessionScanner(home: root)
    other.noteCodexEvent(hiddenHook)
    precondition(!other.codex(limit: .max).contains { $0.project.id == "hook-first" })
    print("PASS unindexed Codex conversation, lifecycle completion, stale start hook and foreground notification policy")
    print("PASS hook-first discovery preserves current turn and deduplicates the session")
    print("PASS Codex indexed project history, latest turn, renamed projects, rollout fallback, deduplication and archive refresh")

    try FileManager.default.createDirectory(at: root.appendingPathComponent("sqlite"), withIntermediateDirectories: true)
    let chatID = "aaaaaaaa-0000-4000-8000-000000000001"
    let missingID = "aaaaaaaa-0000-4000-8000-000000000002"
    let personalID = "aaaaaaaa-0000-4000-8000-000000000003"
    let time = Date().timeIntervalSince1970
    database("sqlite/codex.db", """
        CREATE TABLE local_thread_catalog_hosts(host_id,host_kind);
        CREATE TABLE local_thread_catalog(host_id,thread_id,display_title,source_created_at,source_updated_at,source_recency_at,source_kind,conversation_origin,missing_candidate);
        CREATE TABLE active_chat_turns(thread_id,observed_at_ms);
        INSERT INTO local_thread_catalog_hosts VALUES('chatgpt:test','chatgpt'),('local','local');
        INSERT INTO local_thread_catalog VALUES
          ('chatgpt:test','\(chatID)','Work without a local rollout',\(time-100),\(time),\(time),'chatgpt','tpp',0),
          ('chatgpt:test','\(missingID)','Removed Work',\(time),\(time),\(time),'chatgpt','tpp',1),
          ('chatgpt:test','\(personalID)','Personal chat',\(time),\(time),\(time),'chatgpt',NULL,0),
          ('local','aaaaaaaa-0000-4000-8000-000000000004','Local duplicate',\(time),\(time),\(time),'vscode','tpp',0);
        """)
    let chats = scanner.chatGPTWork(limit: .max)
    precondition(chats.count == 1 && chats[0].project.name == "Work without a local rollout")
    let work = chats[0].project
    precondition(work.id == "chatgpt:" + chatID && work.cwd == nil && !work.terminal)
    precondition(work.status.kind == "idle" && work.status.kind != "done")
    precondition(work.chatGPTURL?.absoluteString == "https://chatgpt.com/c/" + chatID)
    precondition(SessionManage.actions(for: work).isEmpty)
    database("sqlite/codex.db", "INSERT INTO active_chat_turns VALUES('\(chatID)',\(time*1000))")
    precondition(scanner.chatGPTWork(limit: .max)[0].project.status.kind == "running")
    precondition(scanner.chatGPTWork(limit: .max, now: Date(timeIntervalSince1970: time+121))[0].project.status.kind == "idle")
    database("sqlite/codex.db", "UPDATE local_thread_catalog SET missing_candidate=1 WHERE thread_id='\(chatID)'")
    precondition(scanner.chatGPTWork(limit: .max).isEmpty)
    print("PASS ChatGPT Work discovery without CLI rollout, excludes personal chats, restores parent URL and blocks CLI mutations")
    print("PASS Work activity expiry never fabricates completion and removed catalog entries disappear")
}
