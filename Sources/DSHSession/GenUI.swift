import DSHProtocol
import Foundation

// GenUI (the `@changfenhuang/dsh-genui` DSH plugin): models emit a JSON
// component tree either through the `render_ui` tool or as a ```dsh-ui fence
// in their reply. Fences with `"panel": true` (and every render_ui call) drive
// the session's Panel dock above the composer; other fences render inline.
//
// The desktop keeps no panel state on the host — it folds these transcript
// records client-side — so the phone folds the same records the same way
// (mirrors `panel-store.ts`: sorted ops, latest replace wins, appends merge,
// 200-node / 200-append budgets).

public enum GenUI {
    public static let renderTool = "render_ui"
    public static let fenceLanguage = "dsh-ui"
    public static let maxNodes = 200
    public static let maxAppends = 200

    // MARK: Fences

    public enum Segment: Equatable, Sendable {
        case markdown(String)
        /// A fenced code block. `closed` is false while a stream is still writing it.
        case fence(language: String?, body: String, raw: String, closed: Bool)
    }

    /// Cheap pre-check before splitting a message.
    public static func mentionsFence(_ markdown: String) -> Bool {
        markdown.contains(fenceLanguage)
    }

    /// Split Markdown into prose and top-level fenced code blocks (CommonMark
    /// fence rules: ``` or ~~~, ≤3 spaces indent, closer at least as long).
    public static func segments(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var open: (marker: Character, length: Int, language: String?, lines: [Substring], opener: Substring)?
        func flushProse() {
            if !prose.isEmpty { segments.append(.markdown(prose.joined(separator: "\n"))) }
            prose.removeAll()
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let fence = open {
                if let closer = fenceMarker(line), closer.marker == fence.marker, closer.length >= fence.length,
                   line.drop(while: { $0 == " " }).dropFirst(closer.length).allSatisfy(\.isWhitespace) {
                    let raw = ([fence.opener] + fence.lines + [line]).joined(separator: "\n")
                    segments.append(.fence(language: fence.language, body: fence.lines.joined(separator: "\n"), raw: raw, closed: true))
                    open = nil
                } else {
                    open?.lines.append(line)
                }
            } else if let opener = fenceMarker(line) {
                let info = line.drop(while: { $0 == " " }).dropFirst(opener.length).trimmingCharacters(in: .whitespaces)
                // Backtick fences can't carry backticks in their info string.
                if opener.marker == "`" && info.contains("`") { prose.append(line); continue }
                flushProse()
                let language = info.split(separator: " ").first.map { $0.lowercased() }
                open = (opener.marker, opener.length, language, [], line)
            } else {
                prose.append(line)
            }
        }
        if let fence = open {
            let raw = ([fence.opener] + fence.lines).joined(separator: "\n")
            segments.append(.fence(language: fence.language, body: fence.lines.joined(separator: "\n"), raw: raw, closed: false))
        }
        flushProse()
        return segments
    }

