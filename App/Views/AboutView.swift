import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Abdul Basit Khudair").font(.title2)
                Link("Telegram: t.me/ipafilesfor", destination: URL(string: "https://t.me/ipafilesfor")!)
                Link("TikTok: @087.n", destination: URL(string: "https://www.tiktok.com/@087.n")!)
                Spacer()
            }
            .padding()
            .navigationTitle("Credits")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
