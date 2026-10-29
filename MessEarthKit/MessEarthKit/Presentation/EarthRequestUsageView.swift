import Foundation
import MessEarthKit
import Observation
import SwiftUI

struct EarthRequestUsageDisplay
{
    let requests: String
    let sessions: String
    let detail: String
    let coverage: String
    let issue: String?

    init(snapshot: EarthRequestUsageSnapshot)
    {
        requests = snapshot.totalRequests.map(String.init) ?? "Unavailable"
        sessions = snapshot.sessionRequests.map(String.init) ?? "Unavailable"
        detail = "Metadata: \(snapshot.metadataRequests.map(String.init) ?? "—") · GLBs: \(snapshot.tileRequests.map(String.init) ?? "—") · Completed: \(snapshot.succeededRequests.map(String.init) ?? "—") · Failed: \(snapshot.failedRequests.map(String.init) ?? "—") · Cancelled: \(snapshot.cancelledRequests.map(String.init) ?? "—") · Pending/interrupted: \(snapshot.pendingRequests.map(String.init) ?? "—")"
        if let cleared = snapshot.lastClearedAt
        { coverage = "Local history cleared \(cleared.formatted(date: .abbreviated, time: .shortened))." }
        else if let started = snapshot.trackingStartedAt
        { coverage = "Local tracking began \(started.formatted(date: .abbreviated, time: .shortened)). Earlier requests are not included." }
        else { coverage = "Local request history could not be loaded." }
        issue = snapshot.trackingIssue
    }
}

/// UI scheduling and cached display text stay here. The SDK store performs all
/// persistence on its own actor; source jobs receive only an actor-neutral sink.
@MainActor
@Observable
final class EarthRequestUsageViewModel
{
    private(set) var display: EarthRequestUsageDisplay?
    private(set) var isClearing = false
    @ObservationIgnored private let store: EarthRequestUsageStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var needsRefresh = false

    init(store: EarthRequestUsageStore)
    {
        self.store = store
        refresh()
    }

    deinit { refreshTask?.cancel(); expirationTask?.cancel(); clearTask?.cancel() }

    var requestObserver: EarthRequestObserver
    {
        let store = store
        let observer: EarthRequestObserver =
        { [weak self] event in
            await store.record(event)
            await self?.refresh()
        }
        return observer
    }

    func refresh()
    {
        guard !isClearing else { return }
        guard refreshTask == nil else { needsRefresh = true; return }
        needsRefresh = false
        expirationTask?.cancel()
        let expected = generation
        let delay = max(0, 1 - Date().timeIntervalSince(refreshedAt))
        refreshTask = Task
        { [weak self, store] in
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
            catch { return }
            let snapshot = await store.snapshot()
            guard let self, !Task.isCancelled, expected == generation else { return }
            apply(snapshot)
            refreshTask = nil
            if needsRefresh { refresh() }
            else { scheduleExpiration(snapshot.nextExpiration ?? (snapshot.trackingIssue == nil ? nil : Date().addingTimeInterval(60))) }
        }
    }

    func clearCounter()
    {
        guard !isClearing else { return }
        isClearing = true
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        expirationTask?.cancel()
        clearTask = Task
        { [weak self, store] in
            let snapshot = await store.clear()
            guard let self, !Task.isCancelled else { return }
            apply(snapshot)
            isClearing = false
            clearTask = nil
            // Pick up any new attempts that entered transport during the clear.
            scheduleExpiration(Date().addingTimeInterval(1))
        }
    }

    private func apply(_ snapshot: EarthRequestUsageSnapshot)
    {
        display = EarthRequestUsageDisplay(snapshot: snapshot)
        refreshedAt = Date()
    }

    private func scheduleExpiration(_ next: Date?)
    {
        guard let next else { return }
        let delay = min(60, max(0.1, next.timeIntervalSinceNow + 0.05))
        expirationTask = Task
        { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.refresh()
        }
    }
}

struct EarthRequestUsageView: View
{
    let viewModel: EarthRequestUsageViewModel
    @Binding var showsDetails: Bool

    var body: some View
    {
        VStack(alignment: .leading, spacing: 6)
        {
            HStack(alignment: .top, spacing: 12)
            {
                VStack(alignment: .leading, spacing: 4)
                {
                    if let display = viewModel.display
                    {
                        Text("Requests — last 30 days: \(display.requests)").monospacedDigit()
                        Text("Session requests: \(display.sessions)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    else { Text("Loading local request history…") }
                }
                Spacer()
                Button("Clear counter", action: viewModel.clearCounter).disabled(viewModel.isClearing)
                    .help("Clears local request statistics only. Captures, keys, and Google usage are unchanged.")
            }
            if let display = viewModel.display
            {
                if let issue = display.issue { Text(issue).foregroundStyle(.orange) }
                Text(display.coverage).foregroundStyle(.secondary)
                DisclosureGroup("Usage details", isExpanded: $showsDetails)
                {
                    Text(display.detail).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Rolling 30-day attempts from this app, including failures and retries. Session requests are root-tileset attempts, not confirmed charges or your Google billing balance.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
