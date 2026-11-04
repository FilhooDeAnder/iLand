import Foundation
import CoreAudio

struct AudioDev: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

/// Volume, mudo e dispositivo padrão de entrada e saída via CoreAudio (sem driver, sem permissão de captura).
enum CoreAudioSound {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663   // 'vmvc': kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private static func address(_ sel: AudioObjectPropertySelector, input: Bool? = nil) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: input.map { $0 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput } ?? kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = a, v = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult private static func set<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = a, v = value
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(obj, &a, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let id = get(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
        return (id ?? 0) == 0 ? nil : id
    }

    static func setDefaultDevice(_ dev: AudioDeviceID, input: Bool) {
        set(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), dev)
    }

    /// 0...1; nil se o dispositivo não tem volume ajustável (ex.: saída HDMI).
    static func volume(_ dev: AudioDeviceID, input: Bool) -> Float? { get(dev, address(virtualMainVolume, input: input), Float32(0)) }
    static func setVolume(_ dev: AudioDeviceID, input: Bool, _ v: Float) { set(dev, address(virtualMainVolume, input: input), Float32(min(max(v, 0), 1))) }

    static func muted(_ dev: AudioDeviceID, input: Bool) -> Bool? { get(dev, address(kAudioDevicePropertyMute, input: input), UInt32(0)).map { $0 != 0 } }
    static func setMuted(_ dev: AudioDeviceID, input: Bool, _ m: Bool) { set(dev, address(kAudioDevicePropertyMute, input: input), UInt32(m ? 1 : 0)) }

    static func devices(input: Bool) -> [AudioDev] {
        var a = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var s = address(kAudioDevicePropertyStreams, input: input)
            var n = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr, n > 0 else { return nil }
            return AudioDev(id: id, name: name(id) ?? "Dispositivo \(id)")
        }
    }

    static func name(_ dev: AudioDeviceID) -> String? {
        var a = address(kAudioObjectPropertyName), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?   // a propriedade devolve uma referência que o chamador precisa liberar
    }
}

/// Estado da página Som. O relógio de 1 s só roda com a página à vista (fechado = zero custo).
final class SoundModel: ObservableObject {
    @Published private(set) var outVolume: Float?
    @Published private(set) var outMuted = false
    @Published private(set) var inVolume: Float?
    @Published private(set) var inMuted = false
    @Published private(set) var outputs: [AudioDev] = []
    @Published private(set) var outputID: AudioDeviceID?
    @Published private(set) var inputs: [AudioDev] = []
    @Published private(set) var inputID: AudioDeviceID?
    private var timer: Timer?
    private var dragging = false

    var outputName: String { outputs.first { $0.id == outputID }?.name ?? "Saída" }
    var inputName: String { inputs.first { $0.id == inputID }?.name ?? "—" }

    func setActive(_ on: Bool) {
        if on, timer == nil {
            refresh()
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            t.tolerance = 0.3
            timer = t
        } else if !on {
            timer?.invalidate(); timer = nil
        }
    }

    func refresh() {
        guard !dragging else { return }
        outputs = CoreAudioSound.devices(input: false)
        outputID = CoreAudioSound.defaultDevice(input: false)
        if let o = outputID { outVolume = CoreAudioSound.volume(o, input: false); outMuted = CoreAudioSound.muted(o, input: false) ?? false }
        else { outVolume = nil }
        inputs = CoreAudioSound.devices(input: true)
        inputID = CoreAudioSound.defaultDevice(input: true)
        if let i = inputID { inVolume = CoreAudioSound.volume(i, input: true); inMuted = CoreAudioSound.muted(i, input: true) ?? false }
        else { inVolume = nil }
    }

    func editing(_ on: Bool) { dragging = on }

    func setOutVolume(_ v: Float) {
        guard let o = outputID else { return }
        CoreAudioSound.setVolume(o, input: false, v); outVolume = v
        if outMuted, v > 0 { CoreAudioSound.setMuted(o, input: false, false); outMuted = false }
    }
    func toggleOutMute() { guard let o = outputID else { return }; CoreAudioSound.setMuted(o, input: false, !outMuted); outMuted.toggle() }
    func setOutput(_ id: AudioDeviceID) { CoreAudioSound.setDefaultDevice(id, input: false); outputID = id; refresh() }

    func setInput(_ id: AudioDeviceID) { CoreAudioSound.setDefaultDevice(id, input: true); inputID = id; refresh() }

    func setInVolume(_ v: Float) {
        guard let i = CoreAudioSound.defaultDevice(input: true) else { return }
        CoreAudioSound.setVolume(i, input: true, v); inVolume = v
    }
    func toggleInMute() { guard let i = CoreAudioSound.defaultDevice(input: true) else { return }; CoreAudioSound.setMuted(i, input: true, !inMuted); inMuted.toggle() }
}
