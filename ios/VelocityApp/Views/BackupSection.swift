import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup: automatic backups, a folder that survives deleting the app, and restore.
struct BackupSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackupStore.lastBackupKey) private var lastBackup: Double = 0
    @AppStorage(BackupStore.lastFolderErrorKey) private var folderError = ""
    @State private var folderName = BackupStore.folderName
    @State private var picking: PickMode?
    @State private var pending: BackupFile?
    @State private var status: String?
    @State private var working = false

    enum PickMode { case folder, restore }

    var body: some View {
        Section {
            HStack {
                Text("Last backup")
                Spacer()
                Text(lastDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet").foregroundStyle(Theme.muted)
            }
            Button("Back up now") {
                working = true
                Task {
                    do { try await model.backUp(); status = "Backed up." } catch { status = "Backup failed: \(error.localizedDescription)" }
                    folderName = BackupStore.folderName
                    working = false
                }
            }
            .disabled(working)
            Button(folderName.map { "Backup folder: \($0)" } ?? "Choose a backup folder…") { picking = .folder }
            if folderName != nil {
                Button("Stop using this folder", role: .destructive) { BackupStore.setFolder(nil); folderName = nil; folderError = "" }
            }
            if !folderError.isEmpty, folderName != nil {
                Text("Last copy to the folder failed: \(folderError)").font(.caption).foregroundStyle(Theme.warn)
            }
            if let latest = latestLocal {
                ShareLink(item: latest) { Label("Share latest backup", systemImage: "square.and.arrow.up") }
            }
            Button("Restore from a backup…") { picking = .restore }
            if let status { Text(status).font(.caption).foregroundStyle(Theme.muted) }
        } header: { Text("Backup") } footer: {
            Text("The app backs up your sets, program, debriefs, hand-logged sets and settings after each session and when you leave the app (at most every 15 minutes). Videos aren't included. Copies are kept in Files › On My iPhone › Velocity › Backups, but those go if the app is deleted, so choose a folder in iCloud Drive to keep one there too. Restoring replaces the data on this phone, after backing up what's there now.")
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .folder ? [.folder] : [.json]) { result in
            let mode = picking
            picking = nil
            guard case let .success(url) = result else { return }
            if mode == .folder {
                BackupStore.setFolder(url)
                folderName = BackupStore.folderName
                Task { _ = try? await model.backUp(); status = "Backups now also go to \(folderName ?? "that folder")." }
            } else {
                do { pending = try BackupStore.read(url) } catch { status = "That file isn't a Velocity backup (\(error.localizedDescription))." }
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { b in
            Button("Replace data on this phone", role: .destructive) {
                working = true
                Task {
                    do { try await model.restore(b); status = "Restored the backup from \(b.created.formatted(date: .abbreviated, time: .shortened))." }
                    catch { status = "Restore failed: \(error.localizedDescription)" }
                    working = false
                }
            }
        } message: { b in
            Text("Backup from \(b.created.formatted(date: .abbreviated, time: .shortened)) (version \(b.appVersion)): \(b.sets.count) sets, \(b.debriefs.count) debriefs, \(b.manualSets.count) hand-logged sets\(b.program == nil ? "" : ", and a program"). What's on this phone now is backed up first.")
        }
    }

    private var lastDate: Date? {
        lastBackup > 0 ? Date(timeIntervalSince1970: lastBackup) : nil
    }

    private var latestLocal: URL? {
        _ = lastBackup
        let files = (try? FileManager.default.contentsOfDirectory(at: BackupStore.localFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }
}
