import SwiftUI

struct SourcesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.forgeTheme) private var T

    @State private var newSourceText: String = ""
    @State private var editingRemovalConfirm: URL? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GlassSection("Add Source") {
                    HStack {
                        TextField("https://example.com/apps.json", text: $newSourceText)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled(true)
                        Button("Add") {
                            let trimmed = newSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
                            sources.addSource(trimmed)
                            newSourceText = ""
                            Task { await sources.refreshAll() }
                        }
                        .buttonStyle(GlassTactileButtonStyle())
                    }
                    .padding(.horizontal, 12)
                }

                GlassSection("Sources") {
                    VStack(spacing: 8) {
                        ForEach(sources.sources, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.absoluteString).font(T.mono(12)).foregroundColor(T.ink2).lineLimit(1)
                                    if let err = sources.perSourceError[url] {
                                        Text("Last fetch error: \(err.localizedDescription)").font(T.mono(10)).foregroundColor(T.bad)
                                    } else {
                                        Text("OK").font(T.mono(10)).foregroundColor(T.ink3)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    editingRemovalConfirm = url
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .fGlass(cornerRadius: 10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.rule2, lineWidth: AppStroke.hairline))
                        }
                        if sources.sources.isEmpty {
                            Text("No sources added. Add an AltStore-compatible apps.json URL above.")
                                .font(T.mono(12)).foregroundColor(T.ink3).padding(12)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(GlassTactileButtonStyle())
                }
            }
            .confirmationDialog("Delete source?", isPresented: Binding(get: { editingRemovalConfirm != nil }, set: { if !$0 { editingRemovalConfirm = nil } })) {
                Button("Delete", role: .destructive) {
                    if let url = editingRemovalConfirm {
                        sources.removeSource(url)
                        Task { await sources.refreshAll() }
                    }
                    editingRemovalConfirm = nil
                }
                Button("Cancel", role: .cancel) {
                    editingRemovalConfirm = nil
                }
            } message: {
                Text("This will remove the source and its cached data.")
            }
        }
    }
}
