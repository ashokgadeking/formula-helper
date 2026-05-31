import SwiftUI

struct BookooPairingView: View {
    @ObservedObject private var manager = BookooManager.shared
    @State private var renameID: UUID?
    @State private var renameDraft = ""

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            List {
                pairedSection
                if manager.isScanning {
                    discoverySection
                }
                actionsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Bookoo Scales")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.primaryBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Rename scale", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let id = renameID {
                    manager.rename(id: id, to: renameDraft.isEmpty ? "Bookoo" : renameDraft)
                }
                renameID = nil
            }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
    }

    // MARK: - Paired

    @ViewBuilder
    private var pairedSection: some View {
        Section {
            if manager.pairedScales.isEmpty {
                Text("No scales paired yet.")
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
                    .listRowBackground(Color.elevatedBackground)
            } else {
                ForEach(manager.pairedScales) { scale in
                    pairedRow(scale)
                        .listRowBackground(Color.elevatedBackground)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.unpair(id: scale.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button {
                                renameDraft = scale.name
                                renameID = scale.id
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        } header: {
            Text("Paired").foregroundColor(Color.secondaryLabel)
        } footer: {
            Text("Bottles you mix on these scales auto-log to AvantiLog.")
                .appFont(.footnote)
                .foregroundColor(Color.secondaryLabel)
        }
    }

    private func pairedRow(_ scale: PairedScale) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scalemass.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(scale.name)
                    .appFont(.body)
                    .foregroundColor(Color.primaryLabel)
                if let last = scale.lastSeenAt {
                    HStack(spacing: 6) {
                        if let pct = scale.lastBatteryPct {
                            Text("\(pct)% battery")
                        }
                        Text("·")
                        Text("Seen \(last, style: .relative) ago")
                    }
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
                } else {
                    Text("Not yet seen")
                        .appFont(.footnote)
                        .foregroundColor(Color.secondaryLabel)
                }
            }
            Spacer()
        }
    }

    // MARK: - Discovery

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if manager.discovered.isEmpty {
                HStack {
                    ProgressView().tint(Color.secondaryLabel)
                    Text("Power on the scale you want to pair…")
                        .appFont(.footnote)
                        .foregroundColor(Color.secondaryLabel)
                }
                .listRowBackground(Color.elevatedBackground)
            } else {
                ForEach(manager.discovered) { d in
                    Button {
                        let defaultName = "Bookoo \(manager.pairedScales.count + 1)"
                        manager.pair(d, named: defaultName)
                        manager.stopDiscoveryScan()
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                            Text(d.name)
                                .appFont(.body)
                                .foregroundColor(Color.primaryLabel)
                            Spacer()
                            Text("\(d.rssi) dBm")
                                .appFont(.footnote)
                                .foregroundColor(Color.secondaryLabel)
                        }
                    }
                    .listRowBackground(Color.elevatedBackground)
                }
            }
        } header: {
            Text("Discovered").foregroundColor(Color.secondaryLabel)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                if manager.isScanning {
                    manager.stopDiscoveryScan()
                } else {
                    manager.startDiscoveryScan()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: manager.isScanning ? "stop.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(manager.isScanning ? .red : .green)
                    Text(manager.isScanning ? "Stop scan" : "Add scale")
                        .appFont(.body)
                        .foregroundColor(Color.primaryLabel)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(Color.elevatedBackground)
        }
    }
}
