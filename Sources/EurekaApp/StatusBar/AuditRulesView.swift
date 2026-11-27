import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// A rule being written or edited in the rules panel. Text fields hold what the user typed; `rule`
/// turns it into a `RiskRule` once it is complete and its patterns compile.
struct AuditRuleDraft: Equatable {
    /// Id of the rule being edited; nil for a new one
    var originalId: String?
    var id = ""
    var title = ""
    var level: RiskLevel = .high
    var kinds: Set<ToolKind> = [.command]
    var scope: RiskRule.Scope = .segment
    var access: RiskRule.Access = .any
    /// Comma-separated command words
    var commands = ""
    var pattern = ""
    /// One regex per line
    var exclude = ""
    var sample = ""

    init() {}

    init(editing rule: RiskRule) {
        originalId = rule.id
        id = rule.id
        title = rule.title.english
        level = rule.level
        kinds = rule.kinds
        scope = rule.scope
        access = rule.access
        commands = rule.commands.joined(separator: ", ")
        pattern = rule.pattern ?? ""
        exclude = rule.exclude.joined(separator: "\n")
    }

    private var commandList: [String] {
        commands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var excludeList: [String] {
        exclude.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Why the draft cannot be saved yet; nil when it can
    func problem(existingIds: Set<String>) -> String? {
        let id = id.trimmingCharacters(in: .whitespaces)
        if id.isEmpty { return L10n.text("Give the rule an id", zhHans: "给规则起一个 id") }
        if id != originalId, existingIds.contains(id) {
            return L10n.text("Another rule already uses this id", zhHans: "已有规则使用这个 id")
        }
        if kinds.isEmpty { return L10n.text("Pick at least one kind of operation", zhHans: "至少选一种操作类型") }
        if pattern.trimmingCharacters(in: .whitespaces).isEmpty, commandList.isEmpty {
            return L10n.text("Add a pattern or command names; otherwise every operation would match", zhHans: "填写正则或命令词，否则会命中所有操作")
        }
        for text in [pattern.trimmingCharacters(in: .whitespaces)] + excludeList where !text.isEmpty {
            do {
                _ = try NSRegularExpression(pattern: text)
            } catch {
                return L10n.format("Not a valid pattern: %@", zhHans: "正则不合法：%@", text)
            }
        }
        return nil
    }

    func rule() -> RiskRule {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        let id = id.trimmingCharacters(in: .whitespaces)
        let title = title.trimmingCharacters(in: .whitespaces)
        return RiskRule(
            id: id, title: RiskRuleTitle(title.isEmpty ? id : title), level: level,
            category: .custom, kinds: kinds, scope: scope, commands: commandList,
            pattern: pattern.isEmpty ? nil : pattern, access: access, exclude: excludeList)
    }

    /// What the draft rule says about the sample text: the kind tried is the first the rule
    /// looks at (a tool rule matches the sample as a tool name)
    func sampleMatches(home: String = NSHomeDirectory()) -> Bool? {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let rules = RiskRuleSet(rules: [rule()])
        guard rules.problems.isEmpty else { return nil }
        return ToolKind.allCases.filter(kinds.contains).contains { kind in
            rules.evaluate(
                kind: kind, tool: scope == .tool ? text : "", detail: scope == .tool ? "" : text,
                home: home) != nil
        }
    }
}

/// The rules panel: every rule in force with its switch, level and stored hits; the user's own
/// rules; the allow list. Each change is written to `audit-rules.json` at once and stored history
/// is evaluated again in the background.
struct AuditRulesView: View {
    enum Pane: Hashable {
        case rules, allow
    }

    @ObservedObject var service: AuditService
    let onClose: () -> Void

    @State private var pane: Pane
    @State private var expanded: Set<String> = []
    @State private var draft: AuditRuleDraft?
    @State private var allowRule = ""
    @State private var allowDirectory = ""
    @State private var allowPattern = ""

    init(
        service: AuditService, initialPane: Pane = .rules, initialDraft: AuditRuleDraft? = nil,
        onClose: @escaping () -> Void
    ) {
        self._service = ObservedObject(wrappedValue: service)
        self.onClose = onClose
        self._pane = State(initialValue: initialPane)
        self._draft = State(initialValue: initialDraft)
    }

    private var config: RiskRulesConfig { service.rulesState.config }
    private var builtin: [RiskRule] { RiskRuleEngine.builtinRules }
    /// Rules as they are in force: the user's own, then built-in ones with overrides applied
    private var effective: [RiskRule] {
        RiskRuleSet.make(builtin: builtin, config: config).rules
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("Risk rules", zhHans: "风险规则")).font(Theme.font.themed(15, .bold))
                if draft == nil {
                    ThemedSegmentedPicker(
                        selection: $pane, options: [.rules, .allow],
                        label: { $0 == .rules ? L10n.text("Rules", zhHans: "规则") : L10n.text("Allow list", zhHans: "白名单") },
                        classicWidth: 170)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            if let binding = Binding($draft) {
                editor(binding)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        problems
                        switch pane {
                        case .rules: rulesPane
                        case .allow: allowPane
                        }
                    }
                    .padding(18)
                }
                .background(Theme.surfaceSecondary)
                Divider()
                footer
            }
        }
        .frame(width: 680, height: 640)
        .toggleStyle(.themedSwitch)
        .controlSize(.small)
        .onAppear { service.loadRuleHitCounts() }
    }

    // MARK: - Problems

    @ViewBuilder
    private var problems: some View {
        let state = service.rulesState
        if state.fileError != nil || !state.problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if state.fileError != nil {
                    Text(L10n.text("audit-rules.json could not be read as a rules file. The rules from before stay in force until it is fixed.", zhHans: "audit-rules.json 无法作为规则文件读取。修好之前继续使用之前的规则。"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(state.problems.enumerated()), id: \.offset) { _, problem in
                    Text("\(problem.ruleId): \(problem.message)")
                        .font(Theme.font.themedMono(10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !state.problems.isEmpty {
                    Text(L10n.text("These entries are skipped; every other rule works.", zhHans: "以上条目已跳过，其余规则照常生效。"))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(Theme.font.themed(10.5))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Theme.failureRed.opacity(0.10)))
        }
    }

    // MARK: - Rules

    private var rulesPane: some View {
        let rules = effective
        let categories = RiskRule.Category.allCases.sorted { ($0 == .custom ? 0 : 1) < ($1 == .custom ? 0 : 1) }
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Switch a rule off, change its level, or add your own. Changes apply to new operations at once and to stored history within a minute.", zhHans: "可以关闭规则、调整等级或添加自己的规则。改动对新操作立即生效，已入库的历史会在一分钟内重新判定。"))
                .font(Theme.font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(categories, id: \.self) { category in
                let members = rules.filter { $0.category == category }
                if !members.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.label).font(Theme.font.themed(12, .semibold))
                        KnowledgeListContainer {
                            VStack(spacing: 0) {
                                ForEach(Array(members.enumerated()), id: \.element.id) { index, rule in
                                    if index > 0 { Divider().opacity(0.4) }
                                    ruleRow(rule)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isCustom(_ rule: RiskRule) -> Bool { rule.category == .custom }

    private func ruleRow(_ rule: RiskRule) -> some View {
        let isOpen = expanded.contains(rule.id)
        let hits = service.ruleHitCounts[rule.id] ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { setEnabled($0, rule) }))
                    .labelsHidden()
                    .fixedSize()
                Picker("", selection: Binding(
                    get: { rule.level },
                    set: { setLevel($0, rule) })) {
                    ForEach(RiskLevel.allCases.reversed(), id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 104, alignment: .leading)
                HStack(spacing: 6) {
                    Text(rule.title.text)
                        .font(Theme.font.themed(11.5, .medium))
                        .foregroundStyle(rule.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                    if config.overrides[rule.id] != nil {
                        TagChip(L10n.text("Changed", zhHans: "已改"), tint: Theme.brandFg)
                    }
                    // Listed in the file but left out of the rules in force (see the note on top)
                    if service.rulesState.problems.contains(where: { $0.ruleId == rule.id }) {
                        TagChip(L10n.text("Skipped", zhHans: "已跳过"), tint: Theme.failureRed)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(hits == 0 ? "—" : hits == 1
                     ? L10n.text("1 hit", zhHans: "1 次命中")
                     : L10n.format("%@ hits", zhHans: "%@ 次命中", AuditAnalyticsView.number(hits)))
                    .font(Theme.font.themedMono(10))
                    .foregroundStyle(.tertiary)
                Button {
                    if isOpen { expanded.remove(rule.id) } else { expanded.insert(rule.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(Theme.font.themed(9, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isOpen { ruleDetail(rule) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func ruleDetail(_ rule: RiskRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailLine("id", rule.id)
            detailLine(L10n.text("looks at", zhHans: "看什么"),
                       Self.scopeLabel(rule.scope) + " · "
                        + ToolKind.allCases.filter(rule.kinds.contains).map(\.label).joined(separator: " / "))
            if !rule.commands.isEmpty {
                detailLine(L10n.text("commands", zhHans: "命令词"), rule.commands.joined(separator: ", "))
            }
            if let pattern = rule.pattern { detailLine(L10n.text("pattern", zhHans: "正则"), pattern) }
            if !rule.pipeInto.isEmpty {
                detailLine(L10n.text("piped into", zhHans: "管道进"), (rule.pipeInto + rule.pipeIntoBare).joined(separator: ", "))
            }
            if !rule.exclude.isEmpty {
                detailLine(L10n.text("unless", zhHans: "排除"), rule.exclude.joined(separator: "   "))
            }
            HStack(spacing: 8) {
                if isCustom(rule) {
                    SecondaryButton(title: L10n.text("Edit", zhHans: "编辑"), icon: "pencil") {
                        draft = AuditRuleDraft(editing: rule)
                    }
                    SecondaryButton(title: L10n.text("Delete", zhHans: "删除"), icon: "trash", destructive: true) {
                        var next = config
                        next.rules.removeAll { $0.id == rule.id }
                        service.saveRules(next)
                    }
                } else if config.overrides[rule.id] != nil {
                    SecondaryButton(title: L10n.text("Back to default", zhHans: "恢复默认"), icon: "arrow.uturn.backward") {
                        var next = config
                        next.overrides[rule.id] = nil
                        service.saveRules(next)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 42)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func scopeLabel(_ scope: RiskRule.Scope) -> String {
        switch scope {
        case .text: return L10n.text("Whole text", zhHans: "整段文本")
        case .segment: return L10n.text("Each command", zhHans: "每条命令")
        case .pipeline: return L10n.text("Pipelines", zhHans: "管道")
        case .path: return L10n.text("Paths read or written", zhHans: "读写的路径")
        case .tool: return L10n.text("Tool name", zhHans: "工具名")
        }
    }

    private func setEnabled(_ enabled: Bool, _ rule: RiskRule) {
        var next = config
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index].enabled = enabled
        } else {
            guard let original = builtin.first(where: { $0.id == rule.id }) else { return }
            var change = next.overrides[rule.id] ?? .init()
            change.enabled = enabled == original.enabled ? nil : enabled
            next.overrides[rule.id] = change.enabled == nil && change.level == nil ? nil : change
        }
        service.saveRules(next)
    }

    private func setLevel(_ level: RiskLevel, _ rule: RiskRule) {
        var next = config
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index].level = level
        } else {
            guard let original = builtin.first(where: { $0.id == rule.id }) else { return }
            var change = next.overrides[rule.id] ?? .init()
            change.level = level == original.level ? nil : level
            next.overrides[rule.id] = change.enabled == nil && change.level == nil ? nil : change
        }
        service.saveRules(next)
    }

    // MARK: - Allow list

    private var allowPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("An entry silences a rule where every condition it states holds. A lower rule can still match the same operation.", zhHans: "一条白名单在它写明的条件都成立时让某条规则不再命中；同一个操作仍可能命中更低等级的规则。"))
                .font(Theme.font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if config.allow.isEmpty {
                Text(L10n.text("Nothing is allowed yet.", zhHans: "还没有白名单。"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
            } else {
                KnowledgeListContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(config.allow.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().opacity(0.4) }
                            allowRow(entry, index: index)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Add an entry", zhHans: "新增一条")).font(Theme.font.themed(12, .semibold))
                field(L10n.text("Rule id, or * for every rule", zhHans: "规则 id，或 * 表示所有规则"), $allowRule)
                field(L10n.text("Working directory (optional): the session's directory or one above it", zhHans: "工作目录（可选）：会话所在目录或它的上级"), $allowDirectory)
                field(L10n.text("Pattern over the command the rule matched (optional)", zhHans: "匹配规则命中的那条命令的正则（可选）"), $allowPattern)
                HStack {
                    PrimaryButton(title: L10n.text("Add", zhHans: "添加"), icon: "plus") { addAllow() }
                        .disabled(allowProblem != nil)
                    if let allowProblem, !allowRule.isEmpty {
                        Text(allowProblem).font(Theme.font.caption).foregroundStyle(Theme.failureRed)
                    }
                }
            }
        }
    }

    private var allowProblem: String? {
        let rule = allowRule.trimmingCharacters(in: .whitespaces)
        let directory = allowDirectory.trimmingCharacters(in: .whitespaces)
        let pattern = allowPattern.trimmingCharacters(in: .whitespaces)
        if rule.isEmpty { return L10n.text("Name a rule", zhHans: "填写规则 id") }
        if rule != "*", !effective.contains(where: { $0.id == rule }) {
            return L10n.text("No rule has this id", zhHans: "没有这个 id 的规则")
        }
        if directory.isEmpty, pattern.isEmpty {
            return L10n.text("Add a directory or a pattern (switch the rule off to silence it everywhere)", zhHans: "至少填目录或正则（想全部忽略请直接关闭规则）")
        }
        if !pattern.isEmpty, (try? NSRegularExpression(pattern: pattern)) == nil {
            return L10n.text("Not a valid pattern", zhHans: "正则不合法")
        }
        return nil
    }

    private func addAllow() {
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        var next = config
        next.allow.append(.init(
            rule: allowRule.trimmingCharacters(in: .whitespaces),
            cwd: value(allowDirectory), pattern: value(allowPattern)))
        service.saveRules(next)
        allowRule = ""
        allowDirectory = ""
        allowPattern = ""
    }

    private func allowRow(_ entry: RiskRulesConfig.Allow, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.rule == "*"
                     ? L10n.text("Every rule", zhHans: "所有规则")
                     : (RiskRuleEngine.title(forRule: entry.rule) ?? entry.rule))
                    .font(Theme.font.themed(11.5, .medium))
                if let cwd = entry.cwd { detailLine(L10n.text("in", zhHans: "目录"), cwd) }
                if let source = entry.source { detailLine(L10n.text("source", zhHans: "来源"), source) }
                if let pattern = entry.pattern { detailLine(L10n.text("pattern", zhHans: "正则"), pattern) }
            }
            Spacer(minLength: 8)
            CardActionButton(icon: "trash", color: Theme.failureRed, help: L10n.text("Remove", zhHans: "移除")) {
                var next = config
                next.allow.remove(at: index)
                service.saveRules(next)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Editor

    private func field(_ placeholder: String, _ text: Binding<String>, mono: Bool = true) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(mono ? Theme.font.themedMono(11) : Theme.font.themed(11.5))
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            content()
        }
    }

    private static let draftKinds: [ToolKind] = [.command, .read, .edit, .search, .web, .mcp]

    private func editor(_ draft: Binding<AuditRuleDraft>) -> some View {
        let value = draft.wrappedValue
        let ids = Set(effective.map(\.id))
        let problem = value.problem(existingIds: ids)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(value.originalId == nil
                         ? L10n.text("New rule", zhHans: "新增规则") : L10n.text("Edit rule", zhHans: "编辑规则"))
                        .font(Theme.font.themed(13, .semibold))
                    formRow("id") { field("prod-db", draft.id) }
                    formRow(L10n.text("Title", zhHans: "标题")) {
                        field(L10n.text("What the alert says", zhHans: "告警里显示的名字"), draft.title, mono: false)
                    }
                    formRow(L10n.text("Level", zhHans: "等级")) {
                        ThemedSegmentedPicker(
                            selection: draft.level, options: [.notice, .high, .critical],
                            label: \.label, classicWidth: 230)
                        Spacer()
                    }
                    formRow(L10n.text("Operations", zhHans: "操作类型")) {
                        HStack(spacing: 6) {
                            ForEach(Self.draftKinds, id: \.self) { kind in
                                let isOn = value.kinds.contains(kind)
                                Button {
                                    if isOn { draft.wrappedValue.kinds.remove(kind) }
                                    else { draft.wrappedValue.kinds.insert(kind) }
                                } label: {
                                    Text(kind.label)
                                        .font(Theme.font.themed(10.5, isOn ? .semibold : .regular))
                                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.surface)))
                                        .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.cardBorder, lineWidth: 0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }
                    formRow(L10n.text("Looks at", zhHans: "匹配范围")) {
                        Picker("", selection: draft.scope) {
                            ForEach([RiskRule.Scope.segment, .text, .path, .tool], id: \.self) {
                                Text(Self.scopeLabel($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        if value.scope == .path {
                            Picker("", selection: draft.access) {
                                Text(L10n.text("Read or written", zhHans: "读或写")).tag(RiskRule.Access.any)
                                Text(L10n.text("Read", zhHans: "读取")).tag(RiskRule.Access.read)
                                Text(L10n.text("Written", zhHans: "写入")).tag(RiskRule.Access.write)
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Spacer()
                    }
                    if value.scope == .segment || value.scope == .path {
                        formRow(L10n.text("Commands", zhHans: "命令词")) {
                            field(L10n.text("psql, mysql (optional; a trailing * matches a prefix)", zhHans: "psql, mysql（可选；结尾加 * 表示前缀）"), draft.commands)
                        }
                    }
                    formRow(L10n.text("Pattern", zhHans: "正则")) {
                        field(L10n.text("Case-insensitive regular expression", zhHans: "不区分大小写的正则表达式"), draft.pattern)
                    }
                    formRow(L10n.text("Unless", zhHans: "排除")) {
                        field(L10n.text("A pattern that cancels the hit (optional)", zhHans: "命中这个正则则不算（可选）"), draft.exclude)
                    }
                    Divider().padding(.vertical, 4)
                    formRow(L10n.text("Try it", zhHans: "试一试")) {
                        VStack(alignment: .leading, spacing: 6) {
                            field(value.scope == .tool
                                  ? L10n.text("A tool name, e.g. Slack.slack_send_message", zhHans: "一个工具名，例如 Slack.slack_send_message")
                                  : L10n.text("A command or a path", zhHans: "一条命令或一个路径"), draft.sample)
                            HStack(spacing: 10) {
                                if problem == nil, let matches = value.sampleMatches() {
                                    Label(
                                        matches ? L10n.text("Matches", zhHans: "命中") : L10n.text("Does not match", zhHans: "不命中"),
                                        systemImage: matches ? "checkmark.circle.fill" : "xmark.circle")
                                        .font(Theme.font.themed(11, .medium))
                                        .foregroundStyle(matches ? Theme.failureRed : Color.secondary)
                                }
                                SecondaryButton(title: L10n.text("Count past operations", zhHans: "统计历史命中"), icon: "clock.arrow.circlepath") {
                                    service.previewHits(of: value.rule())
                                }
                                .disabled(problem != nil)
                                if let preview = service.rulePreview, preview.ruleId == value.id.trimmingCharacters(in: .whitespaces) {
                                    Text(L10n.format("%@ stored operations would match", zhHans: "历史记录里会命中 %@ 条", AuditAnalyticsView.number(preview.hits)))
                                        .font(Theme.font.themed(11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Theme.surfaceSecondary)
            Divider()
            HStack(spacing: 10) {
                if let problem {
                    Text(problem).font(Theme.font.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                SecondaryButton(title: L10n.text("Cancel", zhHans: "取消")) { self.draft = nil }
                PrimaryButton(title: L10n.text("Save", zhHans: "保存")) {
                    var next = config
                    let rule = value.rule()
                    if let original = value.originalId,
                       let index = next.rules.firstIndex(where: { $0.id == original }) {
                        next.rules[index] = rule
                    } else {
                        next.rules.append(rule)
                    }
                    service.saveRules(next)
                    self.draft = nil
                }
                .disabled(problem != nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if pane == .rules {
                PrimaryButton(title: L10n.text("New rule", zhHans: "新增规则"), icon: "plus") {
                    draft = AuditRuleDraft()
                }
            }
            SecondaryButton(
                title: L10n.text("Show audit-rules.json", zhHans: "显示 audit-rules.json"), icon: "folder",
                help: L10n.text("The file can be edited by hand; changes are picked up within 10 seconds", zhHans: "这个文件可以手工编辑，10 秒内生效")
            ) { revealFile() }
            Spacer()
            SecondaryButton(title: L10n.text("Done", zhHans: "完成")) { onClose() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// Shows the rules file in Finder, writing the current config first when there is none yet
    private func revealFile() {
        let url = service.rulesFileURL
        if !FileManager.default.fileExists(atPath: url.path) { service.saveRules(config) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }
    }
}