    private static func fenceMarker(_ line: Substring) -> (marker: Character, length: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    /// A fence body as a spec: a JSON object with an `items` array.
    public static func spec(fromFence body: String) -> JSONValue? {
        guard let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value["items"]?.arrayValue != nil else { return nil }
        return value
    }

    public static func isPanel(_ spec: JSONValue) -> Bool { spec["panel"]?.boolValue == true }

    // MARK: Message display

    public enum DisplayBlock: Equatable, Sendable {
        case markdown(String)
        /// An inline (non-panel) spec, drawn in the message flow.
        case ui(JSONValue)
        /// A `panel:true` fence: it updates the dock, so the flow shows a marker.
        case panelUpdate(title: String?)
        /// A dsh-ui fence still streaming.
        case building
    }

    /// How an assistant message renders: prose (other code fences stay in
    /// the Markdown) interleaved with GenUI blocks. Unparseable dsh-ui fences
    /// stay visible as code, like the desktop.
    public static func displayBlocks(_ markdown: String) -> [DisplayBlock] {
        guard mentionsFence(markdown) else { return [.markdown(markdown)] }
        var blocks: [DisplayBlock] = []
        var buffer: [String] = []
        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.markdown(text)) }
            buffer.removeAll()
        }
        for segment in segments(markdown) {
            switch segment {
            case .markdown(let text):
                buffer.append(text)
            case .fence(let language, let body, let raw, let closed):
                guard language == fenceLanguage else { buffer.append(raw); continue }
                guard closed else { flush(); blocks.append(.building); continue }
                guard let spec = spec(fromFence: body) else { buffer.append(raw); continue }
                flush()
                blocks.append(isPanel(spec) ? .panelUpdate(title: spec["title"]?.stringValue) : .ui(spec))
            }
        }
        flush()
        return blocks
    }

    /// The Markdown pieces `displayBlocks` produces (for prewarming).
    public static func markdownPieces(_ markdown: String) -> [String] {
        displayBlocks(markdown).compactMap { if case .markdown(let text) = $0 { text } else { nil } }
    }

    // MARK: Panel fold

    public struct PanelOperation: Equatable, Sendable {
        public let sourceId: String
        /// [messageSeq, textBlockIndex, fenceIndex]; render_ui uses [resultSeq, -1, 0].
        public let order: [Int]
        public let append: Bool
        public let spec: JSONValue
    }

    public struct Panel: Equatable, Sendable {
        public let spec: JSONValue
        public var title: String? { spec["title"]?.stringValue }
        public var items: [JSONValue] { spec["items"]?.arrayValue ?? [] }
    }

    /// Every settled panel operation in the loaded transcript.
    public static func panelOperations(_ items: [TimelineItem]) -> [PanelOperation] {
        var ops: [PanelOperation] = []
        for item in items {
            switch item.content {
            case .tool(let tool):
                if let spec = tool.uiSpec, let seq = tool.resultSeq {
                    ops.append(PanelOperation(sourceId: "render_ui:\(tool.callId)", order: [seq, -1, 0], append: false, spec: spec))
                }
            case .assistant(let markdown) where mentionsFence(markdown):
                // Item ids are "a<seq>.<blockIndex>".
                let block = item.id.split(separator: ".").last.flatMap { Int($0) } ?? 0
                var fenceIndex = 0
                for segment in segments(markdown) {
                    guard case .fence(let language, let body, _, let closed) = segment else { continue }
                    defer { fenceIndex += 1 }
                    guard closed, language == fenceLanguage, let spec = spec(fromFence: body), isPanel(spec) else { continue }
                    ops.append(PanelOperation(
                        sourceId: "\(item.id):\(fenceIndex)", order: [item.seq, block, fenceIndex],
                        append: spec["append"]?.boolValue == true, spec: spec))
                }
            default:
                continue
            }
        }
        return ops
    }

    /// Highest message seq among the operations (the dismiss barrier).
    public static func latestSeq(_ ops: [PanelOperation]) -> Int {
        ops.map { $0.order[0] }.max() ?? -1
    }

    /// Fold operations newer than `barrier` (the seq at which the user last
    /// closed the panel) into the panel to show, or nil.
    public static func fold(_ ops: [PanelOperation], after barrier: Int = -1) -> Panel? {
        let live = ops.filter { $0.order[0] > barrier }.sorted { $0.order.lexicographicallyPrecedes($1.order) }
        let start = live.lastIndex { !$0.append && nodeCount($0.spec) <= maxNodes } ?? 0
        var snapshot: JSONValue?
        var appends = 0
        for op in live[start...] {
            if !op.append {
                guard nodeCount(op.spec) <= maxNodes else { continue }
                snapshot = op.spec
                appends = 0
                continue
            }
            let merged = merge(snapshot, op.spec)
            guard appends < maxAppends, nodeCount(merged) <= maxNodes else { continue }
            snapshot = merged
            appends += 1
        }
        guard let snapshot, snapshot["items"]?.arrayValue?.isEmpty == false else { return nil }
        return Panel(spec: snapshot)
    }

    /// Append `next` into `previous`: same-label tabs grow, new tabs are added,
    /// plain item lists are concatenated. The earlier title wins.
    public static func merge(_ previous: JSONValue?, _ next: JSONValue) -> JSONValue {
        guard let previous, case .object(var base) = previous, let prevItems = previous["items"]?.arrayValue, !prevItems.isEmpty else {
            return next
        }
        if base["title"] == nil, let title = next["title"] { base["title"] = title }
        let nextItems = next["items"]?.arrayValue ?? []
        if let prevTabs = tabs(prevItems), let nextTabs = tabs(nextItems) {
            var labels: [String] = []
            var merged: [String: [JSONValue]] = [:]
            for tab in prevTabs + nextTabs {
                let label = tab["label"]?.stringValue ?? ""
                if merged[label] == nil { labels.append(label) }
                merged[label, default: []] += tab["items"]?.arrayValue ?? []
            }
            let tabList: [JSONValue] = labels.map { .object(["label": .string($0), "items": .array(merged[$0] ?? [])]) }
            base["items"] = .array([.object(["type": "tabs", "tabs": .array(tabList)])])
        } else {
            base["items"] = .array(prevItems + nextItems)
        }
        return .object(base)
    }

    private static func tabs(_ items: [JSONValue]) -> [JSONValue]? {
        guard items.count == 1, items[0]["type"]?.stringValue == "tabs" else { return nil }
        return items[0]["tabs"]?.arrayValue
    }

    /// Component nodes in a tree (any object carrying a string `type`).
    public static func nodeCount(_ value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            let own = object["type"]?.stringValue == nil ? 0 : 1
            return own + object.values.reduce(0) { $0 + nodeCount($1) }
        case .array(let array):
            return array.reduce(0) { $0 + nodeCount($1) }
        default:
            return 0
        }
    }

    // MARK: Actions

    /// The prompt the desktop sends when a panel control with an `action`
    /// fires (verbatim from the plugin, so the model sees the same request).
    public static func actionPrompt(_ action: String, payload: [String: JSONValue]) -> String {
        let data = payload.isEmpty ? "" : " 组件数据: \(JSONValue.object(payload).compactDescription)"
        return "[genui-action] \(action)。用户刚刚在面板中触发了动作 \"\(action)\"，请根据组件数据执行相应操作，只输出一个 panel:true 的 dsh-ui 围栏来更新面板，回复文本至多一行 10 字以内的确认（如\"已刷新\"），不要解释、不要普通围栏。\(data)"
    }

    /// The action name if a user message is a panel action prompt.
    public static func actionName(inPrompt text: String) -> String? {
        guard text.hasPrefix("[genui-action] "), let end = text.firstIndex(of: "。") else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: 15)..<end])
    }
}
