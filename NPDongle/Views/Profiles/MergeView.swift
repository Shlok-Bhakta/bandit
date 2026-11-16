import DongleProtocol
import SwiftUI

/// This phone's set next to another (the dongle's, or a file): what each side changed, a pick
/// for every part both changed, and the merged set's verdict before it's taken.
struct MergeView: View {
    @Environment(DongleModel.self) private var model
    @State var request: DongleModel.MergeRequest
    /// Called when merged or cancelled.
    var onFinish: () -> Void

    private var merge: ProfileMerge { request.merge }
    private var fromDongle: Bool { request.dongleHash != nil }
    private var otherName: String { fromDongle ? "Dongle" : "File" }

    var body: some View {
        let result = merge.result
        let problem = result.validate()
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SymbolTile(symbol: "iphone", tint: Theme.accent, size: 40)
                        Image(systemName: "arrow.triangle.merge").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                        SymbolTile(symbol: fromDongle ? "cable.connector" : "doc.fill", tint: Theme.mint, size: 40)
                    }
                    Text(headline).font(.title3.weight(.semibold))
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            let conflicts = indices(.both)
            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.self) { index in conflictRow(index) }
                } header: {
                    Label("Changed on both: pick one", systemImage: "exclamationmark.2").foregroundStyle(Theme.warn)
                }
            }
            let theirs = indices(.other)
            if !theirs.isEmpty {
                Section {
                    ForEach(theirs, id: \.self) { index in toggleRow(index, keep: .other) }
                } header: {
                    Text("Changed on the \(otherName.lowercased())")
                } footer: {
                    Text("Taken unless you switch them off.")
                }
            }
            let mine = indices(.phone)
            if !mine.isEmpty {
                Section {
                    ForEach(mine, id: \.self) { index in toggleRow(index, keep: .phone) }
                } header: {
                    Text("Changed on this iPhone")
                } footer: {
                    Text("Kept unless you switch them off.")
                }
            }
            Section {
                if let problem {
                    Label("The dongle would refuse the merged set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    ProblemText(error: problem)
                    Text("You can merge anyway and fix it in the editor before sending.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("The merged set is valid", systemImage: "checkmark.shield.fill").foregroundStyle(Theme.mint)
                }
                Button {
                    model.applyMerge(request)
                    onFinish()
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                if fromDongle, problem == nil {
                    Button {
                        model.applyMerge(request)
                        model.sendProfiles()
                        onFinish()
                    } label: {
                        Label("Merge and send to the dongle", systemImage: "arrow.up.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.link.isReady || model.uploader.isBusy)
                    .listRowBackground(Color.clear)
                }
            } footer: {
                Text(fromDongle
                     ? "Merging changes only this iPhone's set. What the dongle doesn't have yet shows in the bar, ready to send."
                     : "Merging changes only this iPhone's set. Send it to the dongle when you're happy with it.")
            }
        }
        .darkList()
        .navigationTitle("Merge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { request.merge.pickAll(.phone) } label: { Label("Keep this iPhone's for all", systemImage: "iphone") }
                    Button { request.merge.pickAll(.other) } label: { Label("Take the \(otherName.lowercased())'s for all", systemImage: fromDongle ? "cable.connector" : "doc") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var headline: String {
        if merge.items.isEmpty { return "Nothing differs" }
        if merge.conflicts.isEmpty {
            return merge.items.allSatisfy { $0.change == .other } ? "The \(otherName.lowercased()) has changes" : "No conflicts"
        }
        return merge.conflicts.count == 1 ? "1 conflict" : "\(merge.conflicts.count) conflicts"
    }

    private var explanation: String {
        if fromDongle {
            return merge.base == nil
                ? "This iPhone hasn't seen the dongle's set before, so every difference is yours to pick."
                : "Parts only one side changed since they last matched are merged for you. Pick a side where both changed."
        }
        return "Pick what to take from \(request.source). Everything else stays as this iPhone has it."
    }

    private func indices(_ change: ProfileMerge.Change) -> [Int] {
        merge.items.indices.filter { merge.items[$0].change == change }
    }

    private func conflictRow(_ index: Int) -> some View {
        let item = merge.items[index]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolTile(symbol: ChangeText.symbol(item.part, in: merge.phone, or: merge.other), tint: ChangeText.tint(item.part, in: merge.phone, or: merge.other), size: 28)
                Text(ChangeText.title(item.part, in: merge.phone, or: merge.other)).font(.headline)
            }
            HStack(spacing: 8) {
                choice(index, .phone, title: "iPhone", symbol: "iphone", text: ChangeText.summary(item.part, in: merge.phone))
                choice(index, .other, title: otherName, symbol: fromDongle ? "cable.connector" : "doc", text: ChangeText.summary(item.part, in: merge.other))
            }
            if case .profile(let id) = item.part, let mine = merge.phone.profile(id: id), let theirs = merge.other.profile(id: id) {
                Text("Differs in " + ChangeText.profileChanges(mine, theirs).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choice(_ index: Int, _ side: ProfileMerge.Side, title: String, symbol: String, text: String) -> some View {
        let picked = merge.items[index].pick == side
        return Button {
            withAnimation(.snappy) { request.merge.items[index].pick = side }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(title, systemImage: symbol).font(.caption.weight(.bold))
                    Spacer()
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle").foregroundStyle(picked ? Theme.accent : .secondary)
                }
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background((picked ? Theme.accent : .white).opacity(picked ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: picked)
    }

    private func toggleRow(_ index: Int, keep side: ProfileMerge.Side) -> some View {
        let item = merge.items[index]
        let changedSet = side == .phone ? merge.phone : merge.other
        let otherSet = side == .phone ? merge.other : merge.phone
        return Toggle(isOn: Binding(get: { request.merge.items[index].pick == side },
                                    set: { request.merge.items[index].pick = $0 ? side : (side == .phone ? .other : .phone) })) {
            ChangeRow(part: item.part, phone: changedSet, other: otherSet)
        }
    }
}
