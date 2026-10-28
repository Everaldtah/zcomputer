import SwiftUI
import ZCore
import ZVM

/// First run: no real machine yet. Offers the Image Library (or the recommended machine in one click); the Demo
/// machine stays available.
struct AgentOnboardingCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("onboarding.machineCardDismissed") private var dismissed = false

    var body: some View {
        let machines = model.machines
        if machines.isSupported, machines.specs.isEmpty, !dismissed {
            let library = model.imageLibrary
            let recommended = library.cloudTemplates.first { $0.recommended }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get a machine for your agents").font(.headline)
                    Text(detail(recommended, library: library))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open the Image Library") {
                            model.machines.tab = .library
                            model.selection = .machines
                        }
                        .buttonStyle(.borderedProminent)
                        if let recommended, library.fit(recommended).canCreate {
                            Button("Get \(recommended.name)") {
                                library.getAndBoot(recommended)
                                model.selection = .machines
                            }
                        }
                        Button("Keep using the Demo machine") { dismissed = true }
                            .buttonStyle(.borderless)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private func detail(_ template: MachineTemplate?, library: ImageLibraryModel) -> String {
        var text = "The Demo machine only simulates a desktop. The Image Library downloads a real Linux machine, "
            + "checks its checksum, and boots it with the guest agent installed."
        if let template, let image = library.image(for: template) {
            text += " Recommended: \(template.name), a \(Format.bytes(image.sizeBytes)) download. \(template.firstBoot)"
        }
        return text
    }
}
