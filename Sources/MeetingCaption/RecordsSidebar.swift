import AppKit
import CaptionCore
import SwiftUI

// Presentation state lives in observable objects because this toolchain ships no SwiftUI
// macro plugin (see `MeetingViewState`).

@MainActor
final class SubjectDraft: ObservableObject {
    @Published var text = ""
}

/// Subject (과목) of the open record. New records inherit it, so it can be set before
/// recording starts and changed while recording.
struct CurrentSubjectField: View {
    @ObservedObject var model: MeetingModel
    @StateObject private var draft = SubjectDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("과목 (예: 자료구조)", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.setCurrentSubject(draft.text) }
                Menu {
                    ForEach(model.knownSubjects, id: \.self) { subject in
                        Button(subject) {
                            draft.text = subject
                            model.setCurrentSubject(subject)
                        }
                    }
                    if !model.knownSubjects.isEmpty { Divider() }
                    Button("미분류") {
                        draft.text = ""
                        model.setCurrentSubject(nil)
                    }
                } label: {
                    Image(systemName: "books.vertical")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("이미 쓰는 과목에서 고릅니다.")
            }
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != (model.transcript.subject ?? "") {
                Button("과목 적용") { model.setCurrentSubject(draft.text) }
                    .controlSize(.small)
            }
            Text("현재 기록과 이어서 시작하는 새 기록에 적용됩니다. 기록 중에도 바꿀 수 있습니다.")
                .sidebarNote()
        }
        .onAppear { draft.text = model.transcript.subject ?? "" }
        .onChange(of: model.transcript.subject) { draft.text = model.transcript.subject ?? "" }
    }
}

@MainActor
final class RecordsSidebarState: ObservableObject {
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "meetingCollapsedSubjects") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed).sorted(), forKey: "meetingCollapsedSubjects") }
    }
    @Published var renameTarget: MeetingSession?
    @Published var subjectTarget: MeetingSession?
    @Published var trashTarget: MeetingSession?
    @Published var draft = ""
}

