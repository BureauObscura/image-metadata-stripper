import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false
    @AccessibilityFocusState private var resultIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Image Metadata Stripper")
                    .font(.title2.weight(.semibold))
                Text("Clean copies are created without changing the originals.")
                    .foregroundStyle(.secondary)
            }

            if model.items.isEmpty {
                emptyState
            } else {
                fileState
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.resultMessage) { _, message in
            resultIsFocused = message != nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Drop images here")
                .font(.title3.weight(.medium))

            Text("You can use JPEG, PNG, HEIC, or TIFF files.")
                .foregroundStyle(.secondary)

            Button("Choose Images…") {
                model.chooseImages()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            Text("Files stay on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 5])
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image drop area")
        .accessibilityHint("Drop JPEG, PNG, HEIC, or TIFF files here, or choose the Choose Images button.")
    }

    private var fileState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.readySummary)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Add Images…") {
                    model.chooseImages()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.isProcessing)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        ImageItemRow(item: item) {
                            model.remove(item)
                        }
                        .padding(.horizontal, 10)

                        if item.id != model.items.last?.id {
                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }

            if model.isProcessing {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(
                            value: Double(model.completedCount),
                            total: Double(max(model.processingTotal, 1))
                        )
                        Text(processingText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Cleaning images")
                    .accessibilityValue(processingText)

                    Button("Cancel") {
                        model.cancelProcessing()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            } else if let resultMessage = model.resultMessage {
                Text(resultMessage)
                    .font(.callout)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($resultIsFocused)
            } else {
                Text("Location, camera, dates, descriptions, and other optional metadata will be removed. Color and orientation data needed for display are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button(model.cleanedItems.isEmpty ? "Clear" : "Clean More Images") {
                    model.clear()
                }
                .disabled(model.isProcessing)

                Spacer()

                if !model.cleanedItems.isEmpty {
                    Button("Reveal in Finder") {
                        model.revealCleanedFiles()
                    }
                    .disabled(model.isProcessing)
                }

                if model.processableCount > 0 {
                    Button(model.cleanedItems.isEmpty ? "Save Clean Copies…" : "Try Again…") {
                        model.chooseOutputAndClean()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isProcessing)
                }
            }
        }
    }

    private var processingText: String {
        let position = min(model.completedCount + 1, model.processingTotal)
        if let filename = model.currentFilename {
            return "Cleaning \(position) of \(model.processingTotal): \(filename)"
        }
        return "Cleaning \(position) of \(model.processingTotal)."
    }
}

private struct ImageItemRow: View {
    let item: ImageItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if case .processing = item.status {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove \(item.url.lastPathComponent) from this batch")
                .accessibilityLabel("Remove \(item.url.lastPathComponent)")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .ready:
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        case .processing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .cleaned:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed, .unsupported:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var detailText: String {
        switch item.status {
        case .ready:
            guard let inspection = item.inspection else {
                return "The image is ready."
            }
            return "\(inspection.formatName), \(inspection.pixelWidth) × \(inspection.pixelHeight), \(Self.byteFormatter.string(fromByteCount: inspection.byteCount))"
        case .processing:
            return "Metadata is being removed."
        case let .cleaned(result):
            return "The clean copy was saved as \(result.outputURL.lastPathComponent)."
        case let .failed(message), let .unsupported(message):
            return message
        }
    }

    private var detailColor: Color {
        switch item.status {
        case .failed, .unsupported:
            return .orange
        case .ready, .processing, .cleaned:
            return .secondary
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()
}
