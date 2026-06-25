import Combine
import Foundation
import SwiftUI
import UserNotifications

#if os(iOS)
private extension Color {
    static func platform(_ color: UIColor) -> Color { Color(uiColor: color) }
}
#elseif os(macOS)
private extension Color {
    static func platform(_ color: NSColor) -> Color { Color(nsColor: color) }
}
#endif

extension View {
    @ViewBuilder func platformListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self
        #endif
    }

    @ViewBuilder func platformTextInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder func platformKeyboardTypeURL() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }
}

enum MainAppMode {
    case knowledge
    case workbench
}

struct ContentView: View {
    @StateObject private var store = KnowledgeAppStore()
    @State private var mode: MainAppMode = .knowledge

    var body: some View {
        Group {
            switch mode {
            case .knowledge:
                ChatView {
                    mode = .workbench
                }
            case .workbench:
                FleetWorkbenchView {
                    mode = .knowledge
                }
            }
        }
        .environmentObject(store)
        .tint(.primary)
    }
}

struct ChatContext: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var detail: String
    var systemPrompt: String
    var accentName: String
    var enableThinking = false
    var contextSummary = ""
    var summarizedThroughMessageID: UUID?
    var summaryUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case detail
        case systemPrompt
        case accentName
        case enableThinking
        case contextSummary
        case summarizedThroughMessageID
        case summaryUpdatedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        systemPrompt: String,
        accentName: String,
        enableThinking: Bool = false,
        contextSummary: String = "",
        summarizedThroughMessageID: UUID? = nil,
        summaryUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.systemPrompt = systemPrompt
        self.accentName = accentName
        self.enableThinking = enableThinking
        self.contextSummary = contextSummary
        self.summarizedThroughMessageID = summarizedThroughMessageID
        self.summaryUpdatedAt = summaryUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decode(String.self, forKey: .detail)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        accentName = try container.decode(String.self, forKey: .accentName)
        enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary) ?? ""
        summarizedThroughMessageID = try container.decodeIfPresent(UUID.self, forKey: .summarizedThroughMessageID)
        summaryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .summaryUpdatedAt)
    }

    var accent: Color {
        switch accentName {
        case "orange": return .orange
        case "indigo": return .indigo
        case "pink": return .pink
        default: return .teal
        }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var contextID: UUID
}

struct ScheduledKnowledgeTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var prompt: String
    var fireDate: Date
    var contextID: UUID
    var sendsNotification: Bool
    var isEnabled: Bool
}

struct KnowledgeServiceSettings: Codable, Equatable {
    static let codexBaseURL = "http://cli.yuqing.me:8080/v1"
    static let defaultModel = "gpt-5.4-mini"
    static let availableModels = ["gpt-5.4-mini", "gpt-5.4"]
    static let codexAPIKey = ProcessInfo.processInfo.environment["MKB_CODEX_API_KEY"] ?? ""
    static let defaultPersonalMemoryURL = "http://127.0.0.1:18188"

    var useMockFallback = true
    var autoSwitchContext = true
    var model = Self.defaultModel
    var personalMemoryURL = Self.defaultPersonalMemoryURL
    var personalMemoryEnabled = true
    var contextBudgetCharacters = 24000
    var compressionTargetCharacters = 3600
    var legacyEnableThinking: Bool?

    var baseURL: String { Self.codexBaseURL }
    var apiKey: String { Self.codexAPIKey }

    enum CodingKeys: String, CodingKey {
        case baseURL
        case model
        case apiKey
        case useMockFallback
        case autoSwitchContext
        case personalMemoryURL
        case personalMemoryEnabled
        case contextBudgetCharacters
        case compressionTargetCharacters
        case legacyEnableThinking = "enableThinking"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useMockFallback = try container.decodeIfPresent(Bool.self, forKey: .useMockFallback) ?? true
        autoSwitchContext = try container.decodeIfPresent(Bool.self, forKey: .autoSwitchContext) ?? true
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        personalMemoryURL = try container.decodeIfPresent(String.self, forKey: .personalMemoryURL) ?? Self.defaultPersonalMemoryURL
        personalMemoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .personalMemoryEnabled) ?? true
        contextBudgetCharacters = try container.decodeIfPresent(Int.self, forKey: .contextBudgetCharacters) ?? 24000
        compressionTargetCharacters = try container.decodeIfPresent(Int.self, forKey: .compressionTargetCharacters) ?? 3600
        legacyEnableThinking = try container.decodeIfPresent(Bool.self, forKey: .legacyEnableThinking)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(useMockFallback, forKey: .useMockFallback)
        try container.encode(autoSwitchContext, forKey: .autoSwitchContext)
        try container.encode(model, forKey: .model)
        try container.encode(personalMemoryURL, forKey: .personalMemoryURL)
        try container.encode(personalMemoryEnabled, forKey: .personalMemoryEnabled)
        try container.encode(contextBudgetCharacters, forKey: .contextBudgetCharacters)
        try container.encode(compressionTargetCharacters, forKey: .compressionTargetCharacters)
    }

    var migratedFromOldDefaults: KnowledgeServiceSettings {
        var copy = self
        if copy.personalMemoryURL.isEmpty {
            copy.personalMemoryURL = Self.defaultPersonalMemoryURL
        }
        if copy.model.isEmpty {
            copy.model = Self.defaultModel
        }
        copy.contextBudgetCharacters = min(max(copy.contextBudgetCharacters, 8000), 120000)
        copy.compressionTargetCharacters = min(max(copy.compressionTargetCharacters, 1200), 12000)
        copy.legacyEnableThinking = nil
        return copy
    }
}

