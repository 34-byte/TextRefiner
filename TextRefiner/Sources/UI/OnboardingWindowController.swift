import Cocoa
import SwiftUI

/// Manages the one-time onboarding window shown on first launch.
/// Guides the user through Accessibility permission and Ollama verification.
final class OnboardingWindowController {
    private var window: NSWindow?
    private var pollingTimer: Timer?

    /// Called when onboarding completes successfully — both checks passed.
    var onComplete: (() -> Void)?

    func show() {
        let onboardingView = OnboardingView(
            onComplete: { [weak self] in
                self?.pollingTimer?.invalidate()
                self?.pollingTimer = nil
                // Use orderOut (instant hide, no animation) instead of close().
                // close() triggers a Core Animation closing transform that holds
                // an internal block reference to the window. If we nil `window`
                // before that animation drains, we get EXC_BAD_ACCESS in
                // _NSWindowTransformAnimation dealloc. orderOut avoids the animation
                // entirely — the window is hidden immediately and will be safely
                // deallocated when AppDelegate sets onboardingController = nil.
                self?.window?.orderOut(nil)
                self?.onComplete?()
                // Do NOT nil self?.window here — let the controller's natural
                // dealloc handle it so no animation is in-flight at release time.
            }
        )

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to TextRefiner"
        w.contentViewController = NSHostingController(rootView: onboardingView)
        w.center()
        w.makeKeyAndOrderFront(nil)

        // Bring our app to the front for onboarding
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}

// MARK: - SwiftUI Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var accessibilityGranted = AccessibilityService.isTrusted()
    @State private var ollamaAvailable: Bool? = nil
    @State private var ollamaInstalled: Bool? = nil
    @State private var modelReady: Bool? = nil
    @State private var checkingOllama = false
    @State private var isInstallingOllama = false
    @State private var installationStatus: String? = nil

    /// Polls Accessibility permission every 1.5s after user goes to System Settings.
    private let accessibilityTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App title
            HStack(spacing: 10) {
                Text("✦")
                    .font(.system(size: 28))
                Text("TextRefiner")
                    .font(.largeTitle.bold())
            }

