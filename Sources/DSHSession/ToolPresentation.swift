import DSHProtocol
import Foundation

/// How DSH presents a tool call (mirrors dsh-client-ui-chat `toolRowModel`):
/// a title, an icon, a one-line summary, and an activity category for group
/// headers ("Ran commands and edited files").
public enum ToolActivity: String, CaseIterable, Sendable {
    case commands, edit, write, read, readImage, search, webSearch, webFetch, code, subagents, plan, questions, tools

    public init(toolName name: String) {
        switch name {
        case "read": self = .read
        case "read_image": self = .readImage
        case "grep", "glob": self = .search
        case "write": self = .write
        case "edit", "apply_patch", "str_replace_editor": self = .edit
        case "bash", "pwsh", "exec_command", "write_stdin", "job_output", "job_kill", "job_list": self = .commands
        case "run_code": self = .code
        case "web_search": self = .webSearch
        case "web_fetch": self = .webFetch
        case "todo_write", "create_goal", "update_goal", "get_goal": self = .plan
        case "ask_user_question": self = .questions
        default:
            if name.hasPrefix("terminal_") { self = .commands }
            else if name.hasSuffix("_inspect") { self = .search }
            else if name.hasPrefix("subagent") || ["send_message", "list_agents", "interrupt_agent"].contains(name) { self = .subagents }
            else if name.hasSuffix("_goal") { self = .plan }
            else { self = .tools }
        }
    }

    /// Group header while the group is running.
    public var runningTitle: String {
        switch self {
        case .commands: "Running commands"
        case .read: "Reading files"
        case .readImage: "Reading images"
        case .search: "Searching code"
        case .edit: "Editing files"
        case .write: "Writing files"
        case .webSearch: "Searching the web"
        case .webFetch: "Visiting web pages"
        case .subagents: "Coordinating subagents"
        case .plan: "Updating the plan"
        case .questions: "Waiting for your action"
        case .code: "Running code"
        case .tools: "Calling tools"
        }
    }

    /// Lower-cased past tense, joined into closed group titles.
    public var doneTitle: String {
        switch self {
        case .commands: "ran commands"
        case .read: "read files"
        case .readImage: "read images"
        case .search: "searched code"
        case .edit: "edited files"
        case .write: "wrote files"
        case .webSearch: "searched the web"
        case .webFetch: "visited web pages"
        case .subagents: "coordinated subagents"
        case .plan: "updated the plan"
        case .questions: "asked questions"
        case .code: "ran code"
        case .tools: "called tools"
        }
    }

    /// SF Symbol standing in for DSH's glyph.
    public var symbol: String {
        switch self {
        case .commands: "terminal"
        case .read, .readImage, .webFetch: "doc.text"
        case .search: "magnifyingglass"
        case .edit, .write: "pencil"
        case .webSearch: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .subagents: "person.2"
        case .plan: "checklist"
        case .questions: "questionmark.bubble"
        case .tools: "sparkle"
        }
    }
}

public struct ToolPresentation: Equatable, Sendable {
    public let title: String
    public let summary: String
    public let activity: ToolActivity
    public var symbol: String { activity.symbol }

    public init(_ tool: ToolCallItem, cwd: String? = nil) {
        let args = tool.parsedArguments
        activity = ToolActivity(toolName: tool.name)
        let known: [String: String] = [
            "bash": "Bash", "pwsh": "Pwsh", "read": "Read", "read_image": "Read image", "write": "Write", "edit": "Edit",
            "grep": "Grep", "glob": "Glob", "web_search": "Search", "web_fetch": "Fetch", "run_code": "Code",
            "todo_write": "Update to-do list", "ask_user_question": "Ask question", "subagent": "Create subagent",
            "subagent_fork": "Fork subagent", "send_message": "Send message", "list_agents": "List subagents",
            "skill": "Skill", "job_output": "Job output", "job_kill": "Stop job", "job_list": "List jobs",
            GenUI.renderTool: "Render panel", "validate_dsh_ui": "Validate UI",
        ]
        let keys: [String]
        switch activity {
        case .commands: keys = ["description", "command", "job_id"]
        case .read, .readImage, .webFetch: keys = ["path", "file_path", "url"]
        case .search, .webSearch: keys = ["query", "pattern", "url", "path"]
        case .write, .edit: keys = ["path", "file_path"]
        case .code: keys = ["description"]
        default: keys = ["title", "description", "name", "query", "message", "path", "url"]
        }
        var summary = keys.lazy.compactMap { args[$0]?.stringValue }.first { !$0.isEmpty }
        if activity == .search || activity == .webSearch, let queries = args["queries"]?.arrayValue {
            let joined = queries.compactMap(\.stringValue).joined(separator: ", ")
            if !joined.isEmpty { summary = joined }
        }
        if tool.name == "todo_write", let todos = args["todos"]?.arrayValue {
            let done = todos.filter { $0["status"]?.stringValue == "completed" }.count
            let active = todos.first { $0["status"]?.stringValue == "in_progress" }?["content"]?.stringValue
            summary = "\(done)/\(todos.count) completed" + (active.map { " · \($0)" } ?? "")
        }
        if tool.name == "ask_user_question", let questions = args["questions"]?.arrayValue {
            summary = questions.first?["question"]?.stringValue
        }
        if tool.name == GenUI.renderTool {
            let spec = args["spec"].flatMap { $0.stringValue.flatMap(GenUI.spec(fromFence:)) ?? $0 }
            summary = tool.uiSpec?["title"]?.stringValue ?? spec?["title"]?.stringValue ?? ""
        }
        if summary == nil, case .object(let object) = args {
            summary = object.keys.sorted().lazy.compactMap { object[$0]?.stringValue }.first
        }
        let line = (summary ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let shortened = Self.shorten(line, cwd: cwd)
        if let title = known[tool.name] {
            self.title = title
            self.summary = shortened
        } else {
            self.title = "Tool call"
            self.summary = shortened.isEmpty ? tool.name : "\(tool.name) · \(shortened)"
        }
    }

    /// Paths relative to the session cwd; home as `~`.
    static func shorten(_ text: String, cwd: String?) -> String {
        if let cwd, !cwd.isEmpty, text.hasPrefix(cwd + "/") { return String(text.dropFirst(cwd.count + 1)) }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty, text.hasPrefix(home + "/") {
            return "~" + text.dropFirst(home.count)
        }
        if let range = text.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + text[range.upperBound...]
        }
        return text
    }
}

/// Closed group title from the activities it contains: up to three, ranked by
/// count, no numbers ("Ran commands, edited files, read files, etc.").
public func groupDoneTitle(_ activities: [ToolActivity]) -> String {
    guard !activities.isEmpty else { return "Analysis completed" }
    var counts: [ToolActivity: Int] = [:]
    var firstSeen: [ToolActivity: Int] = [:]
    for (index, activity) in activities.enumerated() {
        counts[activity, default: 0] += 1
        if firstSeen[activity] == nil { firstSeen[activity] = index }
    }
    let ranked = counts.keys.sorted { (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!) }
    let names = ranked.prefix(3).map(\.doneTitle)
    var title: String
    switch names.count {
    case 1: title = names[0]
    case 2: title = "\(names[0]) and \(names[1])"
    default: title = names.joined(separator: ", ")
    }
    if ranked.count > 3 { title += ", etc." }
    return title.prefix(1).uppercased() + title.dropFirst()
}

/// "Completed in 1m 5s".
public func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \((total % 3600) / 60)m"
}
