import AppKit
import SwiftUI

/// 첫 실행 온보딩과 이후 설정을 함께 하는 창. 순서대로 채우면 자동 리뷰를 켤 수 있다.
struct SettingsView: View {
    let model: AppModel

    @State private var draft = SettingsDraft(config: nil)
    /// 마지막으로 불러오거나 저장한 값. 편집 여부 판단과 저장소 정렬 기준으로 쓴다.
    @State private var baseline = SettingsDraft(config: nil)
    @State private var repoFilter = ""
    @State private var isSaving = false
    /// 모델 선택에서 "직접 입력"을 고른 상태. 목록에 없는 이름이 저장돼 있어도 직접 입력 칸을 보여 준다.
    @State private var isCustomModel = false

    private static let customModelTag = "__custom__"

    private static let toolChecks = ["node", "gh", "git", "claude", "codex"]

    private var isDirty: Bool { draft != baseline }

    var body: some View {
        Form {
            if let setupError = model.setupError {
                Section {
                    Label(setupError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            environmentSection
            repositorySection
            reviewSection
            automationSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 560)
        .safeAreaInset(edge: .bottom) { saveBar }
        .onAppear { syncDraft(force: true) }
        .onChange(of: model.config) { syncDraft(force: false) }
        .task {
            if model.engineModels.isEmpty { await model.loadModels() }
        }
        .task {
            if model.repos.isEmpty { await model.loadRepos() }
        }
    }

    // MARK: - 1. 환경 점검

    private var environmentSection: some View {
        Section {
            if let doctor = model.doctor {
                ForEach(doctor.checks.filter { Self.toolChecks.contains($0.id) }) { check in
                    CheckRow(check: check)
                }
            } else if model.isCheckingEnvironment {
                ProgressView("점검 중…")
            } else {
                Text("아직 점검하지 않았습니다.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("1. 환경 점검")
                Spacer()
                if model.isCheckingEnvironment { ProgressView().controlSize(.small) }
                // 엔진을 새로 설치했을 수 있어 모델 목록도 다시 읽는다.
                Button("다시 점검") {
                    Task {
                        await model.checkEnvironment()
                        await model.loadModels()
                    }
                }
                    .disabled(model.isCheckingEnvironment || model.cli == nil)
            }
        } footer: {
            Text("Claude Code와 Codex 중 리뷰에 쓸 엔진 하나만 있으면 됩니다. 터미널에서 안내한 명령을 실행한 뒤 다시 점검하세요.")
        }
    }

    // MARK: - 2. 저장소

    private var repositorySection: some View {
        Section {
            TextField("저장소 검색", text: $repoFilter, prompt: Text("owner/name 일부를 입력"))
            if let error = model.reposError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.isLoadingRepos && model.repos.isEmpty {
                ProgressView("저장소 목록을 불러오는 중…")
            } else if visibleRepos.isEmpty {
                Text(repoFilter.isEmpty ? "불러온 저장소가 없습니다." : "검색 결과가 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleRepos, id: \.self) { name in
                            Toggle(isOn: selection(for: name)) {
                                HStack(spacing: 4) {
                                    Text(name)
                                    if privateRepos.contains(name) {
                                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(height: 200)
            }
        } header: {
            HStack {
                Text("2. 감시할 저장소")
                Spacer()
                Text("\(draft.repos.count)개 선택").foregroundStyle(.secondary)
                Button("목록 새로고침") { Task { await model.loadRepos() } }
                    .disabled(model.isLoadingRepos || model.cli == nil)
            }
        } footer: {
            Text("선택한 저장소에서 내가 올린 열린 PR(Draft 포함 여부는 아래에서 선택)을 리뷰합니다.")
        }
    }

    /// 저장된 저장소를 먼저, 나머지는 최근 갱신순으로 보여 준다. 체크할 때마다 순서가 바뀌지 않게 저장된 값을 기준으로 정렬한다.
    private var visibleRepos: [String] {
        let listed = model.repos.map(\.nameWithOwner)
        let saved = baseline.repos.sorted()
        let ordered = saved + listed.filter { !baseline.repos.contains($0) }
        let query = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? ordered : ordered.filter { $0.lowercased().contains(query) }
    }

    private var privateRepos: Set<String> {
        Set(model.repos.filter(\.isPrivate).map(\.nameWithOwner))
    }

    private func selection(for name: String) -> Binding<Bool> {
        Binding(
            get: { draft.repos.contains(name) },
            set: { isOn in
                if isOn { draft.repos.insert(name) } else { draft.repos.remove(name) }
            }
        )
    }

    // MARK: - 3. 리뷰 설정

    private var reviewSection: some View {
        Section("3. 리뷰 설정") {
            Picker("리뷰 엔진", selection: engineSelection) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)
            if let check = model.doctor?.check(draft.engine), !check.ok {
                Label("\(check.label): \(check.detail)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            modelPicker
            if showsCustomModel {
                TextField("모델 이름", text: $draft.model, prompt: Text(draft.engine == "codex" ? "예: gpt-6.1-sol" : "예: claude-opus-5-5"))
            }
            Toggle("Draft PR도 리뷰", isOn: $draft.includeDrafts)
            Toggle(isOn: $draft.post) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PR에 리뷰 코멘트 게시")
                    Text(draft.post ? "리뷰 결과를 PR 코멘트로 올립니다." : "PR에 올리지 않고 이 PC에만 저장합니다 (dry-run).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            reviewInstructionsEditor
        }
    }

    /// 모델 이름은 엔진마다 달라, 엔진을 바꾸면 모델을 기본값으로 돌린다. 저장된 엔진으로 돌아오면 저장된 모델을 다시 쓴다.
    private var engineSelection: Binding<String> {
        Binding(
            get: { draft.engine },
            set: { engine in
                guard engine != draft.engine else { return }
                draft.engine = engine
                draft.model = engine == baseline.engine ? baseline.model : ""
                isCustomModel = false
            }
        )
    }

    private var modelOptions: [EngineModels.Option] {
        model.models(for: draft.engine)?.models ?? []
    }

    private var showsCustomModel: Bool {
        isCustomModel || (!draft.model.isEmpty && !modelOptions.contains { $0.id == draft.model })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { showsCustomModel ? Self.customModelTag : draft.model },
            set: { tag in
                if tag == Self.customModelTag {
                    isCustomModel = true
                } else {
                    isCustomModel = false
                    draft.model = tag
                }
            }
        )
    }

    private var modelPicker: some View {
        Picker(selection: modelSelection) {
            Text(defaultModelLabel).tag("")
            if !modelOptions.isEmpty {
                Divider()
                ForEach(modelOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
            Divider()
            Text("직접 입력…").tag(Self.customModelTag)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("모델")
                Text(modelCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Codex처럼 기본 모델을 알 수 있으면 이름(버전)을 함께 보여 준다.
    private var defaultModelLabel: String {
        guard let id = model.models(for: draft.engine)?.defaultModel else { return "CLI 기본 모델" }
        let label = modelOptions.first { $0.id == id }?.label ?? id
        return "CLI 기본 모델 (\(label))"
    }

    private var modelCaption: String {
        if showsCustomModel {
            return "적은 이름을 \(draft.engine == "codex" ? "codex" : "claude") --model에 그대로 넘깁니다."
        }
        if draft.model.isEmpty {
            let base = draft.engine == "codex" ? "Codex 설정(~/.codex/config.toml)의 모델을 씁니다." : "Claude Code에 설정된 기본 모델을 씁니다."
            if model.isLoadingModels { return "\(base) 모델 목록을 불러오는 중…" }
            if let error = model.models(for: draft.engine)?.error { return "\(base) \(error)" }
            return base
        }
        guard let option = modelOptions.first(where: { $0.id == draft.model }) else { return "" }
        // 화면 이름만으로는 버전을 알기 어려울 수 있어 --model에 넘길 이름을 함께 보여 준다.
        return option.description.isEmpty || option.description == option.id ? option.id : "\(option.id) · \(option.description)"
    }

    /// 기본 리뷰 기준에 더할 사용자 기준. 안전·형식 규칙은 바꾸지 못하고 덧붙이기만 한다.
    private var reviewInstructionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("추가 리뷰 기준")
            TextEditor(text: $draft.reviewInstructions)
                .font(.body)
                .frame(minHeight: 96)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack(alignment: .firstTextBaseline) {
                Text("기본 기준에 더할 내용을 적습니다. 예: 금액 계산은 BigDecimal만 쓴다, 외부 API 호출에는 타임아웃을 둔다. 비우면 기본 기준만 씁니다. 적용하면 PR 리뷰 본문에 \"추가 리뷰 기준 적용\"이 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(draft.reviewInstructionsLength)/\(SettingsDraft.reviewInstructionsLimit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(draft.isReviewInstructionsTooLong ? .red : .secondary)
            }
        }
    }

    // MARK: - 4. 자동 실행

    private var automationSection: some View {
        Section {
            Toggle(isOn: autoReviewBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("로그인 시 자동 리뷰")
                    Text(serviceDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.isApplyingService || model.cli == nil || (!model.isAutoReviewOn && !model.canEnableAutoReview))
            if model.autoReviewUsesOtherCLI, let registered = model.service?.scriptPath {
                VStack(alignment: .leading, spacing: 4) {
                    Label("자동 리뷰가 이 앱 밖의 CLI로 등록돼 있습니다.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(registered).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("앱을 업데이트해도 감시 프로세스는 바뀌지 않습니다. 이 앱으로 다시 등록하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("이 앱으로 다시 등록") { Task { await model.setAutoReview(true) } }
                        .disabled(model.isApplyingService)
                }
            }
            Toggle("로그인 시 메뉴바 아이콘 표시", isOn: opensAtLoginBinding)
            HStack {
                Button("로그 보기") { model.openLog() }
                    .disabled(model.service == nil)
                if model.isAutoReviewOn && !model.autoReviewUsesOtherCLI {
                    Button("다시 등록") { Task { await model.setAutoReview(true) } }
                        .help("node, gh, claude, codex를 새로 설치하거나 옮긴 뒤 누르세요.")
                        .disabled(model.isApplyingService)
                }
                if model.isApplyingService { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("4. 자동 실행")
        } footer: {
            Text("자동 리뷰는 메뉴바 앱과 따로 동작합니다. 앱을 종료해도 리뷰는 계속됩니다.")
        }
    }

    private var serviceDetail: String {
        if let service = model.service, service.loaded {
            let pid = model.status?.pid ?? service.pid.map(Int32.init)
            return model.daemonRunning ? "실행 중\(pid.map { " (PID \($0))" } ?? "")" : "등록됨 · 상태 \(service.state ?? "알 수 없음")"
        }
        if !model.canEnableAutoReview {
            return model.configSnapshot?.exists == true && !(model.config?.repos.isEmpty ?? true)
                ? "필수 도구와 리뷰 엔진을 먼저 준비하세요."
                : "저장소를 선택하고 저장한 뒤 켤 수 있습니다."
        }
        return "꺼져 있음"
    }

    private var autoReviewBinding: Binding<Bool> {
        Binding(
            get: { model.isAutoReviewOn },
            set: { isOn in Task { await model.setAutoReview(isOn) } }
        )
    }

    private var opensAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.opensAtLogin },
            set: { isOn in model.setOpensAtLogin(isOn) }
        )
    }

    // MARK: - 정보

    private var aboutSection: some View {
        Section {
            LabeledContent("앱 버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드")
            if let status = model.status {
                LabeledContent("감시 프로세스 버전", value: status.appVersion)
            }
            if let path = model.configSnapshot?.path {
                LabeledContent("설정 파일") {
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 저장

    private var saveBar: some View {
        HStack(spacing: 10) {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if draft.repos.isEmpty {
                Text("감시할 저장소를 하나 이상 선택하세요.").font(.callout).foregroundStyle(.secondary)
            } else if draft.isReviewInstructionsTooLong {
                Text("추가 리뷰 기준은 \(SettingsDraft.reviewInstructionsLimit)자 이하로 줄여 주세요.").font(.callout).foregroundStyle(.red)
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button("되돌리기") {
                draft = baseline
                isCustomModel = false
            }
                .disabled(!isDirty || isSaving)
            Button("저장") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || draft.repos.isEmpty || draft.isReviewInstructionsTooLong || isSaving || model.cli == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() {
        isSaving = true
        Task {
            if await model.save(draft) { syncDraft(force: true) }
            isSaving = false
        }
    }

    /// 편집 중이 아닐 때만 저장된 설정으로 화면 값을 맞춘다.
    private func syncDraft(force: Bool) {
        guard force || !isDirty else { return }
        let loaded = SettingsDraft(config: model.config)
        draft = loaded
        baseline = loaded
        isCustomModel = false
    }
}

/// 환경 점검 한 줄. 실패하면 해결 명령과 복사 버튼을 보여 준다.
private struct CheckRow: View {
    let check: DoctorResult.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label)
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                if !check.ok, let hint = check.hint {
                    HStack(spacing: 6) {
                        Text(hint).font(.caption.monospaced()).textSelection(.enabled)
                        Button("복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hint, forType: .string)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var symbol: String {
        check.ok ? "checkmark.circle.fill" : check.required ? "xmark.circle.fill" : "minus.circle"
    }

    private var color: Color {
        check.ok ? .green : check.required ? .red : .secondary
    }
}
