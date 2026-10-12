import SwiftUI

struct PresetsPage: View {
    @State private var presets = SettingsPresets.shared
    @State private var newName = ""

    var body: some View {
        let current = presets.currentID()
        GlassCard(title: "現在の設定を保存",
                  footer: "Dock の位置・大きさ・外観、並んでいるアプリやフォルダ、ウィジェットの配置と設定、ディスプレイ専用の設定をまとめて保存します。コントロールセンターから切り替えられます。") {
            Row(title: "名前") {
                TextField(presets.defaultName(), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(save)
                Button("保存", action: save).buttonStyle(.glass)
            }
        }
        GlassCard(title: "保存したプリセット",
                  footer: presets.presets.isEmpty ? "まだプリセットはありません。" : "名前をクリックすると変更できます。") {
            ForEach(Array(presets.presets.enumerated()), id: \.element.id) { i, p in
                if i > 0 { RowDivider() }
                PresetSettingsRow(preset: p, current: p.id == current)
            }
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        withAnimation(.smooth) { _ = presets.saveCurrent(name: name.isEmpty ? presets.defaultName() : name) }
        newName = ""
    }
}

private struct PresetSettingsRow: View {
    let preset: SettingsPreset
    let current: Bool
    @State private var draft = ""
    @State private var confirmOverwrite = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    private var store: SettingsPresets { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(current ? 1 : 0)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                TextField("名前", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: current ? .semibold : .regular))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Text(preset.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("適用") { store.apply(preset.id) }
                .buttonStyle(.glass)
                .disabled(current)
            Button("上書き保存") { confirmOverwrite = true }
                .buttonStyle(.glass)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.glass)
                .help("削除")
        }
        .frame(minHeight: 44)
        .onAppear { draft = preset.name }
        .onChange(of: preset.name) { _, n in if !focused { draft = n } }
        .alert(loc("「%@」を現在の設定で上書きしますか？", preset.name), isPresented: $confirmOverwrite) {
            Button("上書き保存") { store.overwrite(preset.id) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert(loc("「%@」を削除しますか？", preset.name), isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { withAnimation(.smooth) { store.delete(preset.id) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { draft = preset.name } else if name != preset.name { store.rename(preset.id, to: name) }
    }
}
