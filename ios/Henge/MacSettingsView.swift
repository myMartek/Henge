import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false
    @AppStorage("henge.cpus") private var cpus = 4

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "Outside the app's limit once JIT is on" : "Used from free storage if needed")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    Stepper("Memory", value: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() }), in: Device.memoryChoices)
                        .font(.system(size: 16))
                    if let note = Device.memoryNote(mac.ramMB / 1024) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                Stepper(value: $cpus, in: 1...6) {
                    HStack {
                        Text("CPUs").font(.system(size: 16))
                        Spacer()
                        Text("\(cpus)").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                #if os(visionOS)
                DeskHeading("Screen")
                if mac.isWindows {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Screen", selection: Binding(get: {
                            WindowsScreen.all.contains { $0.width == mac.screen.width && $0.height == mac.screen.height }
                                ? "\(mac.screen.width)x\(mac.screen.height)" : "\(WindowsScreen.standard.width)x\(WindowsScreen.standard.height)"
                        }, set: { tag in
                            guard let choice = WindowsScreen.all.first(where: { "\($0.width)x\($0.height)" == tag }) else { return }
                            mac.retina = false
                            (mac.screenWidth, mac.screenHeight) = (choice.width, choice.height)
                            save()
                        })) {
                            ForEach(WindowsScreen.all, id: \.title) { choice in
                                Text(choice.title).tag("\(choice.width)x\(choice.height)")
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Windows draws its screen with the emulated processor: a bigger screen is slower and warmer. Changes apply the next time this PC starts.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                    WindowsServiceCard(pc: mac)
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Screen", selection: Binding(get: {
                        VisionScreen.tag(width: mac.screen.width, height: mac.screen.height)
                    }, set: { tag in
                        guard let choice = VisionScreen.choice(tag) else { return }
                        mac.retina = false
                        (mac.screenWidth, mac.screenHeight) = (choice.width, choice.height)
                        save()
                    })) {
                        ForEach(VisionScreen.all, id: \.tag) { choice in
                            Text(choice.title).tag(choice.tag)
                        }
                        if VisionScreen.choice(VisionScreen.tag(width: mac.screen.width, height: mac.screen.height)) == nil {
                            Text("\(mac.screen.width) × \(mac.screen.height)").tag(VisionScreen.tag(width: mac.screen.width, height: mac.screen.height))
                        }
                    }
                    .pickerStyle(.menu)
                    Text("The window takes the shape of the Mac's screen. A bigger screen is more for the Mac to draw, so it runs slower. Changes apply the next time this Mac starts.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                .padding(17)
                .deskCard()
                }
                #endif

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("Screen")
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Screen", selection: Binding(get: {
                            if mac.isRetina { return "retina" }
                            if mac.screen.width == Device.performanceScreen.width,
                               mac.screen.height == Device.performanceScreen.height { return "performance" }
                            if mac.screen.width == 1920, mac.screen.height == 1080 { return "wide" }
                            return "fit"
                        }, set: { choice in
                            mac.retina = choice == "retina"
                            switch choice {
                            case "retina": break
                            case "performance": (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                            case "wide": (mac.screenWidth, mac.screenHeight) = (1920, 1080)
                            default: (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                            }
                            save()
                        })) {
                            if Device.isPad {
                                Text("Retina").tag("retina")
                                Text("Performance").tag("performance")
                            }
                            Text("Fit this \(Device.name)").tag("fit")
                            Text("16:9").tag("wide")
                        }
                        .pickerStyle(.segmented)
                        Text("\(mac.screen.width) × \(mac.screen.height). \(Device.isPad ? "Performance renders about 30% fewer pixels. " : "")Changes apply the next time this Mac starts.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("Storage")
                VStack(spacing: 11) {
                    HStack {
                        Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                }
                .padding(17)
                .deskCard()

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Henge, Exports, \(folder.lastPathComponent). Deleting Henge deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Henge…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this Mac", symbol: nil, tint: Desk.bad) { confirmDelete = true }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