struct AppSnapshot: Codable {
    var contexts: [ChatContext]
    var selectedContextID: UUID
    var messages: [ChatMessage]
    var tasks: [ScheduledKnowledgeTask]
    var settings: KnowledgeServiceSettings
}

struct ContextCompressionResult {
    var summary: String
    var throughMessageID: UUID
}

struct ContextCompressionPlan {
    var summaryRange: ClosedRange<Int>
}

@MainActor
final class KnowledgeAppStore: ObservableObject {
    private static let defaultContexts: [ChatContext] = [
        ChatContext(
            name: "默认知识库",
            detail: "常规问答、摘要、个人记忆",
            systemPrompt: "你是一个接入 Codex API 与个人记忆库的中文助手，回答要准确、简洁、能落地。",
            accentName: "teal"
        ),
        ChatContext(
            name: "代码助手",
            detail: "Swift、Python、脚本和工程排错",
            systemPrompt: "你是一个资深工程助手，优先给出可执行步骤、代码和验证方法。",
            accentName: "indigo"
        ),
        ChatContext(
            name: "学习计划",
            detail: "整理笔记、复盘、生成任务",
            systemPrompt: "你是一个耐心的学习教练，把复杂知识拆成清晰步骤。",
            accentName: "orange"
        )
    ]

    @Published var contexts: [ChatContext] {
        didSet { persistIfReady() }
    }
    @Published var selectedContextID: UUID {
        didSet { persistIfReady() }
    }
    @Published var messages: [ChatMessage] = [] {
        didSet { persistIfReady() }
    }
    @Published var tasks: [ScheduledKnowledgeTask] = [] {
        didSet { persistIfReady() }
    }
    @Published var settings = KnowledgeServiceSettings() {
        didSet { persistIfReady() }
    }
    @Published var draft = ""
    @Published var isSending = false
    @Published var banner: String?
    @Published var notificationStatus = "未请求"
    @Published var personalMemoryStatus = "未检查"