/// Saved records grouped by subject, or archive-wide search results while a query is typed.
struct RecordsSidebarList: View {
    @ObservedObject var model: MeetingModel
    @StateObject private var state = RecordsSidebarState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("기록 검색 (원문·번역·제목)", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isLocked)
                .help(model.isLocked ? "기록 중에는 검색하거나 다른 기록을 열 수 없습니다." : "저장된 모든 기록에서 찾습니다. 대소문자·악센트는 구분하지 않습니다.")
            if model.isLocked {
                Text("기록 중에는 검색과 불러오기를 쓸 수 없습니다.").sidebarNote()
            } else if RecordSearch.normalizedQuery(model.searchQuery) != nil {
                searchResults
            }
            if model.isLocked || RecordSearch.normalizedQuery(model.searchQuery) == nil {
                groupedRecords
            }
            if model.totalAudioBytes > 0 {
                Text("녹음 파일 합계 \(Self.size(model.totalAudioBytes))").sidebarNote()
            }
        }
        .alert("기록 이름 바꾸기", isPresented: presented(\.renameTarget)) {
            TextField("이름", text: $state.draft)
            Button("바꾸기") {
                if let target = state.renameTarget { model.rename(target.url, to: state.draft) }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("과목 지정", isPresented: presented(\.subjectTarget)) {
            TextField("과목", text: $state.draft)
            Button("지정") {
                if let target = state.subjectTarget { model.setSubject(target.url, to: state.draft) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("비워 두면 미분류로 옮깁니다.")
        }
        .alert("기록을 휴지통으로 옮길까요?", isPresented: presented(\.trashTarget)) {
            Button("휴지통으로 이동", role: .destructive) {
                if let target = state.trashTarget { model.trashRecord(target.url) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("‘\(state.trashTarget?.title ?? "")’ 기록 파일\(state.trashTarget?.audioFiles.isEmpty == false ? "과 녹음 파일" : "")을 휴지통으로 옮깁니다. Finder의 휴지통에서 되살릴 수 있습니다.")
        }
    }

    private func presented(_ target: ReferenceWritableKeyPath<RecordsSidebarState, MeetingSession?>) -> Binding<Bool> {
        Binding(get: { state[keyPath: target] != nil },
                set: { if !$0 { state[keyPath: target] = nil } })
    }

    // MARK: Groups

    @ViewBuilder
    private var groupedRecords: some View {
        if model.sessions.isEmpty {
            Text("저장된 회의 기록이 없습니다.").sidebarNote()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RecordGrouping.grouped(model.sessions, subject: \.subject), id: \.id) { group in
                    DisclosureGroup(isExpanded: expanded(group.id)) {
                        VStack(spacing: 3) {
                            ForEach(group.items) { session in row(session) }
                        }
                        .padding(.top, 3)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: group.subject == nil ? "tray" : "book.closed")
                                .foregroundStyle(.secondary)
                            Text(group.subject ?? "미분류")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("\(group.items.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !state.collapsed.contains(id) },
                set: { if $0 { state.collapsed.remove(id) } else { state.collapsed.insert(id) } })
    }

    private func row(_ session: MeetingSession) -> some View {
        let isCurrent = model.isCurrentRecord(session.url)
        return HStack {
            Button {
                model.restore(session)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Text(rowDetail(session))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .background(Color.primary.opacity(isCurrent ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isLocked)
            .help(model.isLocked ? "기록 중에는 이전 회의를 불러올 수 없습니다." : "이 기록을 불러옵니다.")
            Button {
                model.reveal(session.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 보기")
        }
        .contextMenu {
            Button("이름 바꾸기…") {
                state.draft = session.title
                state.renameTarget = session
            }
            Menu("과목 지정") {
                ForEach(model.knownSubjects, id: \.self) { subject in
                    Button(subject) { model.setSubject(session.url, to: subject) }
                }
                if !model.knownSubjects.isEmpty { Divider() }
                Button("새 과목…") {
                    state.draft = session.subject ?? ""
                    state.subjectTarget = session
                }
                Button("미분류로") { model.setSubject(session.url, to: nil) }
            }
            Button("Finder에서 보기") { model.reveal(session.url) }
            Divider()
            Button("휴지통으로 이동…", role: .destructive) { state.trashTarget = session }
                .disabled(isCurrent && model.isLocked)
        }
    }

    private func rowDetail(_ session: MeetingSession) -> String {
        var detail = "\(session.date.formatted(date: .abbreviated, time: .shortened)) · 문장 \(session.count)개"
        if session.bookmarkCount > 0 { detail += " · ★\(session.bookmarkCount)" }
        if session.audioBytes > 0 { detail += " · 녹음 " + Self.size(session.audioBytes) }
        return detail
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        if model.searchResults.isEmpty {
            HStack(spacing: 6) {
                if model.isSearching { ProgressView().controlSize(.small) }
                Text(model.isSearching ? "검색 중…" : "일치하는 기록이 없습니다.").sidebarNote()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.searchResults) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            model.openSearchHit(result, hit: result.hits.first { $0.captionID != nil })
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(result.subject ?? "미분류") · \(result.date.formatted(date: .abbreviated, time: .shortened)) · \(result.matchCount)곳")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        ForEach(result.hits) { hit in
                            Button {
                                model.openSearchHit(result, hit: hit)
                            } label: {
                                snippet(hit)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("이 기록을 열고 해당 문장으로 이동합니다.")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func snippet(_ hit: RecordSearchHit) -> some View {
        let label: String
        switch hit.field {
        case .title: label = "제목 · "
        case .original: label = "원문 · "
        case .translation: label = "번역 · "
        }
        var text = AttributedString(label)
        text.foregroundColor = .secondary
        text += AttributedString(hit.before)
        var match = AttributedString(hit.match)
        match.font = .caption.bold()
        match.backgroundColor = Color.yellow.opacity(0.35)
        text += match
        text += AttributedString(hit.after)
        return Text(text)
            .font(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Glossary

@MainActor
final class GlossaryEditorState: ObservableObject {
    struct Row: Identifiable {
        var id: UUID
        var term: String
        var korean: String
        var variants: String
    }
    @Published var rows: [Row] = []
    @Published var isPresented = false

    func load(_ glossary: Glossary) {
        rows = glossary.entries.map { Row(id: $0.id, term: $0.term, korean: $0.korean, variants: $0.variantsText) }
    }

    /// Variants are edited as raw text and split only on commit, so a typed separator survives.
    var glossary: Glossary {
        Glossary(entries: rows.compactMap { row in
            let term = row.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            var entry = GlossaryEntry(id: row.id, term: term, korean: row.korean.trimmingCharacters(in: .whitespacesAndNewlines))
            entry.variantsText = row.variants
            return entry
        })
    }
}

struct GlossarySidebarSection: View {
    @ObservedObject var model: MeetingModel
    @StateObject private var editor = GlossaryEditorState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.glossary.entries.isEmpty ? "등록된 용어가 없습니다." : "용어 \(model.glossary.entries.count)개")
                .font(.callout)
            Button("용어집 편집…") {
                editor.load(model.glossary)
                editor.isPresented = true
            }
            .disabled(model.glossaryLoadFailed)
            Text("오인식 변형은 확정된 원문에서 용어로 고쳐 저장하고, 고정 한국어가 있으면 번역에 그 표현을 씁니다(확실히 적용할 수 없는 문장은 일반 번역). Apple 음성인식(SpeechTranscriber)은 사용자 단어 힌트를 받지 않아 인식 자체에는 반영되지 않습니다.")
                .sidebarNote()
        }
        .sheet(isPresented: $editor.isPresented) {
            GlossaryEditor(model: model, editor: editor)
        }
    }
}

struct GlossaryEditor: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var editor: GlossaryEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("전공 용어집").font(.title3.weight(.semibold))
            Text("영어 용어 · 고정 한국어(선택) · 오인식 변형(쉼표로 구분, 선택). 변형은 단어 단위로 대소문자 구분 없이 용어로 고칩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("영어 용어").frame(maxWidth: .infinity, alignment: .leading)
                Text("고정 한국어").frame(maxWidth: .infinity, alignment: .leading)
                Text("오인식 변형").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($editor.rows) { $row in
                        HStack {
                            TextField("eigenvalue", text: $row.term)
                            TextField("고유값", text: $row.korean)
                            TextField("eigen value, I can value", text: $row.variants)
                            Button {
                                editor.rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 24)
                            .help("이 용어 삭제")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    if editor.rows.isEmpty {
                        Text("‘용어 추가’로 강의에 자주 나오는 전공 용어를 등록하세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
            HStack {
                Button {
                    editor.rows.append(.init(id: UUID(), term: "", korean: "", variants: ""))
                } label: {
                    Label("용어 추가", systemImage: "plus")
                }
                Button("CSV 가져오기…") {
                    if let merged = model.importGlossary(into: editor.glossary) { editor.load(merged) }
                }
                Button("CSV 내보내기…") { model.exportGlossary(editor.glossary) }
                Spacer()
                Button("취소", role: .cancel) { editor.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    model.glossary = editor.glossary
                    editor.isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("CSV 형식: term,korean,variants (변형은 | 로 구분). 같은 용어는 가져온 내용으로 바뀝니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 440)
    }
}