            Text("Highlight text anywhere on your Mac, press **⌘⇧R**, and get a clearer version instantly. Powered by a local AI model — nothing leaves your Mac.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Refinement takes 2–5 seconds. You'll see a spinner while it works.")
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            // MARK: Accessibility Permission
            HStack(spacing: 12) {
                Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.title2)
                    .foregroundColor(accessibilityGranted ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility Permission")
                        .font(.headline)
                    if accessibilityGranted {
                        Text("Permission granted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Required to read and replace selected text in other apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if !accessibilityGranted {
                    HStack(spacing: 6) {
                        Button("Grant Access") {
                            AccessibilityService.requestPermission()
                        }
                        .buttonStyle(.bordered)

                        Button("Check") {
                            accessibilityGranted = AccessibilityService.isTrusted()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // MARK: Ollama Check
            HStack(spacing: 12) {
                Group {
                    if checkingOllama {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: ollamaAvailable == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.title2)
                            .foregroundColor(ollamaAvailable == true ? .green : .orange)
                    }
                }
                .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama (Local AI)")
                        .font(.headline)

                    if ollamaAvailable == true && modelReady == true {
                        // All good — Ollama running with selected model
                        Text("Ollama running with \(ModelManager.shared.selectedModel?.displayName ?? ModelManager.shared.selectedModelID) model.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if ollamaAvailable == true && modelReady == false {
                        // Ollama running but no model
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ollama is running. Downloading \(ModelManager.shared.selectedModel?.displayName ?? ModelManager.shared.selectedModelID) model...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let status = installationStatus {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            if !isInstallingOllama {
                                Button("Download Model") {
                                    pullModel()
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    } else if ollamaAvailable == false {
                        if ollamaInstalled == false {
                            // Not installed at all
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ollama not installed.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let status = installationStatus {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                Button(action: { installOllama() }) {
                                    if isInstallingOllama {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.8, anchor: .center)
                                    } else {
                                        Text("Install Ollama")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                .disabled(isInstallingOllama)
                            }
                        } else {
                            // Installed but not running
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ollama installed but not running.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let status = installationStatus {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                Button(action: { startOllama() }) {
                                    if isInstallingOllama {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.8, anchor: .center)
                                    } else {
                                        Text("Start Ollama")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                .disabled(isInstallingOllama)
                            }
                        }
                    } else {
                        Text("Checking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("Check") {
                    checkOllamaStatus()
                }
                .buttonStyle(.bordered)
                .disabled(checkingOllama)
            }

            Spacer()

            // MARK: Get Started
            HStack {
                Spacer()
                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!accessibilityGranted || ollamaAvailable != true || modelReady != true)
            }
        }
        .padding(30)
        .frame(width: 520, height: 520)
        .task {
            // Auto-check Ollama on appear
            checkOllamaStatus()
        }
        .onReceive(accessibilityTimer) { _ in
            // Poll for Accessibility permission grant
            if !accessibilityGranted {
                accessibilityGranted = AccessibilityService.isTrusted()
            }
        }
    }

    // MARK: - Ollama Helpers

    private func checkOllamaStatus() {
        checkingOllama = true
        Task {
            let service = OllamaService()

            // Check if Ollama API is reachable
            let running = await service.isAvailable()
            ollamaAvailable = running

            if running {
                ollamaInstalled = true
                // Check if the selected model is downloaded
                let hasModel = await service.isModelAvailable(modelID: ModelManager.shared.selectedModelID)
                modelReady = hasModel

                // Auto-pull model if Ollama is running but model is missing
                if !hasModel && !isInstallingOllama {
                    pullModel()
                }
            } else {
                let installed = isOllamaInstalled()
                ollamaInstalled = installed
                modelReady = nil
            }
            checkingOllama = false
        }
    }

    /// Checks if Ollama is installed — either as macOS app or CLI.
    private func isOllamaInstalled() -> Bool {
        // Check for Ollama.app in /Applications
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            return true
        }

        // Check for ollama CLI in common paths
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    /// Downloads and installs Ollama directly from ollama.com.
    /// No Homebrew required — downloads the macOS app, unzips, moves to /Applications.
    private func installOllama() {
        isInstallingOllama = true
        installationStatus = "Downloading Ollama..."

        Task {
            let script = """
            set -e
            TMPDIR=$(mktemp -d)
            cd "$TMPDIR"
            curl -fsSL -o Ollama.zip "https://ollama.com/download/Ollama-darwin.zip"
            unzip -q Ollama.zip
            mv Ollama.app /Applications/Ollama.app
            rm -rf "$TMPDIR"
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()

                DispatchQueue.global().async {
                    process.waitUntilExit()

                    DispatchQueue.main.async {
                        if process.terminationStatus == 0 {
                            installationStatus = "Installed! Starting Ollama..."
                            startOllama()
                        } else {
                            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                            print("[TextRefiner] Install failed: \(output)")
                            installationStatus = "Installation failed. Please download from ollama.com"
                            isInstallingOllama = false
                        }
                    }
                }
            } catch {
                installationStatus = "Error: \(error.localizedDescription)"
                isInstallingOllama = false
            }
        }
    }

    /// Downloads the selected model via Ollama API with progress updates.
    private func pullModel() {
        isInstallingOllama = true
        let modelName = ModelManager.shared.selectedModel?.displayName ?? ModelManager.shared.selectedModelID
        installationStatus = "Downloading \(modelName) model..."

        Task {
            do {
                try await OllamaService().pullModel(name: ModelManager.shared.selectedModelID) { status in
                    DispatchQueue.main.async {
                        installationStatus = status
                    }
                }

                // Model downloaded successfully
                installationStatus = nil
                isInstallingOllama = false
                modelReady = true
            } catch {
                installationStatus = "Model download failed: \(error.localizedDescription)"
                isInstallingOllama = false
            }
        }
    }

    /// Starts Ollama and waits for it to be ready.
    private func startOllama() {
        isInstallingOllama = true
        installationStatus = "Starting Ollama..."

        Task {
            // Launch Ollama.app if it exists (it runs as a background service)
            if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Ollama"]
                try? process.run()
                process.waitUntilExit()
            } else {
                // Fallback: start via CLI
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", "nohup ollama serve > /tmp/ollama.log 2>&1 &"]
                try? process.run()
                process.waitUntilExit()
            }

            // Give it a moment to start up
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            // Poll for readiness
            for attempt in 1...15 {
                let running = await OllamaService().isAvailable()
                if running {
                    installationStatus = nil
                    isInstallingOllama = false
                    checkOllamaStatus()
                    return
                }
                installationStatus = "Waiting for Ollama to start... (\(attempt)/15)"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            installationStatus = "Ollama didn't start. Try opening Ollama.app manually."
            isInstallingOllama = false
        }
    }
}
