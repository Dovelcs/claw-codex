import Combine
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum FleetWorkbenchLocalError: LocalizedError {
    case fixedCodexSessionUnavailable(String)
    case unsafeCurrentBridgeSession(String)

    var errorDescription: String? {
        switch self {
        case .fixedCodexSessionUnavailable(let target):
            return "未找到固定 Codex 会话 \(target)"
        case .unsafeCurrentBridgeSession(let sessionID):
            return "拒绝向当前桥接会话 \(sessionID) 发送"
        }
    }
}

#if os(iOS)
private extension Color {
    static func fleetPlatform(_ color: UIColor) -> Color { Color(uiColor: color) }
}
#elseif os(macOS)
private extension Color {
    static func fleetPlatform(_ color: NSColor) -> Color { Color(nsColor: color) }
}
#endif

struct FleetEndpoint: Decodable, Identifiable {
    var endpoint_id: String
    var label: String?
    var status: String?
    var capabilities: JSONValue?
    var last_seen_at: String?
    var created_at: String?
    var updated_at: String?

    var id: String { endpoint_id }
}

struct FleetProject: Decodable, Identifiable {
    var alias: String
    var endpoint_id: String
    var path: String
    var mode: String?
    var created_at: String?
    var updated_at: String?

    var id: String { alias }
}

struct FleetSession: Decodable, Identifiable {
    var session_id: String
    var endpoint_id: String
    var source: String?
    var title: String?
    var cwd: String?
    var rollout_path: String?
    var status: String?
    var thread_id: String?
    var active_turn_id: String?
    var updated_at: String?

    var id: String { session_id }
}

private extension FleetSession {
    var normalizedSource: String {
        source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    var normalizedTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedUpdatedAt: String {
        updated_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var isRelayPlaceholder: Bool {
        normalizedSource == "mkb" || normalizedSource == "codex-relay" || session_id == "session-default"
    }

    var isCurrentVscodeBridge: Bool {
        session_id == "linux-vscode-main" ||
        (normalizedSource == "vscode-codex" && normalizedTitle.localizedCaseInsensitiveContains("当前"))
    }

    var isCodexRuntimeCandidate: Bool {
        if isCurrentVscodeBridge { return true }
        if isRelayPlaceholder { return false }
        if normalizedSource == "mkb" { return false }
        if normalizedSource.isEmpty { return true }
        if normalizedSource.contains("codex") || normalizedSource.contains("vscode") { return true }
        return !(thread_id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var isPreferredCodexRuntime: Bool {
        if normalizedSource.contains("vscode") || normalizedSource.contains("desktop") { return true }
        return normalizedSource.contains("codex") && !isRelayPlaceholder
    }

    var recencySortKey: String {
        if !normalizedUpdatedAt.isEmpty { return normalizedUpdatedAt }
        if !normalizedTitle.isEmpty { return normalizedTitle }
        return session_id
    }
}

private func codexSessionPriority(_ session: FleetSession) -> Int {
    if session.isPreferredCodexRuntime { return 1 }
    if !session.isRelayPlaceholder { return 2 }
    return 3
}

private func codexSessionPrecedes(_ lhs: FleetSession, _ rhs: FleetSession) -> Bool {
    let leftPriority = codexSessionPriority(lhs)
    let rightPriority = codexSessionPriority(rhs)
    if leftPriority != rightPriority { return leftPriority < rightPriority }
    let leftKey = lhs.recencySortKey
    let rightKey = rhs.recencySortKey
    if leftKey != rightKey { return leftKey > rightKey }
    return lhs.session_id > rhs.session_id
}

struct FleetTask: Decodable, Identifiable {
    var task_id: String
    var endpoint_id: String?
    var project_alias: String?
    var session_id: String?
    var prompt: String?
    var mode: String?
    var model: String?
    var reasoning_effort: String?
    var status: String?
    var phase: String?
    var last_summary: String?
    var profile: String?
    var chat_channel: String?
    var chat_id: String?
    var created_at: String?
    var updated_at: String?

    var id: String { task_id }
}

struct FleetChatBinding: Decodable, Identifiable {
    var channel: String
    var chat_id: String
    var profile: String?
    var endpoint_id: String?
    var project_alias: String?
    var session_id: String?
    var title: String?
    var session_policy: String?
    var updated_at: String?

    var id: String { "\(channel):\(chat_id)" }
}

struct FleetSessionMapping: Decodable, Identifiable {
    var number: Int
    var binding: FleetChatBinding
    var session: FleetSession?

    var id: String { binding.id }
}

struct FleetEventsResponse: Decodable {
    var events: [FleetEvent]
}

struct FleetEvent: Decodable, Identifiable {
    var event_id: Int
    var endpoint_id: String?
    var task_id: String?
    var session_id: String?
    var type: String
    var message: String?
    var data: JSONValue?
    var created_at: String?

    var id: Int { event_id }
}

struct FleetChatStatus: Decodable {
    var binding: FleetChatBinding?
    var active_task: FleetTask?
    var recent_tasks: [FleetTask]?
}

struct FleetSessionChatsResponse: Decodable {
    var mappings: [FleetSessionMapping]
}

struct FleetStateResponse: Decodable {
    var endpoints: [FleetEndpoint]
    var projects: [FleetProject]
    var sessions: [FleetSession]
    var tasks: [FleetTask]
}

struct FleetV1StateResponse: Decodable {
    var endpoints: [FleetEndpoint]
    var sessions: [FleetSession]
    var message_count: Int?
    var message_state_count: Int?
    var event_count: Int?
    var next_event_id: Int?
}

struct FleetCodexMessagesResponse: Decodable {
    var messages: [FleetCodexMessage]
}

struct FleetCodexMessageStatesResponse: Decodable {
    var states: [FleetCodexMessageState]
}

struct FleetCodexMessage: Decodable, Identifiable {
    var endpoint_id: String
    var session_id: String
    var message_id: String
    var turn_id: String?
    var seq: Int
    var role: String
    var text: String
    var status: String?
    var updated_at: String?

    var id: String { "\(endpoint_id):\(session_id):\(message_id)" }
    var isUser: Bool { role.lowercased() == "user" }
    var isVisibleConversationMessage: Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            return isUser || ["queued", "running", "streaming"].contains(status ?? "")
        }
        if isUser { return true }
        return !Self.isRawCodexEventEnvelope(trimmedText)
    }

    private static func isRawCodexEventEnvelope(_ text: String) -> Bool {
        guard text.first == "{",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return text.contains("\"type\":\"item.completed\"") && text.contains("\"item\"")
        }

        let rawEventTypes = Set([
            "item.completed",
            "item.started",
            "item.updated",
            "response.completed",
            "response.failed",
            "response.output_item.done"
        ])
        return rawEventTypes.contains(type) && object["item"] != nil
    }
}

struct FleetCodexMessageState: Decodable, Identifiable {
    var endpoint_id: String
    var session_id: String
    var message_id: String
    var turn_id: String?
    var status: String
    var detail: String?
    var updated_at: String?

    var id: String { "\(endpoint_id):\(session_id):\(message_id)" }
}

struct FleetV1CommandRequest: Encodable {
    var endpoint_id: String
    var session_id: String
    var type: String
    var payload_json: String
}

struct FleetHistoryLoadRequest: Encodable {
    var endpoint_id: String
    var session_id: String
}

struct FleetV1Command: Decodable {
    var command_id: Int
    var endpoint_id: String
    var session_id: String
    var type: String
    var status: String?
}

struct FleetSummaryResponse: Decodable {
    struct ContextRow: Decodable {
        var profile: String?
        var project_alias: String?
        var session_id: String?
        var updated_at: String?
    }

    struct Counts: Decodable {
        var active: Int
        var recent: Int
        var sessions: Int
    }

    var context: ContextRow?
    var endpoints: [FleetEndpoint]?
    var active_tasks: [FleetTask]
    var recent_tasks: [FleetTask]
    var counts: Counts
}

struct FleetProjectRequest: Encodable {
    var alias: String
    var endpoint_id: String
    var path: String
    var mode: String
}

struct FleetUseProjectRequest: Encodable {
    var profile: String
    var project_alias: String
}

struct FleetUseSessionRequest: Encodable {
    var profile: String
    var session_selector: String
}

struct FleetClearTargetRequest: Encodable {
    var profile: String
}

struct FleetBindChatRequest: Encodable {
    var channel: String
    var chat_id: String
    var profile: String
    var project_alias: String
    var endpoint_id: String
    var session_policy: String
}

struct FleetUnbindChatRequest: Encodable {
    var channel: String
    var chat_id: String
}

struct FleetSessionSyncRequest: Encodable {
    var channel: String
    var owner_chat_id: String
    var profile: String
    var endpoint_id: String
    var project_alias: String
    var limit: Int
}

struct FleetTaskRequest: Encodable {
    var profile: String
    var prompt: String
    var project_alias: String?
    var session_selector: String?
    var mode: String?
    var model: String?
    var reasoning_effort: String?
}

struct FleetChatTaskRequest: Encodable {
    var channel: String
    var chat_id: String
    var prompt: String
    var mode: String?
    var model: String?
    var reasoning_effort: String?
}

struct FleetStopRequest: Encodable {
    var target: String
}

struct FleetNewConversationRequest: Encodable {
    var profile: String
    var endpoint_id: String
    var project_alias: String
    var title: String?
}

struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let array = try? [JSONValue](from: decoder) {
            self = .array(array)
            return
        }
        if let object = try? [String: JSONValue](from: decoder) {
            self = .object(object)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    var deltaString: String? {
        if case let .object(values) = self, case let .string(delta)? = values["delta"] {
            return delta
        }
        return nil
    }

    var hasDelta: Bool {
        deltaString != nil
    }
}

@MainActor
final class FleetWorkbenchStore: ObservableObject {
    @Published var managerURL: String {
        didSet { persistPreferences() }
    }
    @Published var token: String {
        didSet { persistPreferences() }
    }
    @Published var profile: String {
        didSet { persistPreferences() }
    }
    @Published var channel: String {
        didSet { persistPreferences() }
    }
    @Published var chatID: String {
        didSet { persistPreferences() }
    }
    @Published var ownerChatID: String {
        didSet { persistPreferences() }
    }
    @Published var projectAlias: String {
        didSet { persistPreferences() }
    }
    @Published var projectPath: String {
        didSet { persistPreferences() }
    }
    @Published var endpointID: String {
        didSet { persistPreferences() }
    }
    @Published var sessionSelector: String {
        didSet { persistPreferences() }
    }
    @Published var sessionPolicy: String {
        didSet { persistPreferences() }
    }
    @Published var projectMode: String {
        didSet { persistPreferences() }
    }
    @Published var model: String {
        didSet { persistPreferences() }
    }
    @Published var reasoningEffort: String {
        didSet { persistPreferences() }
    }
    @Published var prompt: String {
        didSet { persistPreferences() }
    }
    @Published var statusText = "未连接"
    @Published var summaryText = "等待刷新"
    @Published var endpoints: [FleetEndpoint] = []
    @Published var projects: [FleetProject] = []
    @Published var sessions: [FleetSession] = []
    @Published var tasks: [FleetTask] = []
    @Published var bindings: [FleetChatBinding] = []
    @Published var mappings: [FleetSessionMapping] = []
    @Published var recentEvents: [FleetEvent] = []
    @Published var sessionEvents: [FleetEvent] = []
    @Published var sessionEventSessionID: String?
    @Published var codexMessages: [FleetCodexMessage] = []
    @Published var codexMessageStates: [String: FleetCodexMessageState] = [:]
    @Published var localPendingMessages: [FleetCodexMessage] = []
    @Published var codexMessageSessionID: String?
    @Published var historyCodexMessagesBySession: [String: [FleetCodexMessage]] = [:]
    @Published var historySessionSummaries: [String: String] = [:]
    @Published var isV1Runtime = false
    @Published var isLoadingSessionEvents = false
    @Published var activeTask: FleetTask?
    @Published var streamingTaskID: String?
    @Published var streamStatusText = "未连接流式通道"
    @Published var thinkingTranscript = ""
    @Published var outputTranscript = ""
    @Published var isRefreshing = false
    @Published var banner: String?

    private let defaults = UserDefaults.standard
    private let baseDefaultsKey = "MKB.FleetWorkbench."
    private let defaultManagerURL = "http://124.174.101.22:886"
    private let retiredPublicManagerURL = "http://124.174.101.22"
    private let retiredDebugManagerURL = "http://127.0.0.1:18886"
    private let retiredLocalManagerURL = "http://127.0.0.1:18992"
    private let retiredBridgeManagerURL = "http://100.106.225.53:18992"
    private let launchFixedCodexSessionID: String
    private let launchFixedCodexSessionTitle: String
    private let useCodexFixtureForUITests: Bool
    private let disableHistoryLoadForUITests: Bool
    private var didBoot = false
    private var streamCursor = 0
    private var eventStreamTask: Swift.Task<Void, Never>?
    private var loadingV1MessageKey: String?
    private var loadingHistorySummaryIDs = Set<String>()
    private var loadedHistorySessionKeys = Set<String>()
    private var fixtureCommandID = 100
    private var fixtureNextMessageSeq = 10_000

