import AppKit
import Foundation
import MetadataStripperCore
import UniformTypeIdentifiers

struct ImageItem: Identifiable, Equatable {
    enum Status: Equatable {
        case ready
        case processing
        case cleaned(SanitizationResult)
        case failed(String)
        case unsupported(String)
    }

    let id: UUID
    let url: URL
    let inspection: ImageInspection?
    var status: Status

    var canProcess: Bool {
        switch status {
        case .ready, .failed:
            return inspection != nil
        case .processing, .cleaned, .unsupported:
            return false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [ImageItem] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var completedCount = 0
    @Published private(set) var processingTotal = 0
    @Published private(set) var currentFilename: String?
    @Published private(set) var resultMessage: String?

    private var cleaningTask: Task<Void, Never>?

    var processableCount: Int {
        items.count(where: \ImageItem.canProcess)
    }

    var cleanedItems: [ImageItem] {
        items.filter {
            if case .cleaned = $0.status {
                return true
            }
            return false
        }
    }

    var readySummary: String {
        let ready = processableCount
        let unavailable = items.count - ready - cleanedItems.count

        if ready == 1, unavailable == 0 {
            return "1 image is ready."
        }
        if ready > 0, unavailable == 0 {
            return "\(ready) images are ready."
        }
        if ready > 0 {
            return "\(ready) images are ready, and \(unavailable) will be skipped."
        }
        if cleanedItems.count == items.count, !items.isEmpty {
            return "All clean copies have been saved."
        }
        return "The selected images can’t be cleaned."
    }

    func chooseImages() {
        guard !isProcessing else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Images"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return
        }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        guard !isProcessing else {
            return
        }

        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        let newURLs = urls
            .filter(\.isFileURL)
            .filter { !existingPaths.contains($0.standardizedFileURL.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for url in newURLs {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let inspection = try ImageSanitizer.inspect(url)
                items.append(
                    ImageItem(id: UUID(), url: url, inspection: inspection, status: .ready)
                )
            } catch {
                items.append(
                    ImageItem(
                        id: UUID(),
                        url: url,
                        inspection: nil,
                        status: .unsupported(error.localizedDescription)
                    )
                )
            }
        }
        resultMessage = nil
    }

    func remove(_ item: ImageItem) {
        guard !isProcessing else {
            return
        }
        items.removeAll { $0.id == item.id }
        resultMessage = nil
    }

    func clear() {
        guard !isProcessing else {
            return
        }
        items.removeAll()
        completedCount = 0
        processingTotal = 0
        currentFilename = nil
        resultMessage = nil
    }

    func chooseOutputAndClean() {
        guard !isProcessing, processableCount > 0 else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Save Clean Copies"
        panel.message = "Choose a folder for the clean copies. Existing files will not be replaced."
        panel.prompt = "Save Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let outputDirectory = panel.url else {
            return
        }

        cleaningTask = Task {
            await clean(into: outputDirectory)
        }
    }

    func cancelProcessing() {
        guard isProcessing else {
            return
        }
        cleaningTask?.cancel()
    }

    func revealCleanedFiles() {
        let urls = cleanedItems.compactMap { item -> URL? in
            if case let .cleaned(result) = item.status {
                return result.outputURL
            }
            return nil
        }
        guard !urls.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func clean(into outputDirectory: URL) async {
        let itemIDs = items.filter(\.canProcess).map(\.id)
        guard !itemIDs.isEmpty else {
            return
        }

        isProcessing = true
        completedCount = 0
        processingTotal = itemIDs.count
        currentFilename = nil
        resultMessage = nil

        let outputAccess = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if outputAccess {
                outputDirectory.stopAccessingSecurityScopedResource()
            }
            isProcessing = false
            currentFilename = nil
            cleaningTask = nil
        }

        var successes = 0
        var failures = 0
        var wasCancelled = false

        for id in itemIDs {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            guard let index = items.firstIndex(where: { $0.id == id }) else {
                continue
            }

            let inputURL = items[index].url
            items[index].status = .processing
            currentFilename = inputURL.lastPathComponent

            let inputAccess = inputURL.startAccessingSecurityScopedResource()
            let operation = await Task.detached(priority: .userInitiated) {
                Result {
                    try ImageSanitizer.stripMetadata(from: inputURL, into: outputDirectory)
                }
            }.value
            if inputAccess {
                inputURL.stopAccessingSecurityScopedResource()
            }

            guard let updatedIndex = items.firstIndex(where: { $0.id == id }) else {
                continue
            }
            switch operation {
            case let .success(result):
                items[updatedIndex].status = .cleaned(result)
                successes += 1
            case let .failure(error):
                items[updatedIndex].status = .failed(error.localizedDescription)
                failures += 1
            }
            completedCount += 1

            if Task.isCancelled {
                wasCancelled = true
                break
            }
        }

        if wasCancelled {
            if successes == 0, failures == 0 {
                resultMessage = "Cleaning was canceled. No clean copies were saved."
            } else if failures == 0 {
                resultMessage = successes == 1
                    ? "Cleaning was canceled after 1 clean copy was saved. Originals were not changed."
                    : "Cleaning was canceled after \(successes) clean copies were saved. Originals were not changed."
            } else {
                resultMessage = "Cleaning was canceled. \(successes) clean copies were saved, and \(failures) files could not be cleaned."
            }
        } else if failures == 0 {
            resultMessage = successes == 1
                ? "1 clean copy was saved. The original was not changed."
                : "\(successes) clean copies were saved. The originals were not changed."
        } else if successes == 0 {
            resultMessage = failures == 1
                ? "The image could not be cleaned. No output was saved."
                : "The images could not be cleaned. No outputs were saved."
        } else {
            resultMessage = "\(successes) clean copies were saved, and \(failures) files could not be cleaned."
        }
    }
}
