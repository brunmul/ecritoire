import CoreServices
import Foundation

/// Surveille récursivement un dossier avec FSEvents et appelle `onChange` (sur la file principale)
/// avec les chemins modifiés, regroupés sur une courte fenêtre.
public final class FileWatcher {
    public let root: URL
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 0.2, onChange: @escaping ([String]) -> Void) {
        self.root = root
        self.onChange = onChange
        start(latency: latency)
    }

    deinit { stop() }

    private func start(latency: TimeInterval) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { array[$0] as? String }
            watcher.onChange(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