    init() {
        let launchSessionID = Self.launchArgumentValue("-MKBCodexFixedSessionID")
        let launchSessionTitle = Self.launchArgumentValue("-MKBCodexFixedSessionTitle")
        useCodexFixtureForUITests = ProcessInfo.processInfo.arguments.contains("-MKBUseCodexFixtureForUITests")
        disableHistoryLoadForUITests = ProcessInfo.processInfo.arguments.contains("-MKBDisableHistoryLoadForUITests")
        let savedManagerURL = defaults.string(forKey: baseDefaultsKey + "managerURL") ?? defaultManagerURL
        let normalizedManagerURL = savedManagerURL == retiredBridgeManagerURL ||
            savedManagerURL == retiredLocalManagerURL ||
            savedManagerURL == retiredDebugManagerURL ||
            savedManagerURL == retiredPublicManagerURL ? defaultManagerURL : savedManagerURL
        managerURL = normalizedManagerURL
        token = defaults.string(forKey: baseDefaultsKey + "token") ?? ""
        profile = defaults.string(forKey: baseDefaultsKey + "profile") ?? "home-codex"
        channel = defaults.string(forKey: baseDefaultsKey + "channel") ?? "mkb"
        chatID = defaults.string(forKey: baseDefaultsKey + "chatID") ?? "mkb-ios"
        ownerChatID = defaults.string(forKey: baseDefaultsKey + "ownerChatID") ?? "mkb-ios"
        projectAlias = defaults.string(forKey: baseDefaultsKey + "projectAlias") ?? "codex-database"
        projectPath = defaults.string(forKey: baseDefaultsKey + "projectPath") ?? ""
        endpointID = defaults.string(forKey: baseDefaultsKey + "endpointID") ?? "company-main"
        let resetForUITests = ProcessInfo.processInfo.arguments.contains("-MKBResetCodexPromptForUITests")
        launchFixedCodexSessionID = launchSessionID
        launchFixedCodexSessionTitle = launchSessionTitle
        let hasLaunchFixedSession = !launchSessionID.isEmpty || !launchSessionTitle.isEmpty
        sessionSelector = launchSessionID.isEmpty ? (resetForUITests ? "" : defaults.string(forKey: baseDefaultsKey + "sessionSelector") ?? "") : launchSessionID
        sessionPolicy = hasLaunchFixedSession ? "fixed-session" : (resetForUITests ? "project-default" : defaults.string(forKey: baseDefaultsKey + "sessionPolicy") ?? "project-default")
        projectMode = defaults.string(forKey: baseDefaultsKey + "projectMode") ?? "vscode"
        let savedModel = defaults.string(forKey: baseDefaultsKey + "model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model = savedModel.isEmpty ? "gpt-5.4" : savedModel
        let savedReasoningEffort = defaults.string(forKey: baseDefaultsKey + "reasoningEffort")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reasoningEffort = savedReasoningEffort.isEmpty ? "medium" : savedReasoningEffort
        if resetForUITests {
            defaults.removeObject(forKey: baseDefaultsKey + "prompt")
            defaults.removeObject(forKey: baseDefaultsKey + "sessionSelector")
            defaults.removeObject(forKey: baseDefaultsKey + "sessionPolicy")
            if useCodexFixtureForUITests {
                defaults.removeObject(forKey: baseDefaultsKey + "endpointID")
                endpointID = "quectel-lnx"
            }
            prompt = ""
        } else {
            prompt = defaults.string(forKey: baseDefaultsKey + "prompt") ?? ""
        }
        didBoot = true
        Swift.Task {
            await self.refreshState(forceSessionEvents: true)
        }
    }

    private static func launchArgumentValue(_ name: String) -> String {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: name) {
            let next = arguments.index(after: index)
            if arguments.indices.contains(next) {
                return arguments[next].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let prefix = "\(name)="
        if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func refresh() {
        Task {
            await refreshState(forceSessionEvents: true)
        }
    }

    func refreshState(forceSessionEvents: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if useCodexFixtureForUITests {
            applyFixtureState(forceSessionEvents: forceSessionEvents)
            return
        }
        if await refreshV1Runtime(forceSessionEvents: forceSessionEvents) {
            return
        }
        do {
            isV1Runtime = false
            let stateValue = try await request(FleetStateResponse.self, path: "/api/state")
            let summaryValue = try await request(FleetSummaryResponse.self, path: "/api/summary?profile=\(profile.escapedQuery)&limit=10")
            let chatStatus = try await request(FleetChatStatus.self, path: "/api/chat-bindings?channel=\(channel.escapedQuery)&chat_id=\(chatID.escapedQuery)")
            let mappingValue = try await request(FleetSessionChatsResponse.self, path: "/api/session-chats?channel=\(channel.escapedQuery)&owner_chat_id=\(ownerChatID.escapedQuery)&limit=50")

            endpoints = stateValue.endpoints
            projects = stateValue.projects
            sessions = stateValue.sessions
            tasks = stateValue.tasks
            bindings = chatStatus.binding.map { [$0] } ?? []
            activeTask = chatStatus.active_task
            if let activeID = activeTask?.task_id, !activeID.isEmpty {
                recentEvents = (try? await request(FleetEventsResponse.self, path: "/api/events?target=\(activeID.escapedQuery)&tail=12"))?.events ?? []
            } else {
                recentEvents = []
            }
            mappings = mappingValue.mappings
            summaryText = "活动 \(summaryValue.counts.active) · 会话 \(summaryValue.counts.sessions) · 最近 \(summaryValue.counts.recent)"
            statusText = chatStatus.binding == nil ? "未绑定" : "已绑定到 \(chatStatus.binding?.project_alias ?? "-")"
            let selectedSessionID = chatStatus.binding?.session_id ?? sessionSelector
            if !selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               forceSessionEvents || sessionEventSessionID != selectedSessionID || sessionEvents.isEmpty {
                await loadSessionEvents(sessionID: selectedSessionID)
            }
            if activeTask == nil, let last = stateValue.tasks.first {
                activeTask = last.isActive ? last : nil
            }
            if let activeTask, activeTask.isActive {
                startEventStream(taskID: activeTask.task_id)
            } else {
                settleIdleStreamState(sessionID: selectedSessionID)
            }
        } catch {
            statusText = "连接失败"
            streamStatusText = "流式通道未连接"
        }
    }

    private func applyFixtureState(forceSessionEvents: Bool = false) {
        isV1Runtime = true
        endpoints = [
            FleetEndpoint(endpoint_id: "quectel-lnx", label: "quectel-lnx", status: "online", capabilities: nil, last_seen_at: "2026-06-23T10:02:00Z", created_at: nil, updated_at: "2026-06-23T10:02:00Z"),
            FleetEndpoint(endpoint_id: "lab-vscode", label: "lab-vscode", status: "online", capabilities: nil, last_seen_at: "2026-06-23T10:01:00Z", created_at: nil, updated_at: "2026-06-23T10:01:00Z")
        ]
        projects = [
            FleetProject(alias: "vscodex", endpoint_id: "quectel-lnx", path: "/home/donovan/work", mode: "vscode", created_at: nil, updated_at: "2026-06-23T10:02:00Z"),
            FleetProject(alias: "vscodex", endpoint_id: "lab-vscode", path: "/workspace", mode: "vscode", created_at: nil, updated_at: "2026-06-23T10:01:00Z")
        ]
        sessions = fixtureSessions()
        tasks = []
        bindings = []
        mappings = []
        recentEvents = []
        activeTask = nil
        let fixtureRuntimeSessions = sessions
            .filter { $0.isCodexRuntimeCandidate }
            .sorted(by: codexSessionPrecedes)
        if let launchSession = launchFixedCodexSession(from: fixtureRuntimeSessions) {
            applyRuntimeSession(launchSession)
            sessionPolicy = "fixed-session"
        } else if hasLaunchFixedCodexSessionTarget {
            sessionPolicy = "fixed-session"
        }
        let selectedEndpoint = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedEndpoint.isEmpty || !endpoints.contains(where: { $0.endpoint_id == selectedEndpoint }) {
            endpointID = "quectel-lnx"
        }
        let endpointSessions = sessions
            .filter { $0.endpoint_id == endpointID && $0.isCodexRuntimeCandidate }
            .sorted(by: codexSessionPrecedes)
        let selectedSession = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedSession.isEmpty || !endpointSessions.contains(where: { $0.session_id == selectedSession }) {
            if let first = endpointSessions.first {
                applyRuntimeSession(first)
            }
        }
        if codexMessages.isEmpty || forceSessionEvents {
            codexMessages = fixtureMessages()
            historyCodexMessagesBySession = Dictionary(grouping: fixtureMessages(), by: \.session_id)
        }
        if codexMessageSessionID == nil {
            codexMessageSessionID = sessionSelector
        }
        statusText = "已连接"
        summaryText = "源 \(endpoints.count) · 会话 \(sessions.count) · 消息 \(codexMessages.count)"
        streamStatusText = hasRunningCodexMessage(in: sessionSelector) ? "Codex 正在输出" : "当前会话 \(sessionSelector)"
        streamingTaskID = hasRunningCodexMessage(in: sessionSelector) ? sessionSelector : nil
    }

    private func fixtureSessions() -> [FleetSession] {
        [
            FleetSession(session_id: "fixture-current", endpoint_id: "quectel-lnx", source: "vscode-codex", title: "当前公司 Codex 对话", cwd: "/home/donovan/work", rollout_path: nil, status: "running", thread_id: "fixture-current-thread", active_turn_id: "fixture-turn-current", updated_at: "2026-06-23T10:03:00Z"),
            FleetSession(session_id: "fixture-test", endpoint_id: "quectel-lnx", source: "codex-vscode", title: "Test", cwd: "/home/donovan/work", rollout_path: nil, status: "synced", thread_id: "fixture-test-thread", active_turn_id: nil, updated_at: "2026-06-23T10:02:00Z"),
            FleetSession(session_id: "fixture-adb", endpoint_id: "quectel-lnx", source: "codex-vscode", title: "检查 ADB 设备连接", cwd: "/home/donovan/work", rollout_path: nil, status: "synced", thread_id: "fixture-adb-thread", active_turn_id: nil, updated_at: "2026-06-23T09:58:00Z"),
            FleetSession(session_id: "fixture-gerrit", endpoint_id: "quectel-lnx", source: "codex-vscode", title: "查找 Gerrit 密钥", cwd: "/home/donovan/work", rollout_path: nil, status: "synced", thread_id: "fixture-gerrit-thread", active_turn_id: nil, updated_at: "2026-06-23T09:55:00Z"),
            FleetSession(session_id: "fixture-lab-test", endpoint_id: "lab-vscode", source: "codex-vscode", title: "Lab Test", cwd: "/workspace", rollout_path: nil, status: "synced", thread_id: "fixture-lab-thread", active_turn_id: nil, updated_at: "2026-06-23T09:57:00Z")
        ]
    }

    private func fixtureMessages() -> [FleetCodexMessage] {
        [
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-current", message_id: "fixture-current-user", turn_id: "fixture-current-turn", seq: 1, role: "user", text: "查看当前修改影响", status: "completed", updated_at: "2026-06-23T10:03:00Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-current", message_id: "fixture-current-assistant", turn_id: "fixture-current-turn", seq: 2, role: "assistant", text: "当前修改集中在公司 Codex 移动端 UI 与同步流程。", status: "completed", updated_at: "2026-06-23T10:03:10Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-test", message_id: "fixture-test-user-1", turn_id: "fixture-test-turn-1", seq: 1, role: "user", text: "Test", status: "completed", updated_at: "2026-06-23T10:02:00Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-test", message_id: "fixture-test-assistant-1", turn_id: "fixture-test-turn-1", seq: 2, role: "assistant", text: "Test 会话已载入，可以继续发送、接收、引导和中断。", status: "completed", updated_at: "2026-06-23T10:02:10Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-test", message_id: "fixture-test-raw-event", turn_id: "fixture-test-turn-raw", seq: 3, role: "assistant", text: "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"error\",\"message\":\"[features].codex_hooks is deprecated\"}}", status: "failed", updated_at: "2026-06-23T10:02:12Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-adb", message_id: "fixture-adb-user", turn_id: "fixture-adb-turn", seq: 1, role: "user", text: "检查 ADB 设备连接", status: "completed", updated_at: "2026-06-23T09:58:00Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-adb", message_id: "fixture-adb-assistant", turn_id: "fixture-adb-turn", seq: 2, role: "assistant", text: "已确认设备列表可以刷新。", status: "completed", updated_at: "2026-06-23T09:58:30Z"),
            FleetCodexMessage(endpoint_id: "quectel-lnx", session_id: "fixture-gerrit", message_id: "fixture-gerrit-user", turn_id: "fixture-gerrit-turn", seq: 1, role: "user", text: "查找 Gerrit 密钥", status: "completed", updated_at: "2026-06-23T09:55:00Z"),
            FleetCodexMessage(endpoint_id: "lab-vscode", session_id: "fixture-lab-test", message_id: "fixture-lab-user", turn_id: "fixture-lab-turn", seq: 1, role: "user", text: "Lab Test", status: "completed", updated_at: "2026-06-23T09:57:00Z")
        ]
    }

    private func refreshV1Runtime(forceSessionEvents: Bool = false) async -> Bool {
        do {
            let stateValue = try await request(FleetV1StateResponse.self, path: "/v1/state")
            isV1Runtime = true
            endpoints = stateValue.endpoints
            sessions = stateValue.sessions
            projects = projects.filter { project in
                stateValue.endpoints.contains(where: { $0.endpoint_id == project.endpoint_id })
            }
            tasks = []
            bindings = []
            mappings = []
            recentEvents = []
            activeTask = nil

            let runtimeSessions = stateValue.sessions
                .filter(isCodexRuntimeSession)
                .sorted(by: codexSessionPrecedes)
            if endpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                endpointID = runtimeSessions.first?.endpoint_id ?? stateValue.endpoints.first?.endpoint_id ?? stateValue.sessions.first?.endpoint_id ?? endpointID
            }
            if !stateValue.endpoints.contains(where: { $0.endpoint_id == endpointID }),
                      let firstEndpoint = runtimeSessions.first?.endpoint_id ?? stateValue.endpoints.first?.endpoint_id ?? stateValue.sessions.first?.endpoint_id {
                endpointID = firstEndpoint
            }
            if let launchSession = launchFixedCodexSession(from: runtimeSessions) {
                applyRuntimeSession(launchSession)
                sessionPolicy = "fixed-session"
            } else if hasLaunchFixedCodexSessionTarget {
                sessionPolicy = "fixed-session"
                streamStatusText = "未找到会话 \(launchFixedCodexSessionLabel)"
            } else if sessionPolicy == "fixed-session" {
                let selectedSessionID = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
                if let selectedSession = runtimeSessions.first(where: { $0.session_id == selectedSessionID }),
                   !selectedSession.isRelayPlaceholder {
                    applyRuntimeSession(selectedSession)
                }
            } else if let preferredSession = currentRuntimeSession(endpointID: endpointID, from: runtimeSessions) {
                applyRuntimeSession(preferredSession)
            }

            if hasLaunchFixedCodexSessionTarget,
               Self.isCurrentBridgeSessionID(sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)) {
                statusText = "已连接"
                summaryText = "源 \(stateValue.endpoints.count) · 会话 \(stateValue.sessions.count) · 消息 \(stateValue.message_count ?? codexMessages.count)"
                streamStatusText = "拒绝使用当前桥接会话"
                streamingTaskID = nil
                return true
            }

            if hasLaunchFixedCodexSessionTarget,
               launchFixedCodexSession(from: runtimeSessions) == nil {
                statusText = "已连接"
                summaryText = "源 \(stateValue.endpoints.count) · 会话 \(stateValue.sessions.count) · 消息 \(stateValue.message_count ?? codexMessages.count)"
                streamingTaskID = nil
                return true
            }
            let selectedSessionID = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedSessionID.isEmpty {
                if codexMessageSessionID != selectedSessionID {
                    codexMessages = []
                    codexMessageStates = [:]
                    localPendingMessages = localPendingMessages.filter { $0.session_id == selectedSessionID }
                    codexMessageSessionID = selectedSessionID
                }
                let selectedEndpointID = endpointID
                let shouldRefreshMessages = codexMessages.isEmpty || forceSessionEvents
                if shouldRefreshMessages {
                    Swift.Task { [weak self] in
                        await self?.loadV1Messages(
                            endpointID: selectedEndpointID,
                            sessionID: selectedSessionID,
                            requestHistoryLoad: !FleetWorkbenchStore.isCurrentBridgeSessionID(selectedSessionID)
                        )
                    }
                }
            }

            let runningCount = codexMessageStates.values.filter { ["streaming", "running", "queued"].contains($0.status) }.count
            statusText = "已连接"
            summaryText = "源 \(stateValue.endpoints.count) · 会话 \(stateValue.sessions.count) · 消息 \(stateValue.message_count ?? codexMessages.count)"
            streamStatusText = runningCount > 0 ? "Codex 正在输出" : (selectedSessionID.isEmpty ? "无运行任务" : "当前会话 \(selectedSessionID)")
            streamingTaskID = runningCount > 0 ? selectedSessionID : nil
            return true
        } catch {
            return false
        }
    }

