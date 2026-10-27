import Foundation
import ZCore

/// What an installer ISO is built for, so the UI can warn before booting an image that cannot work
/// (an x86_64 ISO on Apple silicon, a BIOS-only ISO: Virtualization.framework boots UEFI only).
///
/// Heuristic (UNVERIFIED for every distribution): UEFI loaders in `/EFI/BOOT/` (BOOTAA64.EFI / BOOTX64.EFI),
/// the same names inside the El Torito EFI system image, then words like "arm64"/"amd64" in the volume label
/// or file name.
public struct ISOInspection: Sendable, Hashable {
    public var volumeIdentifier: String
    /// Architectures with a UEFI loader on the image.
    public var efiArchitectures: Set<GuestArchitecture>
    /// The image has an El Torito UEFI boot entry.
    public var hasElToritoEFI: Bool
    /// The image has an El Torito BIOS boot entry.
    public var hasElToritoBIOS: Bool
    /// Best guess for the image's architecture (nil = unknown).
    public var architecture: GuestArchitecture?
    /// How the guess was made (shown in the UI / logs).
    public var evidence: [String]

    public var isUEFIBootable: Bool { !efiArchitectures.isEmpty || hasElToritoEFI }

    /// A user-facing warning when the image will probably not boot on `host`, else nil.
    public func warning(host: GuestArchitecture = .host) -> String? {
        if let arch = architecture, arch != host, !efiArchitectures.contains(host) {
            if host == .arm64 {
                return "This looks like an \(arch.rawValue) (Intel) image. Macs with Apple silicon can only boot arm64 (aarch64) Linux; download the ARM64 version of this distribution."
            }
            return "This looks like an \(arch.rawValue) image, but this Mac needs x86_64 (amd64) guests."
        }
        if !isUEFIBootable && architecture == nil {
            return "No UEFI boot loader was found on this image. Virtualization.framework boots UEFI images only (no legacy BIOS)."
        }
        return nil
    }
}

public enum ISOInspector {
    /// Inspects an ISO file. Reads only the volume descriptors, a few directories and the EFI boot image.
    public static func inspect(url: URL) throws -> ISOInspection {
        try inspect(source: FileSource(url: url), fileName: url.lastPathComponent)
    }

    public static func inspect(source: any RandomAccessSource, fileName: String = "") throws -> ISOInspection {
        let reader = try ISO9660Reader(source: source)
        var result = ISOInspection(volumeIdentifier: reader.jolietVolumeIdentifier ?? reader.primaryVolumeIdentifier,
                                   efiArchitectures: [], hasElToritoEFI: false, hasElToritoBIOS: false,
                                   architecture: nil, evidence: [])

        // 1. /EFI/BOOT/BOOT*.EFI in either directory tree.
        for joliet in [true, false] {
            guard let entries = try? reader.list("EFI/BOOT", joliet: joliet) else { continue }
            for e in entries where !e.isDirectory {
                if let arch = loaderArchitecture(fileName: e.name) {
                    if result.efiArchitectures.insert(arch).inserted {
                        result.evidence.append("/EFI/BOOT/\(e.name)")
                    }
                }
            }
        }

        // 2. El Torito: BIOS / EFI entries, and the loader names inside the EFI FAT image.
        if let boot = try? reader.bootEntries() {
            for b in boot {
                if b.isEFI {
                    result.hasElToritoEFI = true
                    let declared = Int(b.sectorCount) * 512
                    let length = declared > 4096 ? min(declared, 64 << 20) : 32 << 20
                    if let image = try? source.read(at: UInt64(b.loadSector) * 2048, count: length) {
                        for arch in fatLoaderArchitectures(in: image) {
                            if result.efiArchitectures.insert(arch).inserted {
                                result.evidence.append("El Torito EFI image contains the \(arch.rawValue) loader")
                            }
                        }
                    }
                } else {
                    result.hasElToritoBIOS = true
                }
            }
        }

        // 3. Decide.
        if result.efiArchitectures.count == 1, let only = result.efiArchitectures.first {
            result.architecture = only
        } else if result.efiArchitectures.count > 1 {
            let host = GuestArchitecture.host
            result.architecture = result.efiArchitectures.contains(host) ? host : result.efiArchitectures.first
            result.evidence.append("multi-architecture image")
        } else if let hinted = nameHint(result.volumeIdentifier) ?? nameHint(reader.primaryVolumeIdentifier) ?? nameHint(fileName) {
            result.architecture = hinted
            result.evidence.append("name hint: \(hinted.rawValue)")
        }
        return result
    }

    /// Architecture of a UEFI removable-media loader name (BOOTAA64.EFI, BOOTX64.EFI).
    public static func loaderArchitecture(fileName: String) -> GuestArchitecture? {
        switch fileName.uppercased() {
        case "BOOTAA64.EFI": return .arm64
        case "BOOTX64.EFI": return .x86_64
        default: return nil
        }
    }

    /// Loader names as FAT 8.3 directory entries inside an EFI system image.
    public static func fatLoaderArchitectures(in data: Data) -> Set<GuestArchitecture> {
        var found = Set<GuestArchitecture>()
        if data.range(of: Data("BOOTAA64EFI".utf8)) != nil { found.insert(.arm64) }
        if data.range(of: Data("BOOTX64 EFI".utf8)) != nil { found.insert(.x86_64) }
        return found
    }

    /// "arm64"/"aarch64" → arm64, "amd64"/"x86_64"/"x64" → x86_64 in a label or file name.
    public static func nameHint(_ text: String) -> GuestArchitecture? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains("arm64") || t.contains("aarch64") { return .arm64 }
        if t.contains("amd64") || t.contains("x86_64") || t.contains("x86-64") || t.contains("x64") || t.contains("i386") || t.contains("i686") {
            return .x86_64
        }
        return nil
    }
}