    private let client = CodexAPIClient()
    private let personalMemoryClient = PersonalMemoryClient()
    private let thinkingPlaceholder = "正在思考..."
    private var isReadyToPersist = false
    private var persistenceURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("MKB-AppSnapshot.json")
    }

    init() {
        let snapshot = Self.loadSnapshot(from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MKB-AppSnapshot.json"))
        let starterContexts = snapshot?.contexts.isEmpty == false ? snapshot?.contexts ?? Self.defaultContexts : Self.defaultContexts
        let firstID = starterContexts[0].id

        contexts = starterContexts
        selectedContextID = snapshot?.selectedContextID ?? firstID
        if !starterContexts.contains(where: { $0.id == selectedContextID }) {
            selectedContextID = firstID
        }
        messages = snapshot?.messages ?? [
            ChatMessage(role: .assistant, text: "我已经接入 Codex API，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。", contextID: firstID)
        ]
        refreshUntitledContextTitlesFromMessages()
        migrateCodexDefaults()
        tasks = snapshot?.tasks ?? [
            ScheduledKnowledgeTask(
                title: "早间知识摘要",
                prompt: "总结今天最重要的待办和知识库更新。",
                fireDate: Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now,
                contextID: firstID,
                sendsNotification: true,
                isEnabled: true
            )
        ]
        settings = (snapshot?.settings ?? KnowledgeServiceSettings()).migratedFromOldDefaults
        isReadyToPersist = true
        migrateGlobalThinkingIfNeeded(from: snapshot)
        persistIfReady()
        refreshNotificationStatus()
    }

    var selectedContext: ChatContext {
        contexts.first(where: { $0.id == selectedContextID }) ?? contexts[0]
    }

    var visibleMessages: [ChatMessage] {
        messages.filter { $0.contextID == selectedContextID }
    }

    var allContextIDs: Set<UUID> {
        Set(contexts.map(\.id))
    }

    var untitledContextIDs: Set<UUID> {
        Set(contexts.filter(isUntitledContext).map(\.id))
    }

    var selectedContextThinkingBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.selectedContext.enableThinking ?? false
            },
            set: { [weak self] newValue in
                self?.setThinking(newValue, for: self?.selectedContextID)
            }
        )
    }


    private func migrateCodexDefaults() {
        for index in contexts.indices {
            contexts[index].systemPrompt = contexts[index].systemPrompt
                .replacingOccurrences(of: "你是一个接入本机 Qwen 3.6 35B 知识库的中文助手，回答要准确、简洁、能落地。", with: "你是一个接入 Codex API 与个人记忆库的中文助手，回答要准确、简洁、能落地。")
                .replacingOccurrences(of: "你是一个接入 Codex API、个人记忆库与在线工作台的中文助手，回答要准确、简洁、能落地。", with: "你是一个接入 Codex API 与个人记忆库的中文助手，回答要准确、简洁、能落地。")
        }
        for index in messages.indices where messages[index].role == .assistant {
            messages[index].text = messages[index].text
                .replacingOccurrences(of: "我已经准备好连接你的本机 Qwen 知识库。选择上下文后直接提问就行。", with: "我已经接入 Codex API，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。")
                .replacingOccurrences(of: "我已经接入本机 Codex API，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。", with: "我已经接入 Codex API，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。")
                .replacingOccurrences(of: "我已经接入在线工作台，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。", with: "我已经接入 Codex API，默认使用 gpt-5.4-mini。选择上下文后直接提问就行。")
                .replacingOccurrences(of: "我是接入本机 Qwen 3.6 35B 知识库的中文助手。", with: "我是接入 Codex API 的中文助手，当前固定使用 gpt-5.4-mini。")
                .replacingOccurrences(of: "我是接入本机 Codex API 的中文助手，当前固定使用 gpt-5.4-mini。", with: "我是接入 Codex API 的中文助手，当前固定使用 gpt-5.4-mini。")
                .replacingOccurrences(of: "我是接入在线工作台的中文助手，当前固定使用 gpt-5.4-mini。", with: "我是接入 Codex API 的中文助手，当前固定使用 gpt-5.4-mini。")
        }
    }

    func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        draft = ""
        send(trimmed)
    }

    func send(_ text: String) {
        let context = contextForOutgoingText(text)
        let userMessage = ChatMessage(role: .user, text: text, contextID: context.id)
        messages.append(userMessage)
        logToPersonalMemory(userMessage, context: context)
        refreshContextTitleIfNeeded(contextID: context.id, text: text)
        isSending = true

        Task {
            var assistantMessageID: UUID?
            do {
                let placeholder = context.enableThinking ? thinkingPlaceholder : ""
                var assistantMessage = ChatMessage(role: .assistant, text: placeholder, contextID: context.id)
                assistantMessageID = assistantMessage.id
                messages.append(assistantMessage)
                if let summary = try await compressContextIfNeeded(for: context.id) {
                    contextSummaryDidChange(summary, for: context.id)
                }
                guard let currentContext = contexts.first(where: { $0.id == context.id }) else {
                    throw URLError(.cancelled)
                }
                let answer = try await client.send(
                    text: text,
                    context: currentContext,
                    history: conversationHistory(for: currentContext.id),
                    settings: settings,
                    enableThinking: currentContext.enableThinking
                ) { [self] partial in
                    assistantMessage.text = partial
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                        self.messages[index] = assistantMessage
                    }
                }
                if let index = self.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    self.messages[index].text = answer
                }
                logToPersonalMemory(ChatMessage(id: assistantMessage.id, role: .assistant, text: answer, date: assistantMessage.date, contextID: context.id), context: currentContext)
            } catch {
                if let assistantMessageID {
                    messages.removeAll { $0.id == assistantMessageID && ($0.text.isEmpty || $0.text == thinkingPlaceholder) }
                }
                if settings.useMockFallback {
                    let fallback = ChatMessage(role: .assistant, text: mockAnswer(for: text, context: context, error: error), contextID: context.id)
                    messages.append(fallback)
                    logToPersonalMemory(fallback, context: context)
                } else {
                    banner = "请求失败：\(error.localizedDescription)"
                }
            }
            isSending = false
        }
    }

    private func conversationHistory(for contextID: UUID) -> [ChatMessage] {
        messages
            .filter { $0.contextID == contextID && $0.role != .system }
            .sorted { $0.date < $1.date }
    }

    private func compressContextIfNeeded(for contextID: UUID) async throws -> ContextCompressionResult? {
        guard let context = contexts.first(where: { $0.id == contextID }) else { return nil }
        let history = conversationHistory(for: contextID)
        guard shouldCompress(context: context, history: history),
              let plan = compressionPlan(for: context, history: history) else {
            return nil
        }
        let messagesToSummarize = Array(history[plan.summaryRange])
        guard !messagesToSummarize.isEmpty else { return nil }
        let summary = try await client.summarize(
            context: context,
            priorSummary: context.contextSummary,
            messages: messagesToSummarize,
            settings: settings,
            targetCharacters: settings.compressionTargetCharacters
        )
        guard let lastID = messagesToSummarize.last?.id else { return nil }
        return ContextCompressionResult(summary: summary, throughMessageID: lastID)
    }

    private func shouldCompress(context: ChatContext, history: [ChatMessage]) -> Bool {
        estimatedPayloadCharacters(context: context, history: history) > settings.contextBudgetCharacters
    }

    private func compressionPlan(for context: ChatContext, history: [ChatMessage]) -> ContextCompressionPlan? {
        guard history.count > 8 else { return nil }
        let lastSummarizedIndex = context.summarizedThroughMessageID.flatMap { id in
            history.firstIndex(where: { $0.id == id })
        } ?? -1
        let recentStart = recentWindowStartIndex(context: context, history: history)
        let boundary = max(lastSummarizedIndex + 1, recentStart - 1)
        guard boundary > lastSummarizedIndex,
              boundary >= 0,
              boundary < history.count - 2 else {
            return nil
        }
        return ContextCompressionPlan(summaryRange: (lastSummarizedIndex + 1)...boundary)
    }

    private func recentWindowStartIndex(context: ChatContext, history: [ChatMessage]) -> Int {
        guard !history.isEmpty else { return 0 }
        let fixedCost = context.systemPrompt.count + context.contextSummary.count + settings.compressionTargetCharacters + 240
        let recentBudget = max(1600, settings.contextBudgetCharacters - fixedCost)
        var runningCost = 0
        var startIndex = history.count - 1
        for index in stride(from: history.count - 1, through: 0, by: -1) {
            let nextCost = estimatedMessageCharacters(history[index])
            if runningCost + nextCost > recentBudget, index < history.count - 4 {
                break
            }
            runningCost += nextCost
            startIndex = index
        }
        return startIndex
    }

    private func estimatedPayloadCharacters(context: ChatContext, history: [ChatMessage]) -> Int {
        let summaryCost = context.contextSummary.isEmpty ? 0 : context.contextSummary.count + 160
        return context.systemPrompt.count + summaryCost + history.reduce(0) { total, message in
            total + estimatedMessageCharacters(message)
        }
    }

    private func estimatedMessageCharacters(_ message: ChatMessage) -> Int {
        message.text.count + 24
    }

    private func contextSummaryDidChange(_ result: ContextCompressionResult, for contextID: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == contextID }) else { return }
        contexts[index].contextSummary = result.summary
        contexts[index].summarizedThroughMessageID = result.throughMessageID
        contexts[index].summaryUpdatedAt = Date()
    }

    func addContext() {
        let next = ChatContext(
            name: "未命名主题",
            detail: "发送第一条消息后自动命名",
            systemPrompt: "你是一个专注当前上下文的中文知识库助手。",
            accentName: ["teal", "indigo", "orange", "pink"].randomElement() ?? "teal"
        )
        contexts.append(next)
        selectedContextID = next.id
        messages.append(ChatMessage(role: .assistant, text: "新上下文已准备好。第一条问题会自动生成清晰标题。", contextID: next.id))
    }

    func messageCount(for contextID: UUID) -> Int {
        messages.filter { $0.contextID == contextID }.count
    }

    func setThinking(_ isEnabled: Bool, for contextID: UUID?) {
        guard let contextID,
              let index = contexts.firstIndex(where: { $0.id == contextID }) else {
            return
        }
        contexts[index].enableThinking = isEnabled
    }

    func deletableContextIDs(from selectedIDs: Set<UUID>) -> Set<UUID> {
        guard !selectedIDs.isEmpty else { return [] }
        var deletable = selectedIDs.intersection(allContextIDs)
        if contexts.allSatisfy({ deletable.contains($0.id) }), let firstContext = contexts.first {
            deletable.remove(firstContext.id)
        }
        return deletable
    }

    func deleteContexts(with selectedIDs: Set<UUID>) {
        let deletingIDs = deletableContextIDs(from: selectedIDs)
        guard !deletingIDs.isEmpty else {
            banner = "至少保留一个上下文"
            return
        }
        guard let fallback = contexts.first(where: { !deletingIDs.contains($0.id) }) else { return }

        contexts.removeAll { deletingIDs.contains($0.id) }
        messages.removeAll { deletingIDs.contains($0.contextID) }
        for index in tasks.indices where deletingIDs.contains(tasks[index].contextID) {
            tasks[index].contextID = fallback.id
        }
        if deletingIDs.contains(selectedContextID) {
            selectedContextID = fallback.id
        }
        banner = "已删除 \(deletingIDs.count) 个上下文"
    }

    func clearCurrentChat() {
        messages.removeAll { $0.contextID == selectedContextID }
        messages.append(ChatMessage(role: .assistant, text: "当前上下文已清空，可以重新开始。", contextID: selectedContextID))
    }

    func addTask() {
        let task = ScheduledKnowledgeTask(
            title: "新定时任务",
            prompt: "到时间后提醒我查看知识库。",
            fireDate: Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now,
            contextID: selectedContextID,
            sendsNotification: true,
            isEnabled: true
        )
        tasks.insert(task, at: 0)
        scheduleNotification(for: task)
    }

    func updateTask(_ task: ScheduledKnowledgeTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        scheduleNotification(for: task)
    }

    func deleteTasks(at offsets: IndexSet) {
        for index in offsets {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [tasks[index].id.uuidString])
        }
        tasks.remove(atOffsets: offsets)
    }

    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                notificationStatus = granted ? "已允许" : "已拒绝"
                banner = granted ? "通知权限已开启" : "通知权限被拒绝"
            } catch {
                banner = "通知权限请求失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshNotificationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                notificationStatus = "已允许"
            case .denied:
                notificationStatus = "已拒绝"
            case .notDetermined:
                notificationStatus = "未请求"
            @unknown default:
                notificationStatus = "未知"
            }
        }
    }

    func scheduleNotification(for task: ScheduledKnowledgeTask) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
        guard task.isEnabled, task.sendsNotification else { return }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = task.prompt
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: task.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func runTaskNow(_ task: ScheduledKnowledgeTask) {
        selectedContextID = task.contextID
        send(task.prompt)
    }

    func checkPersonalMemory() {
        Task {
            do {
                let status = try await personalMemoryClient.health(settings: settings)
                personalMemoryStatus = "已连接：\(status.memories) 条记忆"
                banner = personalMemoryStatus
            } catch {
                personalMemoryStatus = "连接失败"
                banner = "个人记忆服务失败：\(error.localizedDescription)"
            }
        }
    }

    private func logToPersonalMemory(_ message: ChatMessage, context: ChatContext) {
        guard settings.personalMemoryEnabled else { return }
        let settings = self.settings
        Task.detached {
            try? await PersonalMemoryClient().ingest(message: message, context: context, settings: settings)
        }
    }

    private func contextForOutgoingText(_ text: String) -> ChatContext {
        if isUntitledContext(selectedContext) {
            return selectedContext
        }
        guard settings.autoSwitchContext, let target = bestContext(for: text), target.id != selectedContextID else {
            return selectedContext
        }
        selectedContextID = target.id
        let notice = "已根据你的问题自动切换到「\(target.name)」。"
        if messages.last?.text != notice {
            messages.append(ChatMessage(role: .system, text: notice, contextID: target.id))
        }
        return target
    }

    private func refreshContextTitleIfNeeded(contextID: UUID, text: String) {
        guard let index = contexts.firstIndex(where: { $0.id == contextID }),
              isUntitledContext(contexts[index]) else {
            return
        }
        contexts[index].name = conciseContextTitle(from: text)
        contexts[index].detail = conciseContextDetail(from: text)
    }

    private func refreshUntitledContextTitlesFromMessages() {
        for index in contexts.indices where isUntitledContext(contexts[index]) {
            guard let firstUserMessage = messages.first(where: { $0.contextID == contexts[index].id && $0.role == .user }) else {
                continue
            }
            contexts[index].name = conciseContextTitle(from: firstUserMessage.text)
            contexts[index].detail = conciseContextDetail(from: firstUserMessage.text)
        }
    }

    private func isUntitledContext(_ context: ChatContext) -> Bool {
        context.name.hasPrefix("新上下文") ||
        context.name == "未命名主题" ||
        context.detail == "发送第一条消息后自动命名"
    }

    private func conciseContextTitle(from text: String) -> String {
        var title = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let removable = ["请", "帮我", "一下", "什么是", "为什么", "怎么", "如何", "能不能", "可以", "？", "?", "。", "，", ","]
        for token in removable {
            title = title.replacingOccurrences(of: token, with: "")
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = "新主题"
        }
        if title.count > 16 {
            title = String(title.prefix(16))
        }
        return title
    }

    private func conciseContextDetail(from text: String) -> String {
        let detail = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard detail.count > 28 else { return detail.isEmpty ? "独立会话" : detail }
        return String(detail.prefix(28)) + "..."
    }

    private func bestContext(for text: String) -> ChatContext? {
        let normalized = text.lowercased()
        if let explicit = contexts.first(where: { normalized.contains($0.name.lowercased()) }) {
            return explicit
        }

        let scored: [(context: ChatContext, score: Int)] = contexts.map { context in
            var score = 0
            let searchable = "\(context.name) \(context.detail) \(context.systemPrompt)".lowercased()
            for token in normalized.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
                if searchable.contains(token) {
                    score += 1
                }
            }
            if context.name.contains("代码"), ["代码", "swift", "xcode", "报错", "编译", "函数", "接口", "bug", "python"].contains(where: { normalized.contains($0) }) {
                score += 4
            }
            if context.name.contains("学习"), ["学习", "计划", "复盘", "笔记", "总结", "课程", "记忆"].contains(where: { normalized.contains($0) }) {
                score += 4
            }
            if context.name.contains("默认"), ["知识库", "资料", "检索", "查询", "问答"].contains(where: { normalized.contains($0) }) {
                score += 2
            }
            return (context: context, score: score)
        }
        .sorted { left, right in
            left.score > right.score
        }

        guard let best = scored.first, best.score >= 3 else { return nil }
        return best.context
    }

    private func persistIfReady() {
        guard isReadyToPersist else { return }
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let snapshot = AppSnapshot(
                contexts: contexts,
                selectedContextID: selectedContextID,
                messages: messages,
                tasks: tasks,
                settings: settings
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            banner = "保存失败：\(error.localizedDescription)"
        }
    }

    private static func loadSnapshot(from url: URL) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    private func migrateGlobalThinkingIfNeeded(from snapshot: AppSnapshot?) {
        guard let legacyValue = snapshot?.settings.legacyEnableThinking,
              legacyValue,
              contexts.allSatisfy({ !$0.enableThinking }) else {
            return
        }
        for index in contexts.indices {
            contexts[index].enableThinking = legacyValue
        }
    }

    private func mockAnswer(for text: String, context: ChatContext, error: Error) -> String {
        """
        \(context.name) 已收到：\(text)

        现在还没有连上本机 Codex API，所以先用离线模式回应。请确认这台 Mac 能访问 http://cli.yuqing.me:8080/v1/responses。

        技术信息：\(error.localizedDescription)
        """
    }
}