    func registerProject() {
        Task {
            do {
                let _: FleetProject = try await request(
                    FleetProject.self,
                    path: "/api/projects",
                    method: "POST",
                    body: AnyEncodable(FleetProjectRequest(alias: projectAlias, endpoint_id: endpointID, path: projectPath, mode: projectMode))
                )
                banner = "项目已登记"
                await refreshState()
            } catch {
                banner = "登记失败：\(error.localizedDescription)"
            }
        }
    }

    func useProject() {
        Task {
            do {
                let _: FleetSummaryResponse.ContextRow = try await request(
                    FleetSummaryResponse.ContextRow.self,
                    path: "/api/context/project",
                    method: "POST",
                    body: AnyEncodable(FleetUseProjectRequest(profile: profile, project_alias: projectAlias))
                )
                banner = "已切换到项目 \(projectAlias)"
                await refreshState()
            } catch {
                banner = "切换项目失败：\(error.localizedDescription)"
            }
        }
    }

    func useSession() {
        Task {
            do {
                let _: FleetSummaryResponse.ContextRow = try await request(
                    FleetSummaryResponse.ContextRow.self,
                    path: "/api/context/session",
                    method: "POST",
                    body: AnyEncodable(FleetUseSessionRequest(profile: profile, session_selector: sessionSelector))
                )
                banner = "已切换到会话 \(sessionSelector)"
                await refreshState()
            } catch {
                banner = "切换会话失败：\(error.localizedDescription)"
            }
        }
    }

    func selectSession(_ sessionID: String) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionSelector = trimmed
        sessionPolicy = "fixed-session"
        if isV1Runtime {
            if let session = sessions.first(where: { $0.session_id == trimmed }) {
                endpointID = session.endpoint_id
            }
            codexMessages = []
            localPendingMessages = localPendingMessages.filter { $0.session_id == trimmed }
            codexMessageStates = [:]
            streamStatusText = "已切换到会话 \(trimmed)"
            Task {
                await loadV1Messages(endpointID: endpointID, sessionID: trimmed)
            }
            return
        }
        Task {
            do {
                let _: FleetSummaryResponse.ContextRow = try await request(
                    FleetSummaryResponse.ContextRow.self,
                    path: "/api/context/session",
                    method: "POST",
                    body: AnyEncodable(FleetUseSessionRequest(profile: profile, session_selector: trimmed))
                )
                let _: FleetChatBinding = try await request(
                    FleetChatBinding.self,
                    path: "/api/chat-bindings",
                    method: "POST",
                    body: AnyEncodable(FleetBindChatRequest(channel: channel, chat_id: chatID, profile: profile, project_alias: projectAlias, endpoint_id: endpointID, session_policy: "fixed-session"))
                )
                await refreshState()
            } catch {
                banner = "进入会话失败：\(error.localizedDescription)"
            }
        }
    }

    func clearTarget() {
        Task {
            do {
                let _: FleetSummaryResponse.ContextRow = try await request(
                    FleetSummaryResponse.ContextRow.self,
                    path: "/api/context/clear",
                    method: "POST",
                    body: AnyEncodable(FleetClearTargetRequest(profile: profile))
                )
                banner = "已清空项目/会话目标"
                await refreshState()
            } catch {
                banner = "清空失败：\(error.localizedDescription)"
            }
        }
    }

    func bindChat() {
        Task {
            do {
                let policy = sessionPolicy == "fixed-session" || !sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "fixed-session" : "project-default"
                let _: FleetChatBinding = try await request(
                    FleetChatBinding.self,
                    path: "/api/chat-bindings",
                    method: "POST",
                    body: AnyEncodable(FleetBindChatRequest(channel: channel, chat_id: chatID, profile: profile, project_alias: projectAlias, endpoint_id: endpointID, session_policy: policy))
                )
                banner = "已绑定聊天入口"
                await refreshState()
            } catch {
                banner = "绑定失败：\(error.localizedDescription)"
            }
        }
    }

    func unbindChat() {
        Task {
            do {
                let _: FleetSummaryResponse.ContextRow = try await request(
                    FleetSummaryResponse.ContextRow.self,
                    path: "/api/chat-bindings/clear",
                    method: "POST",
                    body: AnyEncodable(FleetUnbindChatRequest(channel: channel, chat_id: chatID))
                )
                banner = "已解除绑定"
                await refreshState()
            } catch {
                banner = "解绑失败：\(error.localizedDescription)"
            }
        }
    }

    func syncSessionChats() {
        Task {
            do {
                let _: JSONValue = try await request(
                    JSONValue.self,
                    path: "/api/session-chats/sync",
                    method: "POST",
                    body: AnyEncodable(FleetSessionSyncRequest(channel: channel, owner_chat_id: ownerChatID, profile: profile, endpoint_id: endpointID, project_alias: projectAlias, limit: 50))
                )
                banner = "已同步会话映射"
                await refreshState()
            } catch {
                banner = "同步失败：\(error.localizedDescription)"
            }
        }
    }

    func loadSessionEvents(sessionID: String) async {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isV1Runtime {
            let sessionEndpointID = sessions.first(where: { $0.session_id == trimmed })?.endpoint_id
            await loadV1Messages(endpointID: sessionEndpointID ?? endpointID, sessionID: trimmed)
            return
        }
        isLoadingSessionEvents = true
        defer { isLoadingSessionEvents = false }
        do {
            let events = try await request(FleetEventsResponse.self, path: "/api/events?target=\(trimmed.escapedQuery)&tail=400")
            sessionEventSessionID = trimmed
            sessionEvents = events.events
        } catch {
            banner = "加载会话失败：\(error.localizedDescription)"
        }
    }

