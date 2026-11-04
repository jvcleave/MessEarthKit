import SwiftUI

struct EarthExportQueueView: View
{
    let queue: EarthExportQueue
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        VStack(alignment: .leading, spacing: 12)
        {
            HStack
            {
                Button("START (\(queue.selectedPendingCount))", action: library.startExportQueue)
                    .buttonStyle(.borderedProminent)
                    .disabled(!queue.canStart || !library.canRunExportQueue)
                Button("CANCEL", action: queue.cancel)
                    .disabled((!queue.isRunning && !queue.isCollecting) || queue.isCancelling)
                Spacer()
                Button("COLLECT (\(queue.selectedCompleteCount))…", action: library.chooseExportCollectionFolder)
                    .disabled(!queue.canCollect || !library.canRunExportQueue)
            }
            HStack
            {
                Button("Select All") { queue.setAllIncluded(true) }
                Button("Deselect All") { queue.setAllIncluded(false) }
                Button("Remove Checked", action: queue.removeIncluded)
                    .disabled(!queue.entries.contains { $0.isIncluded && $0.id != queue.activeID })
                Spacer()
                Text("\(queue.pendingCount) pending").foregroundStyle(.secondary)
            }
            .disabled(!queue.canEdit)
            if queue.isLoading || queue.isSaving { ProgressView().controlSize(.small) }
            if let error = queue.loadError
            {
                EarthErrorMessage(error)
                Button("Reload Queue", action: queue.reload)
            }
            if let error = queue.persistenceError
            {
                EarthErrorMessage(error)
                Button("Retry Save", action: queue.retrySave).disabled(!queue.canEdit)
            }
            if let error = queue.operationError { EarthErrorMessage(error) }
            List(queue.entries)
            { entry in row(entry) }
            .listStyle(.inset)
            if !queue.status.isEmpty { Text(queue.status).font(.subheadline) }
            if queue.lastCollectionURL != nil
            { Button("Show Collected Exports in Finder", action: queue.revealCollection) }
        }
        .padding()
        .navigationTitle("Queue Manager")
    }

    private func row(_ entry: EarthExportQueueEntry) -> some View
    {
        let active = queue.activeID == entry.id
        return HStack(alignment: .top, spacing: 12)
        {
            Toggle("Include \(entry.request.locationTitle), \(entry.request.detail.title)", isOn: Binding(
                get: { entry.isIncluded },
                set: { queue.setIncluded($0, id: entry.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!queue.canEdit || active)
            VStack(alignment: .leading, spacing: 5)
            {
                Text(entry.request.locationTitle).font(.headline)
                Text("\(entry.request.projectTitle) - \(entry.request.detail.title) - \(entry.request.format.rawValue)")
                    .font(.subheadline)
                Text(entry.request.settingsSummary).font(.caption).foregroundStyle(.secondary)
                if let result = entry.result { Text(result.fileName).font(.caption).textSelection(.enabled) }
                if active
                { ProgressView(queue.activeProgress).controlSize(.small) }
                else { Text(entry.phase.title).font(.caption.bold()) }
                if let message = entry.message { EarthErrorMessage(message).font(.caption) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8)
            {
                HStack
                {
                    Button("Move up", systemImage: "arrow.up") { queue.move(entry.id, by: -1) }
                        .disabled(queue.isRunning || queue.entries.first?.id == entry.id)
                    Button("Move down", systemImage: "arrow.down") { queue.move(entry.id, by: 1) }
                        .disabled(queue.isRunning || queue.entries.last?.id == entry.id)
                    Button("Remove", systemImage: "trash") { queue.remove(entry.id) }
                        .disabled(active)
                }
                .labelStyle(.iconOnly)
                if entry.phase == .failed || entry.phase == .cancelled
                { Button("Retry") { queue.retry(entry.id) }.disabled(queue.containsPending(entry.request)) }
                if entry.phase == .complete
                { Button("Show in Finder") { queue.reveal(entry.id) } }
            }
            .disabled(!queue.canEdit)
        }
        .padding(.vertical, 8)
    }
}
