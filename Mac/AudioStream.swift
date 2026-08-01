import Foundation
import CoreMedia
import AVFoundation

/// Packs ScreenCaptureKit audio sample buffers into wire `AUD1` frames
/// (PCM s16le mono @ 48 kHz) for the Android receiver.
///
/// Wire payload (after the 4-byte length prefix):
/// ```
/// "AUD1" | u8 ver=1 | u8 channels=1 | u16be sampleRate | u32be frameCount | s16le PCM
/// ```
enum AudioWire {
    static let magic = Data([0x41, 0x55, 0x44, 0x31]) // "AUD1"
    static let version: UInt8 = 1
    static let channels: UInt8 = 1
    static let sampleRate: UInt16 = 48_000

    static func pack(pcmS16Mono: [Int16]) -> Data {
        var out = Data()
        out.reserveCapacity(12 + pcmS16Mono.count * 2)
        out.append(magic)
        out.append(version)
        out.append(channels)
        var sr = sampleRate.bigEndian
        out.append(Data(bytes: &sr, count: 2))
        var n = UInt32(pcmS16Mono.count).bigEndian
        out.append(Data(bytes: &n, count: 4))
        pcmS16Mono.withUnsafeBufferPointer { buf in
            out.append(Data(buffer: buf))
        }
        return out
    }
}

/// Converts SCK audio CMSampleBuffers → mono s16le @ 48 kHz.
final class AudioResampler {
    private var converter: AVAudioConverter?
    private var lastInKey: String = ""
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    )!

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Int16] {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return []
        }
        var asbd = asbdPtr.pointee
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let inFmt = AVAudioFormat(streamDescription: &asbd) else { return [] }

        let key = "\(asbd.mSampleRate)-\(asbd.mChannelsPerFrame)-\(asbd.mFormatID)-\(asbd.mBitsPerChannel)"
        if key != lastInKey {
            lastInKey = key
            converter = AVAudioConverter(from: inFmt, to: outFormat)
            if converter == nil {
                Log.info("audio: no converter for \(key)")
            }
        }
        guard let converter else { return [] }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let input = copyToPCMBuffer(sampleBuffer, format: inFmt, frames: frames) else {
            return []
        }

        let ratio = outFormat.sampleRate / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
            return []
        }

        var error: NSError?
        var provided = false
        let block: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        converter.convert(to: output, error: &error, withInputFrom: block)
        if let error {
            Log.info("audio convert: \(error.localizedDescription)")
            return []
        }
        let n = Int(output.frameLength)
        guard n > 0, let ptr = output.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: n))
    }

    private func copyToPCMBuffer(_ sampleBuffer: CMSampleBuffer,
                                 format: AVAudioFormat,
                                 frames: CMItemCount) -> AVAudioPCMBuffer? {
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard st == noErr else { return nil }
        // Keep blockBuffer alive across the copy (holds the ABL memory).
        _ = blockBuffer
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frames)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            if format.isInterleaved {
                if let dst = pcm.floatChannelData?[0], let src = abl.first?.mData {
                    memcpy(dst, src, Int(abl.first?.mDataByteSize ?? 0))
                }
            } else {
                for ch in 0..<min(Int(format.channelCount), abl.count) {
                    if let dst = pcm.floatChannelData?[ch], let src = abl[ch].mData {
                        memcpy(dst, src, Int(abl[ch].mDataByteSize))
                    }
                }
            }
        case .pcmFormatInt16:
            if let dst = pcm.int16ChannelData?[0], let src = abl.first?.mData {
                memcpy(dst, src, Int(abl.first?.mDataByteSize ?? 0))
            }
        default:
            return nil
        }
        return pcm
    }
}
