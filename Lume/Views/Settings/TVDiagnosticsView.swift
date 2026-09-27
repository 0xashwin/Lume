//
//  TVDiagnosticsView.swift
//  Lume
//
//  Diagnostics on Apple TV, which can neither attach a file nor compose mail.
//  The report is condensed to a summary that fits a `mailto:` QR code: scanning
//  it with a phone opens a pre-addressed email with the summary as its body.
//  The same recent problems are listed on screen, so a user can also read them
//  out or photograph them.
//

#if os(tvOS)

    import OSLog
    import SwiftData
    import SwiftUI

    /// Full-screen diagnostics, presented from the add-playlist form (first
    /// launch, no Settings yet) and from Settings ▸ About.
    struct TVDiagnosticsView: View {
        var origin: String?
        var visibleProblem: String?

        @Environment(\.dismiss) private var dismiss
        @Environment(\.modelContext) private var modelContext
        @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
        @AppStorage(DebugLogSettings.enabledKey) private var detailedLogging = false
        @State private var summary: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Send Diagnostics")
                            .font(.system(size: 38, weight: .bold))
                        Text("Scan the code with your phone to email a diagnostic summary to \(SupportInfo.email). Add a sentence about what went wrong before you send it.")
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    HStack(alignment: .top, spacing: 48) {
                        qrCode
                        summaryText
                    }
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                    VStack(alignment: .leading, spacing: 8) {
                        TVOptionToggleRow(title: "Detailed Logging", isOn: $detailedLogging)
                        Text("Diagnostics are always recorded on this device and never leave it unless you send them. Detailed logging adds verbose entries — turn it on only when asked to.")
                            .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }

                    Button("Done") { dismiss() }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
                .frame(maxWidth: 1300, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
            }
            .tvSettingsBackground()
            .task { await loadSummary() }
        }

        @ViewBuilder
        private var qrCode: some View {
            if let summary {
                QRCodeView(string: DiagnosticsReport.mailtoLink(summary: summary, appVersion: SupportInfo.appVersion))
                    .frame(width: 420, height: 420)
                    .padding(20)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
                    .frame(width: 460, height: 460)
            }
        }

        private var summaryText: some View {
            Text(verbatim: summary ?? "")
                .font(.system(size: 20).monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func loadSummary() async {
            let exporter = DiagnosticsReport.exporter(
                container: modelContext.container,
                cloudSync: cloudSync,
                origin: origin,
                visibleProblem: visibleProblem
            )
            Logger.app.notice("Diagnostic summary shown (from \(origin ?? "Settings"))")
            summary = await Task.detached { exporter.compactSummary() }.value
        }
    }

    /// The Settings ▸ About entry point.
    struct TVDiagnosticsSection: View {
        @State private var isPresented = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Troubleshooting")
                Button {
                    isPresented = true
                } label: {
                    HStack {
                        Label("Send Diagnostics", systemImage: "stethoscope")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                Text("Something not working? Send a diagnostic summary to the developer.")
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
            .fullScreenCover(isPresented: $isPresented) {
                TVDiagnosticsView(origin: "Settings")
            }
        }
    }

#endif
