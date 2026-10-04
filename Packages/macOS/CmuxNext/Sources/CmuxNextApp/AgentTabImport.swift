import CmuxNextDaemon
import Foundation
import Observation

/// One-time import of the agent tabs an older build recorded in the window document
/// (`WindowStateDocument.legacyAgentTabs`, R138) into the workspace store
/// (cmux-tui/spec/commands.md, new-conversation-tab). Each recorded tab with a session becomes a store tab in
/// its pane under the key `agent-tab-import-<old id>`, so a crash mid-import replays instead of
/// duplicating. Windows that selected an old tab select its store tab. Imported records, records
/// without a session and records of panes the trees no longer list leave the document in one
/// compare-and-swap write; a record whose pane's daemon is away or refused it stays for the next
/// launch.
@MainActor
enum AgentTabImport {
    /// The idempotency key of the store tab imported for old tab `id`.
    static func key(for id: String) -> String { "agent-tab-import-" + id }

    /// Imports once the local daemon's tree has loaded.
    static func start(_ services: AppServices) {
        guard let windowState = services.daemon.windowState else { return }
        let store = services.daemon.store
        // task-owner: one-shot, ends after the first load
        Task {
            for await loaded in Observations({ store.isLoaded }) where loaded {
                await run(services, windowState: windowState)
                return
            }
        }
    }

    static func run(_ services: AppServices, windowState: WindowStateStore) async {
        guard services.daemon.supports(DaemonCapabilities.shared.agentSessionTabs),
              let document = try? await windowState.load(), !document.legacyAgentTabs.isEmpty else { return }
        var renamed: [String: String] = [:]
        var remaining: [String: [AgentTabRecord]] = [:]
        for (paneKey, records) in document.legacyAgentTabs {
            guard let pane = services.pane(id: paneKey) else { continue } // the pane is gone: drop its tabs
            let daemon = services.daemon(for: pane)
            for record in records {
                guard let session = record.session else { continue } // an empty new chat is not restored
                do {
                    let created = try await services.agentTabs.open(in: pane.handle, of: daemon, session: session,
                                                                    idempotencyKey: key(for: record.id))
                    renamed[record.id] = created.key
                } catch {
                    services.daemon.logger.error("agent tab import: \(String(describing: error), privacy: .public)")
                    remaining[paneKey, default: []].append(record)
                }
            }
        }
        let imported = renamed
        let left = remaining
        _ = try? await windowState.update { document in finish(&document, imported: imported, remaining: left) }
    }

    /// The import's document write: only `remaining` records stay, and every window that selected
    /// an imported old tab selects its store tab.
    nonisolated static func finish(_ document: inout WindowStateDocument, imported: [String: String],
                                   remaining: [String: [AgentTabRecord]]) {
        document.legacyAgentTabs = remaining
        for index in document.windows.indices {
            for (pane, tab) in document.windows[index].selectedTabs {
                if let new = imported[tab] { document.windows[index].selectedTabs[pane] = new }
            }
        }
    }
}
