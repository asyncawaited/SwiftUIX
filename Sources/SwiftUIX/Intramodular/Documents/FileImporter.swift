//
// Copyright (c) Vatsal Manot
//

#if os(macOS)

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 14.0, *)
public extension View {
    /// Presents a system dialog for importing an existing file or directory.
    ///
    /// This modifier follows the behavior of SwiftUI's `fileImporter`, while
    /// using `NSOpenPanel` to correctly support mixed directory and file-package
    /// selections on macOS.
    nonisolated func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        browserOptions: FileDialogBrowserOptions,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false,
            browserOptions: browserOptions,
            onCompletion: { result in
                onCompletion(result.flatMap { urls in
                    guard let url = urls.first else {
                        return .failure(CocoaError(.fileReadUnknown))
                    }

                    return .success(url)
                })
            },
            onCancellation: { }
        )
    }

    /// Presents a system dialog for importing one or more files or directories.
    ///
    /// This modifier follows the behavior of SwiftUI's `fileImporter`, while
    /// using `NSOpenPanel` to correctly support mixed directory and file-package
    /// selections on macOS.
    nonisolated func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        browserOptions: FileDialogBrowserOptions,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            browserOptions: browserOptions,
            onCompletion: onCompletion,
            onCancellation: { }
        )
    }

    /// Presents a system dialog for importing one or more files or directories.
    ///
    /// The `isPresented` binding is reset before either callback is invoked.
    /// Cancellation is reported separately, matching SwiftUI's modern file
    /// importer API.
    nonisolated func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        browserOptions: FileDialogBrowserOptions,
        onCompletion: @escaping (Result<[URL], Error>) -> Void,
        onCancellation: @escaping () -> Void
    ) -> some View {
        modifier(
            _FileImporterModifier(
                isPresented: isPresented,
                configuration: _FileImporterConfiguration(
                    allowedContentTypes: allowedContentTypes,
                    allowsMultipleSelection: allowsMultipleSelection,
                    browserOptions: browserOptions
                ),
                onCompletion: onCompletion,
                onCancellation: onCancellation
            )
        )
    }
}

@available(macOS 14.0, *)
private struct _FileImporterConfiguration {
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let browserOptions: FileDialogBrowserOptions

    func allows(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]
        ) else {
            return false
        }

        if values.isDirectory == true, values.isPackage != true {
            return true
        }

        if let contentType = values.contentType,
           allowedContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }

        let filenameExtension = url.pathExtension.lowercased()

        return !filenameExtension.isEmpty && allowedContentTypes.contains { contentType in
            contentType.tags[.filenameExtension]?.contains { tag in
                tag.caseInsensitiveCompare(filenameExtension) == .orderedSame
            } == true
        }
    }

    @MainActor
    func configure(_ panel: NSOpenPanel) {
        let selectsDirectories = allowedContentTypes.contains { type in
            type == .directory || type == .folder
        }
        let selectsFilePackages = allowedContentTypes.contains { type in
            type != .directory && type != .folder && type.conforms(to: .directory)
        }

        panel.allowedContentTypes = allowedContentTypes
        panel.canChooseFiles = !selectsDirectories || selectsFilePackages
        panel.canChooseDirectories = selectsDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.treatsFilePackagesAsDirectories = browserOptions.contains(.enumeratePackages)
            || !selectsFilePackages
        panel.showsHiddenFiles = browserOptions.contains(.includeHiddenFiles)
        panel.isExtensionHidden = !browserOptions.contains(.displayFileExtensions)
    }
}

@available(macOS 14.0, *)
private struct _FileImporterModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let configuration: _FileImporterConfiguration
    let onCompletion: (Result<[URL], Error>) -> Void
    let onCancellation: () -> Void

    func body(content: Content) -> some View {
        content.background {
            _FileImporterPresenter(
                isPresented: isPresented,
                configuration: configuration,
                onCompletion: onCompletion,
                onCancellation: onCancellation
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

@available(macOS 14.0, *)
private struct _FileImporterPresenter: NSViewRepresentable {
    let isPresented: Binding<Bool>
    let configuration: _FileImporterConfiguration
    let onCompletion: (Result<[URL], Error>) -> Void
    let onCancellation: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            configuration: configuration,
            onCompletion: onCompletion,
            onCancellation: onCancellation,
            sourceView: view
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSOpenSavePanelDelegate {
        private var isPresented: Binding<Bool>?
        private var configuration: _FileImporterConfiguration?
        private var onCompletion: ((Result<[URL], Error>) -> Void)?
        private var onCancellation: (() -> Void)?
        private var panel: NSOpenPanel?
        private var isPresentationScheduled = false

        func update(
            isPresented: Binding<Bool>,
            configuration: _FileImporterConfiguration,
            onCompletion: @escaping (Result<[URL], Error>) -> Void,
            onCancellation: @escaping () -> Void,
            sourceView: NSView
        ) {
            self.isPresented = isPresented
            self.configuration = configuration
            self.onCompletion = onCompletion
            self.onCancellation = onCancellation

            if isPresented.wrappedValue {
                schedulePresentation(from: sourceView)
            } else if panel != nil {
                dismiss()
            }
        }

        func dismiss() {
            panel?.cancel(nil)
        }

        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            configuration?.allows(url) ?? false
        }

        private func schedulePresentation(from sourceView: NSView) {
            guard panel == nil, !isPresentationScheduled else {
                return
            }

            isPresentationScheduled = true

            DispatchQueue.main.async { [weak self, weak sourceView] in
                guard let self else {
                    return
                }

                self.isPresentationScheduled = false

                guard self.isPresented?.wrappedValue == true else {
                    return
                }

                self.present(from: sourceView?.window)
            }
        }

        private func present(from sourceWindow: NSWindow?) {
            guard let configuration, panel == nil else {
                return
            }

            let panel = NSOpenPanel()
            configuration.configure(panel)
            panel.delegate = self
            self.panel = panel

            let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
                guard let self, let panel, self.panel === panel else {
                    return
                }

                let urls = panel.urls

                self.panel = nil
                self.isPresented?.wrappedValue = false

                if response == .OK {
                    self.onCompletion?(.success(urls))
                } else {
                    self.onCancellation?()
                }
            }

            if let sourceWindow, sourceWindow.attachedSheet == nil {
                panel.beginSheetModal(for: sourceWindow, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}

#endif