    private func fetchV1Messages(endpointID targetEndpointID: String, sessionID: String, requestHistoryLoad: Bool) async throws -> (String, [FleetCodexMessage]) {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedEndpointID = targetEndpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpointID.isEmpty,
           let sessionEndpointID = sessions.first(where: { $0.session_id == trimmedSessionID })?.endpoint_id {
            trimmedEndpointID = sessionEndpointID
        }
        let historyKey = "\(trimmedEndpointID)|\(trimmedSessionID)"
        let isCurrentBridge = Self.isCurrentBridgeSessionID(trimmedSessionID)
        if requestHistoryLoad && !disableHistoryLoadForUITests && !isCurrentBridge && !trimmedEndpointID.isEmpty && !loadedHistorySessionKeys.contains(historyKey) {
            let _: JSONValue? = try? await request(
                JSONValue.self,
                path: "/api/history/load",
                method: "POST",
                body: AnyEncodable(FleetHistoryLoadRequest(endpoint_id: trimmedEndpointID, session_id: trimmedSessionID))
            )
            loadedHistorySessionKeys.insert(historyKey)
        }
        var messagesValue = try await request(
            FleetCodexMessagesResponse.self,
            path: "/v1/messages?endpoint_id=\(trimmedEndpointID.escapedQuery)&session_id=\(trimmedSessionID.escapedQuery)&after_seq=0"
        )
        if messagesValue.messages.isEmpty {
            for _ in 0..<8 {
                try await Swift.Task.sleep(nanoseconds: 900_000_000)
                let retryValue = try await request(
                    FleetCodexMessagesResponse.self,
                    path: "/v1/messages?endpoint_id=\(trimmedEndpointID.escapedQuery)&session_id=\(trimmedSessionID.escapedQuery)&after_seq=0"
                )
                if !retryValue.messages.isEmpty {
                    messagesValue = retryValue
                    break
                }
            }
        }
        let orderedMessages = messagesValue.messages.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.message_id < rhs.message_id
        }
        return (trimmedEndpointID, orderedMessages)
    }

    func loadV1Messages(endpointID targetEndpointID: String, sessionID: String, requestHistoryLoad: Bool = true) async {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return }
        if useCodexFixtureForUITests {
            codexMessageSessionID = trimmedSessionID
            codexMessages = (historyCodexMessagesBySession[trimmedSessionID] ?? fixtureMessages().filter { $0.session_id == trimmedSessionID })
            await loadV1MessageStates(endpointID: targetEndpointID, sessionID: trimmedSessionID)
            return
        }
        let trimmedEndpointID = targetEndpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadKey = "\(trimmedEndpointID)|\(trimmedSessionID)"
        if loadingV1MessageKey == loadKey { return }
        loadingV1MessageKey = loadKey
        isLoadingSessionEvents = true
        defer {
            if loadingV1MessageKey == loadKey {
                loadingV1MessageKey = nil
            }
            isLoadingSessionEvents = false
        }
        do {
            let (trimmedEndpointID, orderedMessages) = try await fetchV1Messages(endpointID: targetEndpointID, sessionID: trimmedSessionID, requestHistoryLoad: requestHistoryLoad)
            codexMessageSessionID = trimmedSessionID
            codexMessages = orderedMessages
            localPendingMessages.removeAll { pending in
                codexMessages.contains { synced in
                    synced.session_id == pending.session_id &&
                    synced.role == pending.role &&
                    synced.text.trimmingCharacters(in: .whitespacesAndNewlines) == pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            await loadV1MessageStates(endpointID: trimmedEndpointID, sessionID: trimmedSessionID)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            banner = "加载历史失败：\(error.localizedDescription)"
        }
    }

    func loadHistoryV1Messages(endpointID targetEndpointID: String, sessionID: String, requestHistoryLoad: Bool = true) async {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return }
        if useCodexFixtureForUITests {
            var nextMessages = historyCodexMessagesBySession
            nextMessages[trimmedSessionID] = fixtureAllMessages(for: trimmedSessionID)
            historyCodexMessagesBySession = nextMessages
            return
        }
        isLoadingSessionEvents = true
        defer { isLoadingSessionEvents = false }
        do {
            let (_, orderedMessages) = try await fetchV1Messages(endpointID: targetEndpointID, sessionID: trimmedSessionID, requestHistoryLoad: requestHistoryLoad)
            var nextMessages = historyCodexMessagesBySession
            nextMessages[trimmedSessionID] = orderedMessages
            historyCodexMessagesBySession = nextMessages
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            banner = "加载历史失败：\(error.localizedDescription)"
        }
    }

    func loadHistorySummaries(for sessions: [FleetSession]) async {
        guard isV1Runtime else { return }
        for session in sessions.prefix(50) {
            let sessionID = session.session_id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionID.isEmpty, historySessionSummaries[sessionID] == nil else { continue }
            var nextSummaries = historySessionSummaries
            nextSummaries[sessionID] = ""
            historySessionSummaries = nextSummaries
        }
    }

    private static func semanticSummary(from messages: [FleetCodexMessage]) -> String? {
        let candidates = messages
            .sorted { lhs, rhs in
                if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
                return lhs.message_id < rhs.message_id
            }
            .filter(\.isUser)
            .map(\.text)

        for candidate in candidates {
            if let summary = semanticSummary(from: candidate) {
                return summary
            }
        }
        return nil
    }

    private static func semanticSummary(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let ignoredPrefixes = [
            "<environment_context>",
            "</environment_context>",
            "# AGENTS.md instructions",
            "memory hits:",
            "memory writes:",
            "skipped memory candidates:",
            "Current date:",
            "You are"
        ]

        for line in lines {
            let normalized = line.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*` “”。，,.:：;；"))
            guard !normalized.isEmpty else { continue }
            if ignoredPrefixes.contains(where: { normalized.localizedCaseInsensitiveContains($0) }) {
                continue
            }
            if normalized.hasPrefix("/") || normalized.hasPrefix("{") || normalized.hasPrefix("[") {
                continue
            }
            if normalized.count < 3 {
                continue
            }
            var candidate = normalized
            if let range = candidate.range(of: "判断") {
                candidate = String(candidate[range.lowerBound...])
            }
            return candidate.shortFleetSummary(maxCharacters: 28)
        }
        return nil
    }

    func loadV1MessageStates(endpointID targetEndpointID: String, sessionID: String) async {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return }
        if useCodexFixtureForUITests {
            streamStatusText = hasRunningCodexMessage(in: trimmedSessionID) ? "Codex 正在输出" : "当前会话 \(trimmedSessionID)"
            streamingTaskID = hasRunningCodexMessage(in: trimmedSessionID) ? trimmedSessionID : nil
            return
        }
        let trimmedEndpointID = targetEndpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let statesValue = try await request(
                FleetCodexMessageStatesResponse.self,
                path: "/v1/message_states?endpoint_id=\(trimmedEndpointID.escapedQuery)&session_id=\(trimmedSessionID.escapedQuery)"
            )
            codexMessageStates = Dictionary(uniqueKeysWithValues: statesValue.states.map { ($0.message_id, $0) })
            if statesValue.states.contains(where: { ["streaming", "running", "queued"].contains($0.status) }) {
                streamStatusText = "Codex 正在输出"
                streamingTaskID = trimmedSessionID
            } else {
                streamingTaskID = nil
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            banner = "加载状态失败：\(error.localizedDescription)"
        }
    }

    func sendPrompt(inserted: Bool = false) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if useCodexFixtureForUITests {
            sendFixturePrompt(trimmed, inserted: inserted)
            return
        }
        Task {
            do {
                if isV1Runtime {
                    try await sendV1Prompt(trimmed, inserted: inserted)
                    return
                }
                let mode = inserted ? "insert" : projectMode
                let task: FleetTask
                if bindingForCurrentChat != nil {
                    task = try await request(
                        FleetTask.self,
                        path: "/api/chat-bindings/task",
                        method: "POST",
                        body: AnyEncodable(FleetChatTaskRequest(channel: channel, chat_id: chatID, prompt: trimmed, mode: mode, model: taskModel, reasoning_effort: taskReasoningEffort))
                    )
                } else {
                    task = try await request(
                        FleetTask.self,
                        path: "/api/tasks",
                        method: "POST",
                        body: AnyEncodable(FleetTaskRequest(profile: profile, prompt: trimmed, project_alias: projectAlias.isEmpty ? nil : projectAlias, session_selector: sessionSelector.isEmpty ? nil : sessionSelector, mode: mode, model: taskModel, reasoning_effort: taskReasoningEffort))
                    )
                }
                prompt = ""
                activeTask = task
                resetStream(for: task.task_id)
                startEventStream(taskID: task.task_id)
                banner = nil
                await refreshState()
            } catch {
                banner = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    func insertPrompt() {
        sendPrompt(inserted: true)
    }

    func newConversation() {
        if useCodexFixtureForUITests {
            createFixtureConversation()
            return
        }
        Task {
            do {
                if isV1Runtime {
                    try await sendV1Command(type: "conversation.new", text: "")
                    codexMessages = []
                    localPendingMessages = []
                    streamStatusText = "已请求新对话"
                    banner = nil
                    await refreshState(forceSessionEvents: true)
                    return
                }
                let session: FleetSession = try await request(
                    FleetSession.self,
                    path: "/api/conversations",
                    method: "POST",
                    body: AnyEncodable(FleetNewConversationRequest(profile: profile, endpoint_id: endpointID, project_alias: projectAlias, title: nil))
                )
                sessionSelector = session.session_id
                streamStatusText = "已新开对话 \(session.session_id)"
                thinkingTranscript = ""
                outputTranscript = ""
                banner = "已新开 Codex 对话"
                await refreshState()
            } catch {
                banner = "新开对话失败：\(error.localizedDescription)"
            }
        }
    }

    func stopCurrent() {
        if useCodexFixtureForUITests {
            stopFixtureCurrent()
            return
        }
        Task {
            do {
                if isV1Runtime {
                    try await sendV1Command(type: "turn.interrupt", text: "")
                    streamStatusText = "已请求打断"
                    await refreshState()
                    return
                }
                if bindingForCurrentChat != nil {
                    let _: JSONValue = try await request(
                        JSONValue.self,
                        path: "/api/chat-bindings/stop",
                        method: "POST",
                        body: AnyEncodable(FleetUnbindChatRequest(channel: channel, chat_id: chatID))
                    )
                } else if let current = activeTask?.task_id {
                    let _: JSONValue = try await request(
                        JSONValue.self,
                        path: "/api/stop",
                        method: "POST",
                        body: AnyEncodable(FleetStopRequest(target: current))
                    )
                }
                banner = "已发送停止命令"
                streamStatusText = "已请求打断"
                await refreshState()
            } catch {
                banner = "停止失败：\(error.localizedDescription)"
            }
        }
    }

    private func sendV1Prompt(_ text: String, inserted: Bool) async throws {
        let commandType = inserted ? "turn.steer" : "turn.send"
        let command = try await sendV1Command(type: commandType, text: text)
        let sessionID = command.session_id.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = command.endpoint_id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty {
            endpointID = endpoint
        }
        if !sessionID.isEmpty {
            sessionSelector = sessionID
        }
        let nextSeq = max((codexMessages.map(\.seq).max() ?? 0) + 1, 1_000_000 + command.command_id)
        let pending = FleetCodexMessage(
            endpoint_id: endpoint,
            session_id: sessionID,
            message_id: "local-user-\(command.command_id)",
            turn_id: "local-command-\(command.command_id)",
            seq: nextSeq,
            role: "user",
            text: text,
            status: "queued",
            updated_at: nil
        )
        localPendingMessages.append(pending)
        prompt = ""
        streamStatusText = inserted ? "已引导当前任务" : "消息已发送"
        banner = nil
        await refreshState()
        pollV1SessionUntilIdle(endpointID: endpoint, sessionID: sessionID)
    }

    private func pollV1SessionUntilIdle(endpointID: String, sessionID: String) {
        Task {
            for _ in 0..<300 {
                await loadV1Messages(endpointID: endpointID, sessionID: sessionID, requestHistoryLoad: false)
                if !hasRunningCodexMessage(in: sessionID) { break }
                try? await Swift.Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func sendFixturePrompt(_ text: String, inserted: Bool) {
        if codexMessages.isEmpty {
            applyFixtureState(forceSessionEvents: true)
        }
        let sessionID = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "fixture-test" : sessionSelector
        let endpoint = endpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "quectel-lnx" : endpointID
        if sessionSelector != sessionID { sessionSelector = sessionID }
        if endpointID != endpoint { endpointID = endpoint }
        fixtureCommandID += 1
        fixtureNextMessageSeq += 1
        let turnID = "fixture-command-\(fixtureCommandID)"
        let userMessage = FleetCodexMessage(
            endpoint_id: endpoint,
            session_id: sessionID,
            message_id: "fixture-user-\(fixtureCommandID)",
            turn_id: turnID,
            seq: fixtureNextMessageSeq,
            role: "user",
            text: text,
            status: "completed",
            updated_at: "2026-06-23T10:04:00Z"
        )
        appendFixtureMessage(userMessage)
        prompt = ""

        if inserted {
            completeFixtureRunningMessages(sessionID: sessionID)
            appendFixtureAssistantMessage(
                "已收到引导：\(text)",
                endpointID: endpoint,
                sessionID: sessionID,
                turnID: turnID,
                status: "completed"
            )
            streamStatusText = "已引导当前任务"
            streamingTaskID = nil
            return
        }

        let shouldStayRunning = text.localizedCaseInsensitiveContains("long") ||
            text.localizedCaseInsensitiveContains("keep the turn active") ||
            text.localizedCaseInsensitiveContains("等待引导")
        let reply = fixtureReply(for: text)
        appendFixtureAssistantMessage(
            reply,
            endpointID: endpoint,
            sessionID: sessionID,
            turnID: turnID,
            status: shouldStayRunning ? "running" : "completed"
        )
        if shouldStayRunning {
            streamStatusText = "Codex 正在输出"
            streamingTaskID = sessionID
        } else {
            streamStatusText = "当前会话 \(sessionID)"
            streamingTaskID = nil
        }
    }

    private func stopFixtureCurrent() {
        let sessionID = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }
        completeFixtureRunningMessages(sessionID: sessionID)
        fixtureCommandID += 1
        appendFixtureAssistantMessage(
            "任务已打断",
            endpointID: endpointID,
            sessionID: sessionID,
            turnID: "fixture-interrupt-\(fixtureCommandID)",
            status: "completed"
        )
        streamStatusText = "已请求打断"
        streamingTaskID = nil
    }

    private func createFixtureConversation() {
        fixtureCommandID += 1
        let sessionID = "fixture-new-\(fixtureCommandID)"
        let endpoint = endpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "quectel-lnx" : endpointID
        sessions.insert(
            FleetSession(session_id: sessionID, endpoint_id: endpoint, source: "codex-vscode", title: "新对话 \(fixtureCommandID)", cwd: "/home/donovan/work", rollout_path: nil, status: "synced", thread_id: "fixture-thread-\(fixtureCommandID)", active_turn_id: nil, updated_at: "2026-06-23T10:05:00Z"),
            at: 0
        )
        sessionSelector = sessionID
        sessionPolicy = "fixed-session"
        codexMessages = []
        codexMessageStates = [:]
        historyCodexMessagesBySession[sessionID] = []
        streamStatusText = "已新开对话"
        streamingTaskID = nil
    }

    private func appendFixtureAssistantMessage(
        _ text: String,
        endpointID endpoint: String,
        sessionID: String,
        turnID: String,
        status: String
    ) {
        fixtureNextMessageSeq += 1
        let messageID = "fixture-assistant-\(fixtureCommandID)-\(fixtureNextMessageSeq)"
        let message = FleetCodexMessage(
            endpoint_id: endpoint,
            session_id: sessionID,
            message_id: messageID,
            turn_id: turnID,
            seq: fixtureNextMessageSeq,
            role: "assistant",
            text: text,
            status: status,
            updated_at: "2026-06-23T10:04:10Z"
        )
        appendFixtureMessage(message)
        if ["running", "streaming", "queued"].contains(status) {
            codexMessageStates[messageID] = FleetCodexMessageState(endpoint_id: endpoint, session_id: sessionID, message_id: messageID, turn_id: turnID, status: status, detail: nil, updated_at: "2026-06-23T10:04:10Z")
        }
    }

    private func appendFixtureMessage(_ message: FleetCodexMessage) {
        codexMessageSessionID = message.session_id
        codexMessages.append(message)
        var messages = historyCodexMessagesBySession[message.session_id] ?? []
        messages.append(message)
        historyCodexMessagesBySession[message.session_id] = messages
    }

    private func completeFixtureRunningMessages(sessionID: String) {
        let runningStatuses = Set(["running", "streaming", "queued"])
        codexMessageStates = codexMessageStates.mapValues { state in
            if state.session_id == sessionID && runningStatuses.contains(state.status) {
                return FleetCodexMessageState(endpoint_id: state.endpoint_id, session_id: state.session_id, message_id: state.message_id, turn_id: state.turn_id, status: "completed", detail: state.detail, updated_at: "2026-06-23T10:04:20Z")
            }
            return state
        }
        for index in codexMessages.indices where codexMessages[index].session_id == sessionID && runningStatuses.contains(codexMessages[index].status ?? "") {
            codexMessages[index].status = "completed"
        }
        if var historyMessages = historyCodexMessagesBySession[sessionID] {
            for index in historyMessages.indices where runningStatuses.contains(historyMessages[index].status ?? "") {
                historyMessages[index].status = "completed"
            }
            historyCodexMessagesBySession[sessionID] = historyMessages
        }
    }

    private func fixtureAllMessages(for sessionID: String) -> [FleetCodexMessage] {
        historyCodexMessagesBySession[sessionID] ?? fixtureMessages().filter { $0.session_id == sessionID }
    }

    private func fixtureReply(for text: String) -> String {
        let marker = "reply exactly "
        if let range = text.range(of: marker, options: [.caseInsensitive]) {
            let reply = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { return reply }
        }
        if text.localizedCaseInsensitiveContains("long") || text.localizedCaseInsensitiveContains("keep the turn active") {
            return "正在思考，等待进一步引导或中断"
        }
        return "收到：\(text)"
    }

    @discardableResult
    private func sendV1Command(type: String, text: String) async throws -> FleetV1Command {
        var selectedSessionID = sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        var selectedEndpointID = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedSessions = sessions
            .filter(isCodexRuntimeSession)
            .sorted(by: codexSessionPrecedes)
        if hasLaunchFixedCodexSessionTarget {
            guard let fixedSession = launchFixedCodexSession(from: orderedSessions) else {
                throw FleetWorkbenchLocalError.fixedCodexSessionUnavailable(launchFixedCodexSessionLabel)
            }
            selectedSessionID = fixedSession.session_id
            selectedEndpointID = fixedSession.endpoint_id
            sessionSelector = selectedSessionID
            endpointID = selectedEndpointID
        }
        let selectedSession = orderedSessions.first { session in
            session.session_id == selectedSessionID && (selectedEndpointID.isEmpty || session.endpoint_id == selectedEndpointID)
        }
        if !hasLaunchFixedCodexSessionTarget {
            let shouldUseCurrentSourceSession = sessionPolicy != "fixed-session" || selectedSession == nil || (selectedSession?.isRelayPlaceholder ?? false)
            if shouldUseCurrentSourceSession,
               let firstSession = currentRuntimeSession(endpointID: selectedEndpointID, from: orderedSessions) {
                selectedSessionID = firstSession.session_id
                selectedEndpointID = firstSession.endpoint_id
            } else if let selectedSession {
                selectedSessionID = selectedSession.session_id
                selectedEndpointID = selectedSession.endpoint_id
            }
        } else if let selectedSession {
            selectedSessionID = selectedSession.session_id
            selectedEndpointID = selectedSession.endpoint_id
        }
        if hasLaunchFixedCodexSessionTarget, Self.isCurrentBridgeSessionID(selectedSessionID) {
            throw FleetWorkbenchLocalError.unsafeCurrentBridgeSession(selectedSessionID)
        }
        sessionSelector = selectedSessionID
        endpointID = selectedEndpointID
        guard !selectedEndpointID.isEmpty, !selectedSessionID.isEmpty else {
            throw URLError(.badURL)
        }
        let payload = v1CommandPayload(text: text)
        return try await request(
            FleetV1Command.self,
            path: "/v1/commands",
            method: "POST",
            body: AnyEncodable(FleetV1CommandRequest(endpoint_id: selectedEndpointID, session_id: selectedSessionID, type: type, payload_json: payload))
        )
    }

    func selectCodexSource(endpointID targetEndpointID: String) {
        let trimmedEndpointID = targetEndpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpointID.isEmpty else { return }

        let selectedProject = projects.first { project in
            project.endpoint_id == trimmedEndpointID && project.alias == projectAlias
        } ?? projects.first { project in
            project.endpoint_id == trimmedEndpointID
        }

        endpointID = trimmedEndpointID
        if let selectedProject {
            projectAlias = selectedProject.alias
            projectPath = selectedProject.path
            projectMode = selectedProject.mode ?? "vscode"
        }
        sessionSelector = ""
        sessionPolicy = "project-default"
        thinkingTranscript = ""
        outputTranscript = ""
        sessionEvents = []
        sessionEventSessionID = nil
        codexMessages = []
        codexMessageStates = [:]
        localPendingMessages = localPendingMessages.filter { $0.endpoint_id == trimmedEndpointID }

        if isV1Runtime {
            if let firstSession = currentRuntimeSession(endpointID: trimmedEndpointID) {
                sessionSelector = firstSession.session_id
                endpointID = firstSession.endpoint_id
                streamStatusText = "已切换到 \(firstSession.session_id)"
                Task {
                    await loadV1Messages(endpointID: firstSession.endpoint_id, sessionID: firstSession.session_id)
                }
            } else {
                sessionSelector = ""
                streamStatusText = "当前 Codex 源暂无会话"
            }
            return
        }

        Task {
            do {
                let _: FleetChatBinding = try await request(
                    FleetChatBinding.self,
                    path: "/api/chat-bindings",
                    method: "POST",
                    body: AnyEncodable(FleetBindChatRequest(channel: channel, chat_id: chatID, profile: profile, project_alias: projectAlias, endpoint_id: endpointID, session_policy: "project-default"))
                )
                streamStatusText = "已切换到 \(projectAlias)"
                await refreshState(forceSessionEvents: true)
            } catch {
                banner = "切换 Codex 源失败：\(error.localizedDescription)"
            }
        }
    }

    var bindingForCurrentChat: FleetChatBinding? {
        bindings.first
    }

    var currentSessionID: String {
        bindingForCurrentChat?.session_id ?? sessionSelector
    }

    func tasks(for sessionID: String) -> [FleetTask] {
        tasks.filter { $0.session_id == sessionID }
    }

    func events(for sessionID: String) -> [FleetEvent] {
        let historical = sessionEventSessionID == sessionID ? sessionEvents : []
        let live = recentEvents.filter { $0.session_id == sessionID }
        var seen = Set<Int>()
        return (historical + live).filter { event in
            if seen.contains(event.event_id) { return false }
            seen.insert(event.event_id)
            return true
        }
    }

    func visibleCodexMessages(for sessionID: String) -> [FleetCodexMessage] {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return [] }
        let cachedHistoryMessages = historyCodexMessagesBySession[trimmedSessionID] ?? []
        if !isV1Runtime && cachedHistoryMessages.isEmpty { return [] }
        let directServerMessages = codexMessages.filter { $0.session_id == trimmedSessionID }
        let serverMessages: [FleetCodexMessage]
        if !directServerMessages.isEmpty {
            serverMessages = directServerMessages
        } else if codexMessageSessionID == trimmedSessionID {
            serverMessages = codexMessages
        } else {
            serverMessages = cachedHistoryMessages
        }
        let pending = localPendingMessages.filter { $0.session_id == trimmedSessionID }
        let ordered = (serverMessages + pending)
            .sorted {
                let leftRank = codexMessageSortRank($0)
                let rightRank = codexMessageSortRank($1)
                if leftRank != rightRank { return leftRank < rightRank }
                return $0.message_id < $1.message_id
            }
        let visibleOrdered = ordered.filter(\.isVisibleConversationMessage)
        let taskMirrorSignatures = Set(visibleOrdered
            .filter { $0.message_id.hasPrefix("task-") }
            .map(messageMirrorSignature))
        return visibleOrdered.filter { message in
            if message.message_id.hasPrefix("transcript-"),
               taskMirrorSignatures.contains(messageMirrorSignature(message)) {
                return false
            }
            return true
        }
    }

    private func messageMirrorSignature(_ message: FleetCodexMessage) -> String {
        "\(message.role):\(message.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func hasRunningCodexMessage(in sessionID: String) -> Bool {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isV1Runtime, !trimmedSessionID.isEmpty else { return false }
        let runningStatuses = Set(["streaming", "running", "queued"])
        if codexMessageStates.values.contains(where: { state in
            state.session_id == trimmedSessionID && runningStatuses.contains(state.status)
        }) {
            return true
        }
        return localPendingMessages.contains { pending in
            pending.session_id == trimmedSessionID && runningStatuses.contains(pending.status ?? "")
        }
    }

    private func codexMessageSortRank(_ message: FleetCodexMessage) -> Double {
        if message.message_id.hasPrefix("local-user-"),
           let commandID = Int(message.message_id.replacingOccurrences(of: "local-user-", with: "")) {
            return Double(1000 + commandID) - 0.5
        }
        return Double(message.seq)
    }

    private func persistPreferences() {
        guard didBoot else { return }
        defaults.set(managerURL, forKey: baseDefaultsKey + "managerURL")
        defaults.set(token, forKey: baseDefaultsKey + "token")
        defaults.set(profile, forKey: baseDefaultsKey + "profile")
        defaults.set(channel, forKey: baseDefaultsKey + "channel")
        defaults.set(chatID, forKey: baseDefaultsKey + "chatID")
        defaults.set(ownerChatID, forKey: baseDefaultsKey + "ownerChatID")
        defaults.set(projectAlias, forKey: baseDefaultsKey + "projectAlias")
        defaults.set(projectPath, forKey: baseDefaultsKey + "projectPath")
        defaults.set(endpointID, forKey: baseDefaultsKey + "endpointID")
        defaults.set(sessionSelector, forKey: baseDefaultsKey + "sessionSelector")
        defaults.set(sessionPolicy, forKey: baseDefaultsKey + "sessionPolicy")
        defaults.set(projectMode, forKey: baseDefaultsKey + "projectMode")
        defaults.set(model, forKey: baseDefaultsKey + "model")
        defaults.set(reasoningEffort, forKey: baseDefaultsKey + "reasoningEffort")
        defaults.set(prompt, forKey: baseDefaultsKey + "prompt")
    }

    private var taskModel: String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var taskReasoningEffort: String? {
        let trimmed = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isCurrentBridgeSessionID(_ sessionID: String) -> Bool {
        sessionID == "linux-vscode-main" || sessionID == "codex-vscode-current"
    }

    private var hasLaunchFixedCodexSessionTarget: Bool {
        !launchFixedCodexSessionID.isEmpty || !launchFixedCodexSessionTitle.isEmpty
    }

    private var launchFixedCodexSessionLabel: String {
        if !launchFixedCodexSessionID.isEmpty { return launchFixedCodexSessionID }
        return launchFixedCodexSessionTitle
    }

    private func launchFixedCodexSession(from sourceSessions: [FleetSession]) -> FleetSession? {
        guard hasLaunchFixedCodexSessionTarget else { return nil }
        let safeSessions = sourceSessions.filter { !$0.isRelayPlaceholder && !$0.isCurrentVscodeBridge }
        if !launchFixedCodexSessionID.isEmpty {
            return safeSessions.first { $0.session_id == launchFixedCodexSessionID }
        }
        return safeSessions.first { session in
            session.normalizedTitle.compare(launchFixedCodexSessionTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func applyRuntimeSession(_ session: FleetSession) {
        if sessionSelector != session.session_id {
            sessionSelector = session.session_id
        }
        if endpointID != session.endpoint_id {
            endpointID = session.endpoint_id
        }
    }

    private func v1CommandPayload(text: String) -> String {
        let values = [
            "text": text,
            "mode": projectMode,
            "model": model,
            "reasoning_effort": reasoningEffort
        ]
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"text\":\"\(text.jsonEscaped)\"}"
        }
        return string
    }

    private func isCodexRuntimeSession(_ session: FleetSession) -> Bool {
        session.isCodexRuntimeCandidate
    }

    private func preferredRuntimeSession(endpointID targetEndpointID: String? = nil, from sourceSessions: [FleetSession]? = nil) -> FleetSession? {
        let trimmedEndpointID = targetEndpointID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = (sourceSessions ?? sessions.filter(isCodexRuntimeSession))
            .filter { session in
                trimmedEndpointID.isEmpty || session.endpoint_id == trimmedEndpointID
            }
            .sorted(by: codexSessionPrecedes)
        return candidates.first { $0.isCurrentVscodeBridge }
            ?? candidates.first { $0.isPreferredCodexRuntime && !$0.isRelayPlaceholder }
            ?? candidates.first { !$0.isRelayPlaceholder }
            ?? candidates.first
    }

    private func currentRuntimeSession(endpointID targetEndpointID: String? = nil, from sourceSessions: [FleetSession]? = nil) -> FleetSession? {
        let endpointSession = preferredRuntimeSession(endpointID: targetEndpointID, from: sourceSessions)
        if let endpointSession, !endpointSession.isRelayPlaceholder {
            return endpointSession
        }
        return preferredRuntimeSession(from: sourceSessions) ?? endpointSession
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        body: AnyEncodable? = nil
    ) async throws -> T {
        if useCodexFixtureForUITests {
            throw URLError(.unsupportedURL)
        }
        guard let url = URL(string: managerURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.fleet.decode(type, from: data)
    }

    private func resetStream(for taskID: String) {
        streamCursor = 0
        streamingTaskID = taskID
        streamStatusText = "正在连接流式通道"
        thinkingTranscript = ""
        outputTranscript = ""
        recentEvents = []
    }

    private func startEventStream(taskID: String) {
        if streamingTaskID == taskID, eventStreamTask != nil {
            return
        }
        eventStreamTask?.cancel()
        if streamingTaskID != taskID {
            resetStream(for: taskID)
        }
        eventStreamTask = Swift.Task { [weak self] in
            await self?.readEventStream(taskID: taskID)
        }
    }

    private func readEventStream(taskID: String) async {
        do {
            let base = managerURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/api/stream?target=\(taskID.escapedQuery)&cursor=\(streamCursor)") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3600
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            streamStatusText = "流式传输中"
            var sawTerminalEvent = false
            for try await line in bytes.lines {
                if Swift.Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder.fleet.decode(FleetEvent.self, from: data) else {
                    continue
                }
                consumeStreamEvent(event)
                if event.type == "task.completed" || event.type == "task.interrupted" || event.type == "task.failed" {
                    sawTerminalEvent = true
                    break
                }
            }
            eventStreamTask = nil
            if sawTerminalEvent || activeTask?.task_id == taskID {
                await refreshState(forceSessionEvents: true)
            }
        } catch {
            if !Swift.Task.isCancelled {
                streamStatusText = "流式连接失败：\(error.localizedDescription)"
                eventStreamTask = nil
            }
        }
    }

    private func consumeStreamEvent(_ event: FleetEvent) {
        streamCursor = max(streamCursor, event.event_id)
        if !recentEvents.contains(where: { $0.event_id == event.event_id }) {
            recentEvents.append(event)
            if recentEvents.count > 40 {
                recentEvents.removeFirst(recentEvents.count - 40)
            }
        }
        let delta = event.data?.deltaString ?? event.message ?? ""
        switch event.type {
        case "codex.thinking.delta":
            if !delta.isEmpty {
                thinkingTranscript += (thinkingTranscript.isEmpty ? "" : "\n") + delta
            }
            streamStatusText = "Codex 正在思考"
        case "codex.output.delta":
            if !delta.isEmpty {
                outputTranscript += delta
            }
            streamStatusText = "Codex 正在输出"
        case "task.completed":
            streamStatusText = "任务完成"
            eventStreamTask = nil
            activeTask = nil
        case "task.interrupted":
            streamStatusText = "任务已打断"
            eventStreamTask = nil
            activeTask = nil
        case "task.failed":
            streamStatusText = delta.isEmpty ? "任务失败" : "任务失败：\(delta)"
            eventStreamTask = nil
            activeTask = nil
        case "task.inserted":
            streamStatusText = "任务已进入队列"
        case "task.steered", "turn.steer.queued", "turn.steer.sent":
            streamStatusText = "已引导当前任务"
        case "workspace.switched":
            streamStatusText = "工作区已切换"
        case "conversation.created":
            streamStatusText = "新对话已创建"
        default:
            break
        }
    }

    private func settleIdleStreamState(sessionID: String) {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        streamingTaskID = nil
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        streamStatusText = trimmedSessionID.isEmpty ? "无运行任务" : "当前会话 \(trimmedSessionID)"
    }
}

private extension FleetTask {
    var isActive: Bool {
        status == "running" || status == "queued"
    }
}

private extension JSONDecoder {
    static var fleet: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

private struct AnyCodable: Decodable {}

private extension String {
    var escapedQuery: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    func shortFleetSummary(maxCharacters: Int) -> String {
        let singleLine = components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let sentenceEndings = CharacterSet(charactersIn: "。！？!?；;")
        let firstSentence = singleLine.rangeOfCharacter(from: sentenceEndings).map {
            String(singleLine[..<$0.upperBound])
        } ?? singleLine
        let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var jsonEscaped: String {
        var out = ""
        for scalar in unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

enum FleetWorkbenchMode: String, CaseIterable, Identifiable {
    case overview = "概览"
    case stream = "流式"
    case target = "目标"
    case sessions = "会话"
    case tasks = "任务"
    case settings = "连接"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .stream: return "waveform"
        case .target: return "scope"
        case .sessions: return "rectangle.stack"
        case .tasks: return "arrow.up.message"
        case .settings: return "network"
        }
    }
}

struct FleetCodexOption: Identifiable {
    var id: String { value }
    let title: String
    let value: String
}

private struct FleetCodexSource: Identifiable {
    let endpointID: String
    let title: String
    let subtitle: String

    var id: String { endpointID }
}

private struct FleetChatBubble: Identifiable {
    let id: String
    let title: String
    let body: String
    let isUser: Bool
    let tint: Color
}

enum FleetMessageSegmentKind {
    case paragraph
    case code(language: String?)
    case command
}

struct FleetMessageSegment: Identifiable {
    let id: Int
    let kind: FleetMessageSegmentKind
    let text: String
    let copyText: String
}

private enum FleetClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct FleetRichMessageText: View {
    let text: String
    let tint: Color
    var compact = false
    var fillsWidth = true
    @State private var copiedSegmentID: Int?
    @State private var codeExpansionOverrides: [Int: Bool] = [:]

    private let collapsedCodeLineLimit = 8
    private let longCodeLineThreshold = 14

    private var segments: [FleetMessageSegment] {
        FleetMessageParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .paragraph:
                    paragraph(segment.text)
                case .code(let language):
                    codeBlock(segment: segment, language: language)
                case .command:
                    commandBlock(segment: segment)
                }
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }

    private func paragraph(_ value: String) -> some View {
        markdownText(value)
            .font(compact ? .footnote : .body)
            .lineSpacing(compact ? 2 : 4)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func markdownText(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: value, options: options) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func codeBlock(segment: FleetMessageSegment, language: String?) -> some View {
        let lineCount = codeLineCount(segment.text)
        let isFoldable = lineCount > collapsedCodeLineLimit
        let defaultExpanded = lineCount <= longCodeLineThreshold
        let isExpanded = codeExpansionOverrides[segment.id] ?? defaultExpanded
        let displayedText = isFoldable && !isExpanded ? codePreview(segment.text) : segment.text

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("代码")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let language = codeBlockLanguage(language) {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if lineCount > 1 {
                    Text("\(lineCount) 行")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isFoldable {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            codeExpansionOverrides[segment.id] = !isExpanded
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "折叠代码块" : "展开代码块")
                }
                copyButton(segment: segment, label: "复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(displayedText)
                    .font(.system(size: compact ? 12 : 13, weight: .regular, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }

            if isFoldable && !isExpanded {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                        .font(.caption2.weight(.semibold))
                    Text("已折叠 \(max(0, lineCount - collapsedCodeLineLimit)) 行")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(Color.fleetPlatform(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func commandBlock(segment: FleetMessageSegment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("命令")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                copyButton(segment: segment, label: "复制命令")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.045))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(segment.text)
                    .font(.system(size: compact ? 12 : 13, weight: .regular, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func copyButton(segment: FleetMessageSegment, label: String) -> some View {
        Button {
            FleetClipboard.copy(segment.copyText)
            copiedSegmentID = segment.id
            Swift.Task {
                try? await Swift.Task.sleep(nanoseconds: 900_000_000)
                if copiedSegmentID == segment.id {
                    copiedSegmentID = nil
                }
            }
        } label: {
            Image(systemName: copiedSegmentID == segment.id ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copiedSegmentID == segment.id ? .green : .secondary)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func codeBlockLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return nil
        }
        return language
    }

    private func codeLineCount(_ value: String) -> Int {
        max(1, value.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private func codePreview(_ value: String) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.prefix(collapsedCodeLineLimit).joined(separator: "\n")
    }
}

enum FleetMessageParser {
    static func parse(_ text: String) -> [FleetMessageSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var segments: [FleetMessageSegment] = []
        var paragraphLines: [String] = []
        var commandLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeFence = false
        var segmentID = 0

        func nextID() -> Int {
            defer { segmentID += 1 }
            return segmentID
        }

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll()
            guard !joined.isEmpty else { return }
            segments.append(FleetMessageSegment(id: nextID(), kind: .paragraph, text: joined, copyText: joined))
        }

        func flushCommands() {
            let display = commandLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            commandLines.removeAll()
            guard !display.isEmpty else { return }
            let copy = display
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { cleanedCommandLine(String($0)) }
                .joined(separator: "\n")
            segments.append(FleetMessageSegment(id: nextID(), kind: .command, text: copy, copyText: copy))
        }

        func flushCode() {
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            codeLines.removeAll()
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(FleetMessageSegment(id: nextID(), kind: .code(language: codeLanguage), text: code, copyText: code))
            codeLanguage = nil
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    inCodeFence = false
                    flushCode()
                } else {
                    flushParagraph()
                    flushCommands()
                    inCodeFence = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushCommands()
                continue
            }

            if looksLikeCommand(trimmed) ||
                commandLines.last?.trimmingCharacters(in: .whitespaces).hasSuffix("\\") == true {
                flushParagraph()
                commandLines.append(line)
                continue
            }

            flushCommands()
            paragraphLines.append(line)
        }

        if inCodeFence {
            flushCode()
        }
        flushParagraph()
        flushCommands()
        return segments.isEmpty ? [FleetMessageSegment(id: 0, kind: .paragraph, text: text, copyText: text)] : segments
    }

    private static func looksLikeCommand(_ line: String) -> Bool {
        if line.hasPrefix("$ ") || line.hasPrefix("% ") || line.hasPrefix("➜ ") { return true }
        if line.hasPrefix("./") || line.hasPrefix("~/") { return true }
        if line.contains("：") || line.contains("。") { return false }
        let commandHeads: Set<String> = [
            "adb", "awk", "brew", "cat", "cd", "chmod", "chown", "cp", "curl",
            "docker", "export", "find", "git", "grep", "kill", "kubectl", "ls",
            "make", "mkdir", "mv", "npm", "pnpm", "python", "python3", "rm",
            "rg", "scp", "sed", "ssh", "sudo", "swift", "tar", "xcodebuild", "yarn"
        ]
        guard let head = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
        return commandHeads.contains(String(head))
    }

    private static func cleanedCommandLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["$ ", "% ", "➜ "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }
}

struct FleetWorkbenchView: View {
    @StateObject private var store = FleetWorkbenchStore()
    var openKnowledge: () -> Void = {}
    @State private var mode: FleetWorkbenchMode = .overview
    @State private var navigationPath: [String] = []
    private let historyRouteID = "__mkb_history_sessions__"
    private let modelOptions = [
        FleetCodexOption(title: "gpt-5.5", value: "gpt-5.5"),
        FleetCodexOption(title: "gpt-5.4", value: "gpt-5.4"),
        FleetCodexOption(title: "gpt-5.4-mini", value: "gpt-5.4-mini")
    ]
    private let reasoningOptions = [
        FleetCodexOption(title: "minimal", value: "minimal"),
        FleetCodexOption(title: "low", value: "low"),
        FleetCodexOption(title: "medium", value: "medium"),
        FleetCodexOption(title: "high", value: "high"),
        FleetCodexOption(title: "xhigh", value: "xhigh")
    ]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            chatShell
                .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let banner = store.banner {
                    Text(banner)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 5)
                        .padding(.top, 8)
                        .onTapGesture { store.banner = nil }
                }
            }
            .navigationDestination(for: String.self) { destination in
                if destination == historyRouteID {
                    historySessionsContent
                } else {
                    sessionDetailContent(sessionID: destination)
                }
            }
        }
        .onAppear {
            store.refresh()
        }
        .task {
            await store.refreshState(forceSessionEvents: true)
            while !Swift.Task.isCancelled {
                try? await Swift.Task.sleep(nanoseconds: 2_500_000_000)
                await store.refreshState()
            }
        }
        .task(id: displaySessionID) {
            if !displaySessionID.isEmpty {
                await store.loadSessionEvents(sessionID: displaySessionID)
            }
        }
    }

    private var displaySessionID: String {
        let selectedSessionID = store.sessionSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedSessionID.isEmpty,
           store.sessions.contains(where: { session in
               session.session_id == selectedSessionID &&
               session.endpoint_id == activeSourceEndpointID &&
               (session.isCurrentVscodeBridge || isCodexHistorySession(session))
           }) {
            return selectedSessionID
        }
        if let currentBridgeSession = currentBridgeSessionForActiveSource {
            return currentBridgeSession.session_id
        }
        return activeSourceSessions.first?.session_id ?? ""
    }

    private var displaySessionTitle: String {
        guard !displaySessionID.isEmpty else { return store.statusText }
        if let session = store.sessions.first(where: { $0.session_id == displaySessionID }),
           let title = session.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let mapping = store.mappings.first(where: { mapping in
            mapping.session?.session_id == displaySessionID || mapping.binding.session_id == displaySessionID
        }) {
            let title = (mapping.session?.title ?? mapping.binding.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        if let binding = store.bindingForCurrentChat {
            let title = (binding.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return synthesizedSessionTitle(for: displaySessionID)
    }

    private var topBarSessionTitle: String {
        activeCodexSource.title
    }

    private var activeSourceEndpointID: String {
        let bindingEndpoint = store.bindingForCurrentChat?.endpoint_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !bindingEndpoint.isEmpty { return bindingEndpoint }
        let selectedEndpoint = store.endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedEndpoint.isEmpty { return selectedEndpoint }
        return store.endpoints.first?.endpoint_id ?? ""
    }

    private var codexSources: [FleetCodexSource] {
        var orderedEndpointIDs: [String] = []
        let codexEndpointIDs = Set(store.sessions.filter(isCodexHistorySession).map(\.endpoint_id))
        func append(_ endpointID: String?) {
            let trimmed = endpointID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, !orderedEndpointIDs.contains(trimmed) else { return }
            orderedEndpointIDs.append(trimmed)
        }

        if activeSourceEndpointID.isEmpty || codexEndpointIDs.isEmpty || codexEndpointIDs.contains(activeSourceEndpointID) {
            append(activeSourceEndpointID)
        }
        store.sessions
            .filter(isCodexHistorySession)
            .sorted(by: codexSessionPrecedes)
            .forEach { append($0.endpoint_id) }
        store.endpoints
            .filter { codexEndpointIDs.contains($0.endpoint_id) }
            .forEach { append($0.endpoint_id) }
        store.projects
            .filter { codexEndpointIDs.contains($0.endpoint_id) }
            .forEach { append($0.endpoint_id) }

        return orderedEndpointIDs.map { endpointID in
            FleetCodexSource(
                endpointID: endpointID,
                title: codexSourceTitle(endpointID: endpointID),
                subtitle: codexSourceSubtitle(endpointID: endpointID)
            )
        }
    }

    private var activeCodexSource: FleetCodexSource {
        codexSources.first(where: { $0.endpointID == activeSourceEndpointID })
            ?? FleetCodexSource(endpointID: activeSourceEndpointID, title: "公司 Codex", subtitle: activeSourceEndpointID)
    }

    private var activeSourceSessions: [FleetSession] {
        store.sessions.filter { session in
            session.endpoint_id == activeSourceEndpointID && isCodexHistorySession(session)
        }
        .sorted(by: codexSessionPrecedes)
    }

    private var currentBridgeSessionForActiveSource: FleetSession? {
        store.sessions
            .filter { session in
                session.endpoint_id == activeSourceEndpointID && session.isCurrentVscodeBridge
            }
            .sorted(by: codexSessionPrecedes)
            .first
    }

    private var displayedActiveSourceSessions: [FleetSession] {
        Array(activeSourceSessions.prefix(50))
    }

    private var activeSourceMappings: [FleetSessionMapping] {
        let knownSessionIDs = Set(activeSourceSessions.map(\.session_id))
        return store.mappings.filter { mapping in
            let endpointID = mapping.session?.endpoint_id ?? mapping.binding.endpoint_id ?? ""
            let matchesEndpoint = endpointID.isEmpty || endpointID == activeSourceEndpointID
            guard matchesEndpoint else { return false }
            if let session = mapping.session {
                return isCodexHistorySession(session) && !knownSessionIDs.contains(session.session_id)
            }
            return true
        }
    }

    private func codexSourceTitle(endpointID: String) -> String {
        if let endpoint = store.endpoints.first(where: { $0.endpoint_id == endpointID }) {
            let label = endpoint.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty { return label }
        }
        if let project = store.projects.first(where: { $0.endpoint_id == endpointID }) {
            return project.alias
        }
        return endpointID.isEmpty ? "公司 Codex" : endpointID
    }

    private func codexSourceSubtitle(endpointID: String) -> String {
        let projectAlias = store.projects.first(where: { $0.endpoint_id == endpointID })?.alias ?? store.projectAlias
        if projectAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return endpointID
        }
        return "\(endpointID) · \(projectAlias)"
    }

    private func isCodexHistorySession(_ session: FleetSession) -> Bool {
        session.isCodexRuntimeCandidate && !session.isRelayPlaceholder && !session.isCurrentVscodeBridge
    }

    private func synthesizedSessionTitle(for sessionID: String) -> String {
        let normalized = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.localizedCaseInsensitiveContains("linux-vscode") {
            return "公司 Linux VS Code Codex 对话"
        }
        if normalized.localizedCaseInsensitiveContains("session-default") {
            return "MKB Codex 默认会话"
        }
        return normalized
    }

    private var activeModelTitle: String {
        let value = store.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未设置" : (modelOptions.first(where: { $0.value == value })?.title ?? value)
    }

    private var activeReasoningTitle: String {
        let value = store.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未设置" : (reasoningOptions.first(where: { $0.value == value })?.title ?? value)
    }

    private var isCodexTaskRunning: Bool {
        if store.isV1Runtime {
            return store.hasRunningCodexMessage(in: store.sessionSelector)
        }
        if let activeTask = store.activeTask, activeTask.isActive {
            return true
        }
        return store.streamingTaskID != nil
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let value = store.model.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? "gpt-5.4" : value
            },
            set: { store.model = $0 }
        )
    }

    private var reasoningSelection: Binding<String> {
        Binding(
            get: {
                let value = store.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? "medium" : value
            },
            set: { store.reasoningEffort = $0 }
        )
    }

    private var chatShell: some View {
        VStack(spacing: 0) {
            chatTopBar
            Divider()
            chatTimeline
            Divider()
            chatComposer
        }
        .background(Color.fleetPlatform(.systemBackground))
        .onAppear {
            Swift.Task {
                await store.refreshState(forceSessionEvents: true)
                await ensureCurrentChatLoaded(force: true)
            }
        }
        .task(id: currentChatLoadKey) {
            await ensureCurrentChatLoaded(force: true)
        }
    }

    private var currentChatLoadKey: String {
        [
            displaySessionID,
            store.isV1Runtime ? "v1" : "legacy",
            store.codexMessageSessionID ?? "",
            "\(store.codexMessages.count)",
            "\(store.sessions.count)"
        ].joined(separator: "|")
    }

    private func ensureCurrentChatLoaded(force: Bool = false) async {
        let sessionID = displaySessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.isV1Runtime, !sessionID.isEmpty else { return }
        guard force || store.visibleCodexMessages(for: sessionID).isEmpty else { return }
        let endpointID = store.sessions.first(where: { $0.session_id == sessionID })?.endpoint_id ?? activeSourceEndpointID
        await store.loadV1Messages(endpointID: endpointID, sessionID: sessionID)
    }

    private var chatTopBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    openKnowledge()
                } label: {
                    toolbarIcon("sidebar.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到知识库")

                Menu {
                    ForEach(codexSources) { source in
                        Button(source.title == source.subtitle ? source.title : "\(source.title) · \(source.subtitle)", systemImage: source.endpointID == activeSourceEndpointID ? "checkmark.circle.fill" : "circle") {
                            store.selectCodexSource(endpointID: source.endpointID)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(topBarSessionTitle)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            Circle()
                                .fill(store.statusText == "连接失败" ? Color.red : Color.green)
                                .frame(width: 6, height: 6)
                        }
                        HStack(spacing: 4) {
                            Text(activeCodexSource.subtitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("公司 Codex")

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    if store.isRefreshing {
                        refreshingToolbarIcon
                    } else {
                        toolbarIcon("arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .buttonStyle(.plain)
                .accessibilityLabel("刷新公司 Codex")

            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    NavigationLink(value: historyRouteID) {
                        controlPillLabel("历史", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)

                    modelPicker
                    reasoningPicker
                }
                .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var modelPicker: some View {
        Menu {
            Picker("模型", selection: modelSelection) {
                ForEach(modelOptions) { option in
                    Text(option.title).tag(option.value)
                }
            }
        } label: {
            controlPillLabel(activeModelTitle, systemImage: "cpu")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换模型，当前 \(activeModelTitle)")
    }

    private var reasoningPicker: some View {
        Menu {
            Picker("推理等级", selection: reasoningSelection) {
                ForEach(reasoningOptions) { option in
                    Text(option.title).tag(option.value)
                }
            }
        } label: {
            controlPillLabel(activeReasoningTitle, systemImage: "brain.head.profile")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换推理等级，当前 \(activeReasoningTitle)")
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .background(Color.fleetPlatform(.secondarySystemBackground), in: Circle())
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private var refreshingToolbarIcon: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 34, height: 34)
            .background(Color.fleetPlatform(.secondarySystemBackground), in: Circle())
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func controlPillLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.fleetPlatform(.secondarySystemBackground), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private var chatTimeline: some View {
        let visibleBubbles = Array(chatBubbles.suffix(30))
        let bottomID = "codex-main-bottom"
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if visibleBubbles.isEmpty {
                        emptyChatState
                    } else {
                        ForEach(visibleBubbles) { bubble in
                            chatBubbleView(bubble)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: visibleBubbles.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: visibleBubbles.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .task(id: visibleBubbles.last?.id ?? "empty") {
                try? await Swift.Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyChatState: some View {
        Color.clear
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chatComposer: some View {
        let trimmedPrompt = store.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldGuide = isCodexTaskRunning && !trimmedPrompt.isEmpty
        let shouldStop = isCodexTaskRunning && trimmedPrompt.isEmpty
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    Button("新对话", systemImage: "plus.message") { store.newConversation() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                TextField("Message Codex", text: $store.prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.vertical, 10)

                Button {
                    if shouldGuide {
                        store.insertPrompt()
                    } else if shouldStop {
                        store.stopCurrent()
                    } else {
                        store.sendPrompt()
                    }
                } label: {
                    Image(systemName: shouldStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(isCodexTaskRunning || !trimmedPrompt.isEmpty ? Color.white : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            composerActionBackground,
                            in: Circle()
                        )
                }
                .disabled(!isCodexTaskRunning && trimmedPrompt.isEmpty)
                .buttonStyle(.plain)
                .accessibilityLabel(shouldGuide ? "引导当前任务" : (shouldStop ? "中断当前任务" : "发送"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.fleetPlatform(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var composerActionBackground: Color {
        let trimmedPrompt = store.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCodexTaskRunning && trimmedPrompt.isEmpty {
            return .red
        }
        return trimmedPrompt.isEmpty ? Color.fleetPlatform(.tertiarySystemFill) : Color.primary
    }

    private var chatBubbles: [FleetChatBubble] {
        let sessionID = displaySessionID
        let v1Messages = store.visibleCodexMessages(for: sessionID)
        if store.isV1Runtime {
            return v1Messages.map { message in
                let state = store.codexMessageStates[message.message_id]?.status ?? message.status ?? ""
                let suffix = !message.isUser && ["streaming", "running", "queued"].contains(state) ? "\n\n…" : ""
                return FleetChatBubble(
                    id: message.id,
                    title: message.isUser ? "你" : "Codex",
                    body: message.text + suffix,
                    isUser: message.isUser,
                    tint: state == "failed" ? .red : .primary
                )
            }
        }
        if !v1Messages.isEmpty {
            return v1Messages.map { message in
                let state = store.codexMessageStates[message.message_id]?.status ?? message.status ?? ""
                let suffix = !message.isUser && ["streaming", "running", "queued"].contains(state) ? "\n\n…" : ""
                return FleetChatBubble(
                    id: message.id,
                    title: message.isUser ? "你" : "Codex",
                    body: message.text + suffix,
                    isUser: message.isUser,
                    tint: state == "failed" ? .red : .primary
                )
            }
        }
        let sessionTasks = sessionID.isEmpty ? store.tasks : store.tasks(for: sessionID)
        let sessionEvents = sessionID.isEmpty ? store.recentEvents : store.events(for: sessionID)
        let orderedTasks = sessionTasks.sorted { lhs, rhs in
            let left = chatTimelineSortKey(lhs, events: sessionEvents)
            let right = chatTimelineSortKey(rhs, events: sessionEvents)
            if left.bucket != right.bucket { return left.bucket < right.bucket }
            if left.order != right.order { return left.order < right.order }
            return lhs.task_id < rhs.task_id
        }

        return orderedTasks.flatMap { task -> [FleetChatBubble] in
            let prompt = (task.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.hasPrefix("<environment_context>") || prompt.hasPrefix("# AGENTS.md instructions") {
                return []
            }
            var bubbles = [
                FleetChatBubble(
                    id: "user-\(task.task_id)",
                    title: "你",
                    body: prompt,
                    isUser: true,
                    tint: .primary
                )
            ]
            let outputEvents = sessionEvents
                .filter { $0.task_id == task.task_id && $0.type == "codex.output.delta" }
            let streamedText = outputEvents
                .compactMap { $0.data?.deltaString }
                .joined()
            let transcriptText = outputEvents
                .filter { !($0.data?.hasDelta ?? false) }
                .compactMap(\.message)
                .joined()
            let outputText = streamedText.isEmpty ? transcriptText : streamedText
            if !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bubbles.append(FleetChatBubble(id: "output-\(task.task_id)", title: "Codex", body: outputText, isUser: false, tint: .primary))
            } else if let summary = task.last_summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bubbles.append(FleetChatBubble(id: "summary-\(task.task_id)", title: "Codex", body: summary, isUser: false, tint: .primary))
            }
            return bubbles.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func chatTimelineSortKey(_ task: FleetTask, events: [FleetEvent]) -> (bucket: Int, order: Int) {
        let eventOrder = events
            .filter { $0.task_id == task.task_id && ($0.type == "transcript.user" || $0.type == "task.created") }
            .map(\.event_id)
            .min()
        if let eventOrder {
            return (1, eventOrder)
        }
        if let line = transcriptLineNumber(task.task_id) {
            return (0, line)
        }
        return (2, trailingTaskNumber(task.task_id) ?? Int.max)
    }

    private func transcriptLineNumber(_ taskID: String) -> Int? {
        if let range = taskID.range(of: "-line-") {
            let suffix = taskID[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func trailingTaskNumber(_ taskID: String) -> Int? {
        if let last = taskID.split(separator: "-").last, let value = Int(last) {
            return value
        }
        return nil
    }

    private func chatBubbleView(_ bubble: FleetChatBubble) -> some View {
        HStack {
            if bubble.isUser { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 6) {
                Text(bubble.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FleetRichMessageText(text: bubble.body, tint: bubble.tint, fillsWidth: !bubble.isUser)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubble.isUser ? Color.fleetPlatform(.secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: bubble.isUser ? 320 : .infinity, alignment: bubble.isUser ? .trailing : .leading)
            if !bubble.isUser { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity, alignment: bubble.isUser ? .trailing : .leading)
    }

    private var modeSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FleetWorkbenchMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        Label(item.rawValue, systemImage: item.iconName)
                            .font(.subheadline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(mode == item ? Color.primary : Color.fleetPlatform(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(mode == item ? Color.fleetPlatform(.systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换到\(item.rawValue)模式")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var codexContent: some View {
        Group {
            Section("公司 Codex") {
                LabeledContent("连接") { Text(store.statusText).foregroundStyle(statusColor) }
                LabeledContent("摘要") { Text(store.summaryText).foregroundStyle(.secondary) }
                LabeledContent("流式") { Text(store.streamStatusText).foregroundStyle(.secondary) }
                HStack {
                    Button("刷新", systemImage: "arrow.clockwise") { store.refresh() }
                        .disabled(store.isRefreshing)
                    Button("新对话", systemImage: "plus.message") { store.newConversation() }
                    Button("打断", systemImage: "stop.circle", role: .destructive) { store.stopCurrent() }
                }
                .buttonStyle(.bordered)
            }

            Section("当前会话") {
                if let binding = store.bindingForCurrentChat {
                    LabeledContent("项目") { Text(binding.project_alias ?? "-") }
                    LabeledContent("会话") {
                        let sessionID = binding.session_id ?? store.sessionSelector
                        Text(sessionID.isEmpty ? "-" : sessionID)
                    }
                    LabeledContent("策略") { Text(binding.session_policy ?? "-") }
                    if !store.currentSessionID.isEmpty {
                        NavigationLink("进入当前对话", value: store.currentSessionID)
                    }
                    Button("解除绑定", systemImage: "link.badge.minus") { store.unbindChat() }
                } else {
                    LabeledContent("项目") { Text(store.projectAlias) }
                    LabeledContent("会话") { Text(store.sessionSelector.isEmpty ? "-" : store.sessionSelector) }
                    if !store.sessionSelector.isEmpty {
                        NavigationLink("进入当前对话", value: store.sessionSelector)
                    }
                    Button("绑定当前入口", systemImage: "link") { store.bindChat() }
                }
            }

            Section("运行参数") {
                Picker("模型", selection: $store.model) {
                    ForEach(modelOptions) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                Picker("推理", selection: $store.reasoningEffort) {
                    ForEach(reasoningOptions) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                Picker("模式", selection: $store.projectMode) {
                    Text("vscode").tag("vscode")
                    Text("headless").tag("headless")
                }
                .pickerStyle(.segmented)
            }

            Section("工作区") {
                TextField("项目", text: $store.projectAlias)
                TextField("会话", text: $store.sessionSelector)
                HStack {
                    Button("切换项目", systemImage: "scope") { store.useProject() }
                    Button("进入会话", systemImage: "rectangle.stack") { store.useSession() }
                }
                .buttonStyle(.bordered)
            }

            Section("输入") {
                TextEditor(text: $store.prompt)
                    .frame(minHeight: 120)
                HStack {
                    Button("发送", systemImage: "paperplane.fill") { store.sendPrompt() }
                        .buttonStyle(.borderedProminent)
                    Button("引导", systemImage: "arrow.turn.down.right") { store.insertPrompt() }
                        .buttonStyle(.bordered)
                    Button("停止", systemImage: "stop.circle", role: .destructive) { store.stopCurrent() }
                        .buttonStyle(.bordered)
                }
            }

            if let activeTask = store.activeTask {
                Section("当前任务") {
                    taskRow(activeTask)
                }
            }

            Section("思考") {
                if store.thinkingTranscript.isEmpty {
                    Text(store.activeTask == nil ? "无运行任务" : "等待思考流")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.thinkingTranscript)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("输出") {
                if store.outputTranscript.isEmpty {
                    Text(store.activeTask == nil ? "无输出" : "等待输出流")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.outputTranscript)
                        .textSelection(.enabled)
                }
            }

            Section("会话") {
                Button("同步会话", systemImage: "arrow.triangle.2.circlepath") {
                    store.syncSessionChats()
                }
                ForEach(store.mappings) { mapping in
                    if let sessionID = mapping.session?.session_id ?? mapping.binding.session_id {
                        NavigationLink(value: sessionID) {
                            sessionMappingRow(mapping)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            store.selectSession(sessionID)
                        })
                    } else {
                        sessionMappingRow(mapping)
                    }
                }
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.session_id) {
                        sessionRow(session)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        store.selectSession(session.session_id)
                    })
                }
            }

            Section("最近事件") {
                ForEach(store.recentEvents) { event in
                    eventRow(event)
                }
            }
        }
    }

    private var historySessionsContent: some View {
        List {
            Section("\(activeCodexSource.title) 历史") {
                if activeSourceSessions.isEmpty && activeSourceMappings.isEmpty {
                    Text("当前 Codex 源没有返回历史会话")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedActiveSourceSessions) { session in
                        Button {
                            openHistorySession(session.session_id)
                        } label: {
                            historySessionRow(
                                title: historySummaryTitle(for: session),
                                subtitle: duplicateHistoryTime(for: session),
                                status: session.status,
                                isSelected: session.session_id == displaySessionID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("切换到该 Codex 会话")
                    }
                    ForEach(activeSourceMappings) { mapping in
                        if let sessionID = mapping.session?.session_id ?? mapping.binding.session_id {
                            Button {
                                openHistorySession(sessionID)
                            } label: {
                                historySessionRow(
                                    title: historySummaryTitle(
                                        title: mapping.session?.title ?? mapping.binding.title,
                                        sessionID: sessionID
                                    ),
                                    subtitle: nil,
                                    status: mapping.session?.status ?? mapping.binding.session_policy,
                                    isSelected: sessionID == displaySessionID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("切换到该 Codex 会话")
                        }
                    }
                }
            }
        }
        .platformListStyle()
        .navigationTitle("历史会话")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: displayedActiveSourceSessions.map(\.session_id).joined(separator: "|")) {
            await store.loadHistorySummaries(for: displayedActiveSourceSessions)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .accessibilityLabel("刷新历史会话")
            }
        }
    }

    private func openHistorySession(_ sessionID: String) {
        store.selectSession(sessionID)
        navigationPath.append(sessionID)
    }

    private func sessionDetailContent(sessionID: String) -> some View {
        VStack(spacing: 0) {
            let bottomID = "codex-bottom-\(sessionID)"
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let v1Messages = store.visibleCodexMessages(for: sessionID)
                        if !v1Messages.isEmpty {
                            ForEach(v1Messages) { message in
                                codexMessageBubble(message)
                            }
                        } else {
                            let tasks = store.tasks(for: sessionID)
                            if tasks.isEmpty {
                                Text(store.isLoadingSessionEvents ? "加载中" : "暂无消息")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 240)
                            } else {
                                ForEach(tasks) { task in
                                    conversationTaskRow(task, events: store.events(for: sessionID).filter { $0.task_id == task.task_id })
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.visibleCodexMessages(for: sessionID).count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: store.visibleCodexMessages(for: sessionID).last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            Divider()
            chatComposer
        }
        .background(Color.fleetPlatform(.systemBackground))
        .navigationTitle(shortSessionTitle(for: sessionID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.fleetPlatform(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: sessionID) {
            var shouldRequestHistoryLoad = true
            while !Swift.Task.isCancelled {
                let session = store.sessions.first(where: { $0.session_id == sessionID })
                if store.isV1Runtime || (session?.isCodexRuntimeCandidate ?? false) {
                    let endpointID = session?.endpoint_id ?? store.endpointID
                    await store.loadHistoryV1Messages(endpointID: endpointID, sessionID: sessionID, requestHistoryLoad: shouldRequestHistoryLoad)
                    shouldRequestHistoryLoad = false
                } else {
                    await store.loadSessionEvents(sessionID: sessionID)
                }
                let isCurrentRunningSession = sessionID == store.sessionSelector && store.hasRunningCodexMessage(in: sessionID)
                let pollDelay: UInt64 = isCurrentRunningSession ? 100_000_000 : 2_500_000_000
                try? await Swift.Task.sleep(nanoseconds: pollDelay)
            }
        }
    }

    private var overviewContent: some View {
        Group {
            Section("状态") {
                LabeledContent("连接") { Text(store.statusText).foregroundStyle(statusColor) }
                LabeledContent("摘要") { Text(store.summaryText).foregroundStyle(.secondary) }
                LabeledContent("流式") { Text(store.streamStatusText).foregroundStyle(.secondary) }
                Button {
                    store.refresh()
                } label: {
                    Label(store.isRefreshing ? "刷新中" : "刷新公司 Codex", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }

            if let activeTask = store.activeTask {
                Section("当前任务") {
                    taskRow(activeTask)
                    Button("停止当前任务", role: .destructive) {
                        store.stopCurrent()
                    }
                }
            }

            if let binding = store.bindingForCurrentChat {
                Section("当前绑定") {
                    LabeledContent("聊天") { Text(binding.chat_id) }
                    LabeledContent("项目") { Text(binding.project_alias ?? "-") }
                    LabeledContent("会话") { Text(binding.session_id ?? "-") }
                    LabeledContent("策略") { Text(binding.session_policy ?? "-") }
                }
            } else {
                Section("当前绑定") {
                    Text("尚未绑定聊天入口")
                        .foregroundStyle(.secondary)
                    Button("去绑定目标") {
                        mode = .target
                    }
                }
            }

            Section("最近任务") {
                ForEach(store.tasks.prefix(5)) { task in
                    taskRow(task)
                }
            }
        }
    }

    private var streamContent: some View {
        Group {
            Section("流式状态") {
                LabeledContent("任务") { Text(store.streamingTaskID ?? store.activeTask?.task_id ?? "-") }
                LabeledContent("状态") { Text(store.streamStatusText).foregroundStyle(.secondary) }
                HStack {
                    Button("刷新", systemImage: "arrow.clockwise") { store.refresh() }
                    Button("打断", role: .destructive) { store.stopCurrent() }
                }
                Button("新开对话", systemImage: "plus.message") { store.newConversation() }
            }

            Section("思考") {
                if store.thinkingTranscript.isEmpty {
                    Text("等待 Codex 思考流")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.thinkingTranscript)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("输出") {
                if store.outputTranscript.isEmpty {
                    Text("等待 Codex 输出流")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.outputTranscript)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            Section("事件") {
                ForEach(store.recentEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.type).font(.headline)
                            Spacer()
                            Text("#\(event.event_id)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = event.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var targetContent: some View {
        Group {
            Section("选择目标") {
                TextField("Project Alias", text: $store.projectAlias)
                TextField("Session Selector", text: $store.sessionSelector)
                TextField("Endpoint ID", text: $store.endpointID)
                Picker("Session Policy", selection: $store.sessionPolicy) {
                    Text("项目默认").tag("project-default")
                    Text("固定会话").tag("fixed-session")
                }
                .pickerStyle(.segmented)
                Picker("Project Mode", selection: $store.projectMode) {
                    Text("vscode").tag("vscode")
                    Text("headless").tag("headless")
                }
                .pickerStyle(.segmented)
            }

            Section("动作") {
                Button("使用项目", systemImage: "scope") { store.useProject() }
                Button("使用会话", systemImage: "rectangle.stack") { store.useSession() }
                Button("清空目标", systemImage: "xmark.circle") { store.clearTarget() }
            }

            Section("聊天绑定") {
                TextField("Channel", text: $store.channel)
                TextField("Chat ID", text: $store.chatID)
                TextField("Owner Chat ID", text: $store.ownerChatID)
                Button("绑定聊天入口", systemImage: "link") { store.bindChat() }
                Button("解除绑定", systemImage: "link.badge.minus") { store.unbindChat() }
                Button("同步会话映射", systemImage: "arrow.triangle.2.circlepath") { store.syncSessionChats() }
            }

            if let binding = store.bindingForCurrentChat {
                Section("绑定结果") {
                    LabeledContent("项目") { Text(binding.project_alias ?? "-") }
                    LabeledContent("会话") { Text(binding.session_id ?? "-") }
                    LabeledContent("更新时间") { Text(binding.updated_at ?? "-") }
                }
            }
        }
    }

    private var sessionsContent: some View {
        Group {
            Section("会话映射") {
                Button("同步会话映射", systemImage: "arrow.triangle.2.circlepath") {
                    store.syncSessionChats()
                }
                ForEach(store.mappings) { mapping in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(mapping.number). \(mapping.session?.title ?? mapping.binding.session_id ?? mapping.binding.chat_id)")
                            .font(.headline)
                        Text(mapping.binding.chat_id)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(mapping.session?.cwd ?? mapping.session?.rollout_path ?? "-")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("全部会话") {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title ?? session.session_id).font(.headline)
                        Text(session.session_id).font(.footnote).foregroundStyle(.secondary)
                        Text(session.cwd ?? session.rollout_path ?? "-")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var tasksContent: some View {
        Group {
            Section("发起工作") {
                TextEditor(text: $store.prompt)
                    .frame(minHeight: 120)
                HStack {
                    Button("发任务") { store.sendPrompt() }
                        .buttonStyle(.borderedProminent)
                    Button("引导任务") { store.insertPrompt() }
                        .buttonStyle(.bordered)
                    Button("停止") { store.stopCurrent() }
                        .buttonStyle(.bordered)
                }
                Button("新开对话", systemImage: "plus.message") { store.newConversation() }
            }

            Section("任务列表") {
                ForEach(store.tasks) { task in
                    taskRow(task)
                }
            }

            Section("最近事件") {
                ForEach(store.recentEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.type).font(.headline)
                            Spacer()
                            Text(event.created_at ?? "-").font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = event.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var settingsContent: some View {
        Group {
            Section("连接") {
                SecureField("Token", text: $store.token)
                TextField("Profile", text: $store.profile)
                Button("刷新连接", systemImage: "arrow.clockwise") { store.refresh() }
            }

            Section("登记项目") {
                TextField("Project Alias", text: $store.projectAlias)
                TextField("Project Path", text: $store.projectPath)
                TextField("Endpoint ID", text: $store.endpointID)
                Picker("Project Mode", selection: $store.projectMode) {
                    Text("vscode").tag("vscode")
                    Text("headless").tag("headless")
                }
                .pickerStyle(.segmented)
                Button("登记项目", systemImage: "folder.badge.plus") { store.registerProject() }
            }

            Section("项目") {
                ForEach(store.projects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.alias).font(.headline)
                        Text(project.path).font(.footnote).foregroundStyle(.secondary)
                        Text("\(project.endpoint_id) · \(project.mode ?? "vscode")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        store.statusText == "连接失败" ? .red : .secondary
    }

    private func historySessionRow(title: String, subtitle: String?, status: String?, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            let visibleStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let visibleStatus,
               !visibleStatus.isEmpty,
               visibleStatus.localizedCaseInsensitiveCompare("synced") != .orderedSame {
                Text(visibleStatus)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.fleetPlatform(.secondarySystemBackground), in: Capsule())
            }
        }
        .padding(.vertical, 8)
    }

    private func sessionTitle(for sessionID: String) -> String {
        if let session = store.sessions.first(where: { $0.session_id == sessionID }) {
            return sessionDisplayTitle(session)
        }
        return synthesizedSessionTitle(for: sessionID)
    }

    private func shortSessionTitle(for sessionID: String) -> String {
        if let session = store.sessions.first(where: { $0.session_id == sessionID }) {
            return shortHistoryTitle(for: session)
        }
        return shortHistoryTitle(title: nil, sessionID: sessionID)
    }

    private func sessionDisplayTitle(_ session: FleetSession) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? session.session_id : title
    }

    private func shortHistoryTitle(for session: FleetSession) -> String {
        shortHistoryTitle(title: session.title, sessionID: session.session_id)
    }

    private func historySummaryTitle(for session: FleetSession) -> String {
        historySummaryTitle(title: session.title, sessionID: session.session_id)
    }

    private func duplicateHistoryTime(for session: FleetSession) -> String? {
        let title = historySummaryTitle(for: session)
        let duplicateCount = displayedActiveSourceSessions.reduce(0) { count, other in
            count + (historySummaryTitle(for: other) == title ? 1 : 0)
        }
        guard duplicateCount > 1 else { return nil }
        return compactSessionTime(session.updated_at)
    }

    private func historySummaryTitle(title: String?, sessionID: String) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty && !trimmedTitle.hasPrefix("2026-") {
            return shortHistoryTitle(title: title, sessionID: sessionID)
        }
        if let summary = store.historySessionSummaries[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        return shortHistoryTitle(title: title, sessionID: sessionID)
    }

    private func shortHistoryTitle(title: String?, sessionID: String) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty && !trimmedTitle.hasPrefix("2026-") {
            return trimmedTitle
        }
        if sessionID == "linux-vscode-main" {
            return "当前 Codex 对话"
        }
        let raw = trimmedTitle.isEmpty ? sessionID : trimmedTitle
        if let range = raw.range(of: #"2026-\d{2}-\d{2}T\d{2}-\d{2}"#, options: .regularExpression) {
            let value = String(raw[range])
            let parts = value.replacingOccurrences(of: "T", with: "-").split(separator: "-")
            if parts.count >= 5 {
                return "\(parts[1])-\(parts[2]) \(parts[3]):\(parts[4])"
            }
        }
        return raw
    }

    private func compactSessionTime(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 16 else { return nil }
        let monthDayStart = normalized.index(normalized.startIndex, offsetBy: 5)
        let monthDayEnd = normalized.index(monthDayStart, offsetBy: 5, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let timeStart = normalized.index(normalized.startIndex, offsetBy: 11, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let timeEnd = normalized.index(timeStart, offsetBy: 5, limitedBy: normalized.endIndex) ?? normalized.endIndex
        guard monthDayStart < monthDayEnd, timeStart < timeEnd else { return nil }
        return "\(normalized[monthDayStart..<monthDayEnd]) \(normalized[timeStart..<timeEnd])"
    }

    private func sessionLocationText(_ session: FleetSession) -> String {
        let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cwd.isEmpty { return cwd }
        let rollout = session.rollout_path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rollout.isEmpty { return rollout }
        return session.endpoint_id
    }

    private func sessionMappingRow(_ mapping: FleetSessionMapping) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(mapping.number). \(mapping.session?.title ?? mapping.binding.session_id ?? mapping.binding.chat_id)")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(mapping.binding.chat_id)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(mapping.session?.cwd ?? mapping.session?.rollout_path ?? "-")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func sessionRow(_ session: FleetSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title ?? session.session_id)
                    .font(.headline)
                Spacer()
                Text(session.status ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(session.session_id)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(session.cwd ?? session.rollout_path ?? "-")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func eventRow(_ event: FleetEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.type).font(.headline)
                Spacer()
                Text("#\(event.event_id)").font(.caption).foregroundStyle(.secondary)
            }
            if let message = event.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private func codexMessageRow(_ message: FleetCodexMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.isUser ? "你" : "Codex")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = store.codexMessageStates[message.message_id]?.status ?? message.status,
                   !status.isEmpty {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            FleetRichMessageText(text: message.text, tint: .primary)
        }
        .padding(.vertical, 4)
    }

    private func codexMessageBubble(_ message: FleetCodexMessage) -> some View {
        let state = store.codexMessageStates[message.message_id]?.status ?? message.status ?? ""
        let suffix = !message.isUser && ["streaming", "running", "queued"].contains(state) ? "\n\n…" : ""
        return chatBubbleView(
            FleetChatBubble(
                id: message.id,
                title: message.isUser ? "你" : "Codex",
                body: message.text + suffix,
                isUser: message.isUser,
                tint: state == "failed" ? .red : .primary
            )
        )
    }

    private func conversationTaskRow(_ task: FleetTask, events: [FleetEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("你")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(task.phase ?? task.status ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FleetRichMessageText(text: task.prompt ?? "-", tint: .primary)

            ForEach(events.filter { conversationEventTypes.contains($0.type) }) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversationEventTitle(event.type))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let message = event.message, !message.isEmpty {
                        FleetRichMessageText(
                            text: message,
                            tint: event.type == "codex.thinking.delta" ? .secondary : .primary,
                            compact: event.type == "codex.thinking.delta"
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var conversationEventTypes: Set<String> {
        [
            "codex.thinking.delta",
            "codex.output.delta",
            "codex.error",
            "codex.diagnostic",
            "task.completed",
            "task.interrupted",
            "task.failed"
        ]
    }

    private func conversationEventTitle(_ type: String) -> String {
        switch type {
        case "codex.thinking.delta": return "思考"
        case "codex.output.delta": return "Codex"
        case "codex.error": return "错误"
        case "codex.diagnostic": return "诊断"
        case "task.completed": return "完成"
        case "task.interrupted": return "已打断"
        case "task.failed": return "失败"
        default: return type
        }
    }

    private func taskRow(_ task: FleetTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.task_id).font(.headline)
                Spacer()
                Text(task.phase ?? task.status ?? "-").foregroundStyle(.secondary)
            }
            if let model = task.model, !model.isEmpty {
                Text([model, task.reasoning_effort].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(task.prompt ?? "-")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let summary = task.last_summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