struct CodexAPIClient {
    struct ResponseRequest: Encodable {
        var model: String
        var input: [InputMessage]
        var instructions: String?
        var temperature: Double?
        var max_output_tokens: Int?
        var stream: Bool
        var store: Bool
    }

    struct InputMessage: Encodable {
        var role: String
        var content: String
    }

    struct ResponseBody: Decodable {
        struct OutputItem: Decodable {
            struct ContentItem: Decodable {
                var type: String?
                var text: String?
            }
            var type: String?
            var role: String?
            var content: [ContentItem]?
        }
        var output_text: String?
        var output: [OutputItem]?
    }

    struct StreamEvent: Decodable {
        var type: String
        var delta: String?
        var text: String?
    }

    func send(
        text: String,
        context: ChatContext,
        history: [ChatMessage],
        settings: KnowledgeServiceSettings,
        enableThinking: Bool,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try responsesURL(settings: settings)
        var payloadMessages = historyAfterSummaryBoundary(context: context, history: history).map {
            InputMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        if payloadMessages.last?.content != text {
            payloadMessages.append(InputMessage(role: "user", content: text))
        }

        let body = ResponseRequest(
            model: settings.model,
            input: payloadMessages,
            instructions: systemPrompt(for: context, enableThinking: enableThinking),
            temperature: 0.4,
            max_output_tokens: enableThinking ? 4096 : 1536,
            stream: true,
            store: false
        )
        let request = try makeRequest(url: url, settings: settings, body: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            return try await readEventStream(bytes: bytes, onPartial: onPartial)
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        let content = try decodeResponseText(from: data)
        await onPartial(content)
        return content
    }

    func summarize(
        context: ChatContext,
        priorSummary: String,
        messages: [ChatMessage],
        settings: KnowledgeServiceSettings,
        targetCharacters: Int
    ) async throws -> String {
        let url = try responsesURL(settings: settings)
        let transcript = messages.map { message in
            let speaker = message.role == .user ? "用户" : "助手"
            return "\(speaker)：\(message.text)"
        }.joined(separator: "\n\n")
        let summaryPrompt = """
        请把下面这段对话压缩成可继续对话的长期上下文摘要。
        要保留：用户目标、已经确认的事实、偏好、关键约束、未完成事项、重要代码/配置/数字。
        不要编造，不要输出寒暄。控制在 \(targetCharacters) 个中文字符以内。

        既有摘要：
        \(priorSummary.isEmpty ? "无" : priorSummary)

        新增对话：
        \(transcript)
        """
        let body = ResponseRequest(
            model: settings.model,
            input: [InputMessage(role: "user", content: summaryPrompt)],
            instructions: "你是对话上下文压缩器，只输出摘要本身。",
            temperature: 0.1,
            max_output_tokens: max(512, min(4096, targetCharacters * 2)),
            stream: false,
            store: false
        )
        let request = try makeRequest(url: url, settings: settings, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let content = try decodeResponseText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw URLError(.cannotParseResponse) }
        return content
    }

    private func responsesURL(settings: KnowledgeServiceSettings) throws -> URL {
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/responses") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func makeRequest<Body: Encodable>(url: URL, settings: KnowledgeServiceSettings, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func systemPrompt(for context: ChatContext, enableThinking: Bool) -> String {
        var prompt = context.systemPrompt
        if !context.contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += """

            以下是本对话较早历史的自动压缩摘要。它代表已经发生过的上下文，请在后续回答中继续遵守和使用：
            \(context.contextSummary)
            """
        }
        if enableThinking {
            prompt += "\n\n回答前先进行必要推理，但最终只输出清晰结论和可执行步骤。"
        }
        return prompt
    }

    private func historyAfterSummaryBoundary(context: ChatContext, history: [ChatMessage]) -> [ChatMessage] {
        guard let boundaryID = context.summarizedThroughMessageID,
              let boundaryIndex = history.firstIndex(where: { $0.id == boundaryID }),
              boundaryIndex + 1 < history.count else {
            return history
        }
        return Array(history[(boundaryIndex + 1)...])
    }

    private func readEventStream(
        bytes: URLSession.AsyncBytes,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }
            if event.type == "response.output_text.delta", let delta = event.delta ?? event.text, !delta.isEmpty {
                accumulated += delta
                await onPartial(accumulated)
            }
        }
        guard !accumulated.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return accumulated
    }

    private func decodeResponseText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let outputText = decoded.output_text, !outputText.isEmpty {
            return outputText
        }
        let text = decoded.output?
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined() ?? ""
        guard !text.isEmpty else { throw URLError(.cannotParseResponse) }
        return text
    }
}

