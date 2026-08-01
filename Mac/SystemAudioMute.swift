import AudioToolbox
import CoreAudio
import Foundation

/// Silences the Mac’s default output while system audio is streamed to a
/// tablet, so sound isn’t doubled on local speakers + device.
///
/// Reference-counted: each streaming session that plays audio on the tablet
/// takes a claim; output is silenced while claims > 0 and restored when the
/// last claim drops.
///
/// MacBooks often ignore or half-apply `kAudioDevicePropertyMute`, so we
/// primarily lower **volume to 0** and restore the previous scalar. Mute is
/// attempted as a secondary control when settable.
enum SystemAudioMute {
    private static let lock = NSLock()
    private static var claims = 0
    /// true once we have applied silence and own a restore snapshot.
    private static var holding = false
    private static var mutedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private static var savedMute: UInt32?
    private static var savedVolume: Float32?
    private static var volumeWasSettable = false

    /// Begin exclusive tablet audio for one session.
    static func claim() {
        lock.lock()
        defer { lock.unlock() }
        claims += 1
        if claims == 1 {
            applySilence()
        }
    }

    /// End exclusive tablet audio for one session.
    static func release() {
        lock.lock()
        defer { lock.unlock() }
        guard claims > 0 else { return }
        claims -= 1
        if claims == 0 {
            restoreOutput()
        }
    }

    /// Drop every claim and restore speakers (audio routing flipped to Mac,
    /// or emergency cleanup). Safe if nothing was claimed.
    static func forceReleaseAll() {
        lock.lock()
        defer { lock.unlock() }
        claims = 0
        restoreOutput()
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            Log.info("SystemAudioMute: no default output device (err=\(err))")
            return nil
        }
        return deviceID
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Master / virtual volume (works on built-in MacBook speakers).
    /// Prefer the current SDK name; fall back to the classic four-char code.
    private static func volumeAddress() -> AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector = {
            // macOS 14+ renamed VirtualMasterVolume → VirtualMainVolume.
            if #available(macOS 14.0, *) {
                return kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            }
            // 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMasterVolume
            return AudioObjectPropertySelector(UInt32(bigEndian: 0x766D7663))
        }()
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readMute(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }

    private static func writeMute(_ deviceID: AudioDeviceID, _ value: UInt32) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, !settable.boolValue {
            return false
        }
        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &v) == noErr
    }

    private static func readVolume(_ deviceID: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }

    private static func writeVolume(_ deviceID: AudioDeviceID, _ value: Float32) -> Bool {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, !settable.boolValue {
            return false
        }
        var v = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &v) == noErr
    }

    private static func applySilence() {
        guard let deviceID = defaultOutputDeviceID() else { return }
        mutedDeviceID = deviceID
        savedMute = readMute(deviceID)
        savedVolume = readVolume(deviceID)
        holding = true

        var didSomething = false

        // Prefer volume → 0 (reliable on MacBook built-in).
        if let vol = savedVolume {
            volumeWasSettable = writeVolume(deviceID, 0)
            if volumeWasSettable {
                didSomething = true
                Log.info("SystemAudioMute: volume \(String(format: "%.2f", vol)) → 0 (tablet audio)")
            }
        } else {
            volumeWasSettable = false
        }

        // Also mute when supported (some external devices).
        if savedMute == 0, writeMute(deviceID, 1) {
            didSomething = true
            Log.info("SystemAudioMute: muted default output (tablet audio)")
        }

        if !didSomething {
            Log.info("SystemAudioMute: could not silence default output — dual audio may remain")
            // Nothing applied — clear snapshot so restore is a no-op.
            holding = false
            savedMute = nil
            savedVolume = nil
            mutedDeviceID = kAudioObjectUnknown
        }
    }

    private static func restoreOutput() {
        defer {
            holding = false
            savedMute = nil
            savedVolume = nil
            volumeWasSettable = false
            mutedDeviceID = kAudioObjectUnknown
        }
        guard holding else { return }

        let deviceID: AudioDeviceID = {
            if mutedDeviceID != kAudioObjectUnknown { return mutedDeviceID }
            return defaultOutputDeviceID() ?? kAudioObjectUnknown
        }()
        guard deviceID != kAudioObjectUnknown else { return }

        // Always clear mute first so volume restore is audible.
        if writeMute(deviceID, 0) {
            Log.info("SystemAudioMute: unmute default output")
        }

        if volumeWasSettable, let vol = savedVolume {
            // Never restore a zero volume if we forced silence ourselves from
            // a non-zero level — that would leave the Mac silent.
            let restore = vol > 0.001 ? vol : 0.5
            if writeVolume(deviceID, restore) {
                Log.info("SystemAudioMute: restored volume to \(String(format: "%.2f", restore))")
            } else {
                Log.info("SystemAudioMute: volume restore failed")
            }
        } else if let vol = savedVolume, vol > 0.001 {
            // Volume was readable but we may not have zeroed it — try restore anyway.
            _ = writeVolume(deviceID, vol)
        } else {
            // No snapshot: force a usable level so “Play on Mac” is never silent.
            if writeVolume(deviceID, 0.5) {
                Log.info("SystemAudioMute: no snapshot — set volume to 0.5")
            }
        }
    }
}
