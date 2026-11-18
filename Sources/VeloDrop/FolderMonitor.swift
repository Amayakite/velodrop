import Darwin
import Foundation

final class FolderMonitor {
    private let source: DispatchSourceFileSystemObject

    init?(_ directory: URL, onChange: @escaping () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                          eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