struct PersonalMemoryClient {
    struct HealthResponse: Decodable {
        struct Counts: Decodable {
            var memories: Int
            var messages: Int
        }
        var ok: Bool
        var counts: Counts
    }

    struct HealthStatus {
        var memories: Int
        var messages: Int
    }

    struct IngestRequest: Encodable {
        var conversation_id: String
        var external_id: String
        var role: String
        var content: String
        var source: String
        var metadata: [String: String]
    }

    func health(settings: KnowledgeServiceSettings) async throws -> HealthStatus {
        let base = settings.personalMemoryURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/health") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard decoded.ok else { throw URLError(.cannotParseResponse) }
        return HealthStatus(memories: decoded.counts.memories, messages: decoded.counts.messages)
    }

    func ingest(message: ChatMessage, context: ChatContext, settings: KnowledgeServiceSettings) async throws {
        let base = settings.personalMemoryURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = IngestRequest(
            conversation_id: "mkb-\(context.id.uuidString)",
            external_id: "mkb-\(message.id.uuidString)",
            role: message.role.rawValue,
            content: message.text,
            source: "MKB-iOS",
            metadata: [
                "context_id": context.id.uuidString,
                "context_name": context.name,
                "message_id": message.id.uuidString
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: KnowledgeAppStore
    var openWorkbench: () -> Void = {}
    @State private var showsHistory = false
    @State private var showsTasks = false
    @State private var showsSettings = false
    @State private var showsContextManager = false
    @State private var showsScrollToBottom = false
    @State private var isJumpingToBottom = false
    @State private var isChatBottomVisible = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platform(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    conversationList
                    Composer()
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.platform(.systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Button {
                            showsHistory = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel("打开历史")

                        Button {
                            openWorkbench()
                        } label: {
                            Label("公司 Codex", systemImage: "terminal")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .accessibilityLabel("切换到公司 Codex")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(store.contexts) { context in
                            Button {
                                store.selectedContextID = context.id
                            } label: {
                                Label(context.name, systemImage: store.selectedContextID == context.id ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(store.selectedContext.name)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切换上下文")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: store.addContext) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("新聊天")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("公司 Codex", systemImage: "terminal") {
                            openWorkbench()
                        }
                        Divider()
                        Menu("切换模型", systemImage: "cpu") {
                            ForEach(KnowledgeServiceSettings.availableModels, id: \.self) { model in
                                Button {
                                    store.settings.model = model
                                } label: {
                                    Label(model, systemImage: store.settings.model == model ? "checkmark" : "circle")
                                }
                            }
                        }
                        Button("生成三点摘要", systemImage: "sparkles") {
                            store.send("请根据当前上下文，给我一个三点摘要。")
                        }
                        Button("清空当前聊天", systemImage: "trash", role: .destructive) {
                            store.clearCurrentChat()
                        }
                        Divider()
                        Button("定时任务", systemImage: "calendar.badge.clock") {
                            showsTasks = true
                        }
                        Button("设置", systemImage: "gearshape") {
                            showsSettings = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("更多")
                }
            }
        }
        .sheet(isPresented: $showsHistory) {
            HistoryDrawerView(showsManager: $showsContextManager)
        }
        .sheet(isPresented: $showsContextManager) {
            ContextManagerView()
        }
        .sheet(isPresented: $showsTasks) {
            TasksView()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .overlay(alignment: .top) {
            if let banner = store.banner {
                Text(banner)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    .padding(.top, 8)
                    .onTapGesture {
                        store.banner = nil
                    }
            }
        }
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(store.visibleMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if store.isSending {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Codex 正在生成回复")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                                isChatBottomVisible = isVisible
                                updateScrollToBottomButtonVisibility()
                            }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard !isJumpingToBottom, !store.visibleMessages.isEmpty else { return }
                            if value.translation.height > 20 || !isChatBottomVisible {
                                showsScrollToBottom = true
                            }
                        }
                )
                .onChange(of: isChatBottomVisible) {
                    updateScrollToBottomButtonVisibility()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    DispatchQueue.main.async {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: store.visibleMessages.count) {
                    scrollToBottom(proxy: proxy)
                }

                if showsScrollToBottom {
                    Button {
                        scrollToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.6)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到聊天底部")
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard !store.visibleMessages.isEmpty else { return }
        isJumpingToBottom = true
        let targetMessageID = store.visibleMessages.last?.id

        scrollToBottom(proxy: proxy, targetMessageID: targetMessageID)

        Task { @MainActor in
            await Task.yield()
            if !isChatBottomVisible {
                scrollToBottom(proxy: proxy, targetMessageID: targetMessageID)
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
            if !isChatBottomVisible {
                scrollToBottom(proxy: proxy, targetMessageID: targetMessageID)
            }
            isJumpingToBottom = false
            updateScrollToBottomButtonVisibility()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, targetMessageID: UUID?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let targetMessageID {
                proxy.scrollTo(targetMessageID, anchor: .bottom)
            }
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    private func updateScrollToBottomButtonVisibility() {
        let shouldShow = !isChatBottomVisible && !store.visibleMessages.isEmpty
        if showsScrollToBottom != shouldShow {
            showsScrollToBottom = shouldShow
        }
    }
}

struct HistoryDrawerView: View {
    @EnvironmentObject private var store: KnowledgeAppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var showsManager: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.addContext()
                        dismiss()
                    } label: {
                        Label("新聊天", systemImage: "square.and.pencil")
                    }
                }

                Section("历史") {
                    ForEach(store.contexts) { context in
                        Button {
                            store.selectedContextID = context.id
                            dismiss()
                        } label: {
                            HistoryRow(context: context, isSelected: store.selectedContextID == context.id)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        showsManager = true
                    } label: {
                        Label("管理历史", systemImage: "checklist")
                    }
                    Button(role: .destructive) {
                        store.clearCurrentChat()
                        dismiss()
                    } label: {
                        Label("清空当前聊天", systemImage: "trash")
                    }
                }
            }
            .platformListStyle()
            .navigationTitle("MKB")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HistoryRow: View {
    var context: ChatContext
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "message.fill" : "message")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(context.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if context.enableThinking {
                Image(systemName: "brain.head.profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContextManagerView: View {
    @EnvironmentObject private var store: KnowledgeAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.contexts) { context in
                        Button {
                            toggle(context.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(context.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(context.id) ? .primary : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(context.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(context.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("\(store.messageCount(for: context.id)) 条消息")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    if store.selectedContextID == context.id {
                                        Text("当前")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                    Toggle("", isOn: Binding(
                                        get: { context.enableThinking },
                                        set: { store.setThinking($0, for: context.id) }
                                    ))
                                    .labelsHidden()
                                    .accessibilityLabel("\(context.name) 思考模式")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择删除上下文：\(context.name)")
                    }
                } header: {
                    Text("历史上下文")
                } footer: {
                    Text("批量删除会同时删除对应聊天记录，并把关联定时任务移到保留的上下文。")
                }
            }
            .platformListStyle()
            .navigationTitle("管理历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("全选") {
                            selectedIDs = store.allContextIDs
                        }
                        Button("只选未命名") {
                            selectedIDs = store.untitledContextIDs
                        }
                        Button("清空选择") {
                            selectedIDs.removeAll()
                        }
                        Button("删除所选", role: .destructive) {
                            store.deleteContexts(with: selectedIDs)
                            selectedIDs.removeAll()
                        }
                        .disabled(store.deletableContextIDs(from: selectedIDs).isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("批量上下文操作")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Text("已选 \(selectedIDs.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全选") {
                        selectedIDs = store.allContextIDs
                    }
                    .buttonStyle(.bordered)
                    Button("删除") {
                        store.deleteContexts(with: selectedIDs)
                        selectedIDs.removeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(store.deletableContextIDs(from: selectedIDs).isEmpty)
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

struct MessageBubble: View {
    var message: ChatMessage

    var body: some View {
        Group {
            switch message.role {
            case .user:
                HStack(alignment: .bottom) {
                    Spacer(minLength: 48)
                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.platform(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.primary)
                }
            case .assistant:
                HStack(alignment: .top, spacing: 12) {
                    AssistantMark()
                    VStack(alignment: .leading, spacing: 8) {
                        if message.text == "正在思考..." {
                            ThinkingStatusView()
                        } else if message.text == "思考完成，正在生成正式回答..." {
                            ThinkingStatusView(label: "生成正式回答")
                        } else {
                            Text(message.text)
                                .font(.body)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
            case .system:
                HStack {
                    Spacer(minLength: 24)
                    Text(message.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.platform(.secondarySystemBackground), in: Capsule())
                    Spacer(minLength: 24)
                }
            }
        }
        .padding(.horizontal, 18)
    }
}

struct AssistantMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary)
            Text("M")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.platform(.systemBackground))
        }
        .frame(width: 26, height: 26)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

struct ThinkingStatusView: View {
    var label = "正在思考"
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.38, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(phase == index ? 0.9 : 0.22))
                        .frame(width: 6, height: 6)
                        .scaleEffect(phase == index ? 1.25 : 0.88)
                }
            }
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel(label)
    }
}

struct Composer: View {
    @EnvironmentObject private var store: KnowledgeAppStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    store.selectedContextThinkingBinding.wrappedValue.toggle()
                } label: {
                    Image(systemName: store.selectedContext.enableThinking ? "brain.head.profile.fill" : "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.platform(.secondarySystemBackground), in: Circle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(store.selectedContext.enableThinking ? "关闭当前上下文思考" : "开启当前上下文思考")

                TextField("Message MKB", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)

                Button(action: store.sendDraft) {
                    Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.primary : Color(.systemGray4), in: Circle())
                        .foregroundStyle(Color.platform(.systemBackground))
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.platform(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)

            Text("MKB 可能会出错。重要信息请核对。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSending
    }
}

struct TasksView: View {
    @EnvironmentObject private var store: KnowledgeAppStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.tasks) { task in
                        TaskRow(task: task)
                    }
                    .onDelete(perform: store.deleteTasks)
                }
            }
            .navigationTitle("定时任务")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: store.addTask) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加任务")
                }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: KnowledgeAppStore
    @State var task: ScheduledKnowledgeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("任务名称", text: $task.title)
                    .font(.headline)
                Toggle("", isOn: $task.isEnabled)
                    .labelsHidden()
            }

            TextField("任务提示词", text: $task.prompt, axis: .vertical)
                .lineLimit(2...4)

            Picker("上下文", selection: $task.contextID) {
                ForEach(store.contexts) { context in
                    Text(context.name).tag(context.id)
                }
            }

            DatePicker("时间", selection: $task.fireDate, displayedComponents: [.date, .hourAndMinute])

            HStack {
                Toggle("通知", isOn: $task.sendsNotification)
                Spacer()
                Button("立即运行") {
                    store.runTaskNow(task)
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 8)
        .onChange(of: task) {
            store.updateTask(task)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: KnowledgeAppStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Codex API") {
                    LabeledContent("服务") {
                        Text(KnowledgeServiceSettings.codexBaseURL)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("模型") {
                        Text(store.settings.model)
                            .foregroundStyle(.teal)
                    }
                    Toggle("自动切换上下文", isOn: $store.settings.autoSwitchContext)
                    Toggle("连接失败时使用离线回显", isOn: $store.settings.useMockFallback)
                    LabeledContent("当前上下文思考") {
                        Text(store.selectedContext.enableThinking ? "开启" : "关闭")
                            .foregroundStyle(store.selectedContext.enableThinking ? .teal : .secondary)
                    }
                    Stepper("上下文预算 \(store.settings.contextBudgetCharacters)", value: $store.settings.contextBudgetCharacters, in: 8000...120000, step: 4000)
                    Stepper("压缩摘要目标 \(store.settings.compressionTargetCharacters)", value: $store.settings.compressionTargetCharacters, in: 1200...12000, step: 600)
                    if !store.selectedContext.contextSummary.isEmpty {
                        LabeledContent("当前摘要") {
                            Text("\(store.selectedContext.contextSummary.count) 字")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("个人记忆") {
                    Toggle("自动记录每条对话", isOn: $store.settings.personalMemoryEnabled)
                    TextField("记忆服务地址", text: $store.settings.personalMemoryURL)
                        .platformTextInputAutocapitalizationNever()
                        .platformKeyboardTypeURL()
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(store.personalMemoryStatus)
                            .foregroundStyle(.secondary)
                    }
                    Button("检查个人记忆服务", systemImage: "brain.head.profile") {
                        store.checkPersonalMemory()
                    }
                }

                Section("通知") {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(store.notificationStatus)
                            .foregroundStyle(.secondary)
                    }
                    Button("请求通知权限", systemImage: "bell.badge") {
                        store.requestNotificationPermission()
                    }
                    Button("刷新状态", systemImage: "arrow.clockwise") {
                        store.refreshNotificationStatus()
                    }
                }

                Section("连接测试") {
                    Button("发送测试消息", systemImage: "network") {
                        store.send("请只回复：知识库连接正常")
                    }
                    Text("固定调用本机 Codex API 的 /responses，当前模型为 \(store.settings.model)。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

#Preview {
    ContentView()
}
