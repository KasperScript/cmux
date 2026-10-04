import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Opening agent chat tabs on the workspace store, and letting their views go when the store
/// drops them (cmux-tui/spec/commands.md, new-conversation-tab).
extension AgentTabStore {
    /// The `origin` of the app's `new-conversation-tab` requests for agent chats.
    static let createOrigin = "cmux-next-agent-tab"

    /// Adds a new agent chat tab to `pane`'s strip in the store and returns it once committed.
    ///
    /// - Parameters:
    ///   - pane: The pane (its daemon handle).
    ///   - daemon: The daemon that owns the pane.
    ///   - session: The acpmux session it shows; nil starts a new chat.
    ///   - seed: What a new chat inherits (cwd, a draft); ignored with a session.
    ///   - newTab: Shows the new tab page until it becomes a chat; the
    ///     handler gets the terminal or browser choices and shortcut edits.
    ///   - spare: A prewarmed page (``makeSpare(_:)``) the new tab page adopts.
    ///   - linked: A `cmux://session/<id>` link opened it: its page refuses a session the
    ///     daemon does not have instead of falling back.
    ///   - adopt: The outside chat it resumes (`harness:agentSessionId`).
    ///   - idempotencyKey: The creation's key; a retry with it returns the same tab. Fresh by default.
    /// - Throws: When this Mac has no install id or the daemon refuses the tab.
    func open(in pane: PaneID, of daemon: DaemonService, session: String? = nil, seed: AgentPaneSeedSource? = nil,
              newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
              linked: Bool = false, adopt: AgentPaneAdopt? = nil,
              idempotencyKey: String = UUID().uuidString.lowercased()) async throws -> AgentTabCreated {
        guard let localHost else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: localHost, session: session, harness: adopt?.harness)
        let created = try await create(pane, daemon, record, idempotencyKey)
        let key = created.key
        if let session { sessions[key] = session }
        newTabPages[key] = newTab
        if session == nil { seeds[key] = seed }
        if linked { linkedSessions.insert(key) }
        if let adopt { adoptions["\(adopt.harness):\(adopt.agentSessionId)"] = key }
        if let spare, let newTab {
            if views[key] == nil {
                standaloneViews.remove(spare)
                wire(spare.model, key: key)
                views[key] = spare
                let store = lookup(key)?.store ?? daemon.store
                viewStores[key] = store
                watch(store)
                spare.adoptNewTab(newTab.page)
            } else if recycle?(spare) != true {
                // The tab showed (and made its own page) before the store answered.
                retirer.retire(spare)
            }
        }
        return created
    }

    /// ``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)`` in `pane`, as a tracked
    /// task: the pane selects the tab once the store reports it (unless `select` is false), then
    /// `then` gets its id. A refusal is logged and reported through the registry.
    func openTab(in pane: PaneController, session: String? = nil, seed: AgentPaneSeedSource? = nil,
                 newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
                 linked: Bool = false, select: Bool = true, then: (@MainActor (String) -> Void)? = nil) {
        let handle = pane.pane.handle
        let daemon = pane.daemon
        pane.services.registry.track(Task { [weak self, weak pane] in
            guard let self else { return nil }
            do {
                let created = try await open(in: handle, of: daemon, session: session, seed: seed, newTab: newTab,
                                             spare: spare, linked: linked)
                if select { pane?.selectWhenReported(surface: created.surface) }
                then?(created.key)
                return nil
            } catch {
                daemon.logger.error("new-conversation-tab (agent) failed: \(String(describing: error), privacy: .public)")
                return "new agent tab: \(error)"
            }
        })
    }

    /// The tab already resuming the outside chat `adopt` while a tree lists it.
    func tab(resuming adopt: AgentPaneAdopt) -> String? {
        guard let key = adoptions["\(adopt.harness):\(adopt.agentSessionId)"], isAgentTab(key) else { return nil }
        return key
    }

    /// The tab closed (``TabContentCache/release(_:)``): stop its page and forget its view state.
    func release(_ key: String) {
        if let view = views.removeValue(forKey: key) {
            // An untouched new tab page goes back to the pool (no teardown, no rebuild, R81).
            if newTabPages[key] != nil, recycle?(view) == true {
                standaloneViews.add(view)
            } else {
                retirer.retire(view)
            }
        }
        sessions[key] = nil
        newTabPages[key] = nil
        seeds[key] = nil
        adoptions = adoptions.filter { $0.value != key }
        linkedSessions.remove(key)
        pendingTurns[key] = nil
        viewStores[key] = nil
        forgetUnusedStores()
        stopCustomizationWhenUnused()
    }

    /// Lets go of the views of tabs `store` no longer lists, once it is connected with a live
    /// tree. While the daemon is away its tabs keep their views.
    func releaseGoneTabs(in store: DaemonStore) {
        guard let live = Self.liveTabs(store) else { return }
        for (key, owner) in viewStores where owner === store && !live.contains(key) {
            release(key)
        }
    }

    static func liveTabs(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
    }

    func watch(_ store: DaemonStore) {
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no view belongs to the store
        watches[id] = Task { [weak self] in
            for await live in Observations({ Self.liveTabs(store) }) where live != nil {
                guard let self else { return }
                self.releaseGoneTabs(in: store)
            }
        }
    }

    private func forgetUnusedStores() {
        let used = Set(viewStores.values.map { ObjectIdentifier($0) })
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }
}
