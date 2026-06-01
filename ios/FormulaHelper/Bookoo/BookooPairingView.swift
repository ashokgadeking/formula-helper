import SwiftUI

struct BookooPairingView: View {
    @ObservedObject private var manager = BookooManager.shared
    @State private var renameID: UUID?
    @State private var renameDraft = ""
    @State private var showCalibration = false

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            List {
                pairedSection
                if manager.isScanning {
                    discoverySection
                }
                actionsSection
                calibrationSection
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
        .sheet(isPresented: $showCalibration) {
            BookooCalibrationSheet()
        }
    }

    // MARK: - Calibration (global, shared across scales)

    @ViewBuilder
    private var calibrationSection: some View {
        Section {
            Button {
                showCalibration = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: manager.dryBottleWeight != nil ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 18))
                        .foregroundColor(manager.dryBottleWeight != nil ? .green : .orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bottle calibration")
                            .appFont(.body)
                            .foregroundColor(Color.primaryLabel)
                        if let dry = manager.dryBottleWeight {
                            Text("Empty bottle: \(String(format: "%.1f", dry)) g")
                                .appFont(.footnote)
                                .foregroundColor(Color.secondaryLabel)
                        } else {
                            Text("Not calibrated — using formula ratio")
                                .appFont(.footnote)
                                .foregroundColor(Color.secondaryLabel)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.tertiaryLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text("Calibration").foregroundColor(Color.secondaryLabel)
        } footer: {
            Text("One empty-bottle weight used for every scale. When set, water volume is measured directly from the scale instead of derived from the formula ratio.")
                .appFont(.footnote)
                .foregroundColor(Color.secondaryLabel)
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
                    Button {
                        renameDraft = scale.name
                        renameID = scale.id
                    } label: {
                        pairedRow(scale)
                    }
                    .buttonStyle(.plain)
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
            Text("Tap a scale to rename it. Bottles you mix on these scales auto-log to AvantiLog.")
                .appFont(.footnote)
                .foregroundColor(Color.secondaryLabel)
        }
    }

    private func pairedRow(_ scale: PairedScale) -> some View {
        let connected = manager.connectedIDs.contains(scale.id)
        return HStack(spacing: 12) {
            Image(systemName: "scalemass.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(scale.name)
                    .appFont(.body)
                    .foregroundColor(Color.primaryLabel)
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? Color.green : Color.secondaryLabel)
                        .frame(width: 7, height: 7)
                    Text(connected ? "Connected" : "Disconnected")
                    if connected, let pct = scale.lastBatteryPct {
                        Text("·")
                        Text("\(pct)% battery")
                    }
                }
                .appFont(.footnote)
                .foregroundColor(connected ? Color.green : Color.secondaryLabel)

                if connected, let dbg = manager.debugInfo[scale.id] {
                    HStack(spacing: 10) {
                        Text("Powder \(String(format: "%.1f", dbg.powderPeakG))g")
                        Text("Water \(dbg.liveWaterG.map { String(format: "%.1f", $0) + "g" } ?? "—")")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.blue)
                }
            }
            Spacer()
            Image(systemName: "pencil")
                .font(.system(size: 13))
                .foregroundColor(Color.tertiaryLabel)
        }
        .contentShape(Rectangle())
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

// MARK: - Calibration sheet

struct BookooCalibrationSheet: View {
    @ObservedObject private var manager = BookooManager.shared
    @Environment(\.dismiss) private var dismiss

    private var liveWeight: Double? { manager.liveWeightAnyScale }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Bottle calibration")
                        .appFont(.title3)
                        .foregroundColor(Color.primaryLabel)

                    Text("Power on a scale empty (it tares to 0). Then place your empty, dry bottle on it and tap Capture. This one weight is used for every scale.")
                        .appFont(.body)
                        .foregroundColor(Color.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    VStack(spacing: 6) {
                        Text("Live reading")
                            .appFont(.footnote)
                            .foregroundColor(Color.tertiaryLabel)
                        if let w = liveWeight {
                            Text("\(String(format: "%.1f", w)) g")
                                .font(.outfit(48, weight: .bold))
                                .foregroundColor(Color.green)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .font(.outfit(48, weight: .bold))
                                .foregroundColor(Color.tertiaryLabel)
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    if let dry = manager.dryBottleWeight {
                        Text("Currently saved: \(String(format: "%.1f", dry)) g")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }

                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            manager.setDryBottleWeight(nil)
                            dismiss()
                        } label: {
                            Text("Clear")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            if let w = liveWeight, w > 0.5 {
                                manager.setDryBottleWeight(w)
                                dismiss()
                            }
                        } label: {
                            Text("Capture")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((liveWeight ?? 0) <= 0.5)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
                .padding(.top, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
