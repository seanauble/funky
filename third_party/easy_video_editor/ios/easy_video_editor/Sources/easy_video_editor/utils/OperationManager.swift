// Patched locally: the published 0.1.6 source is missing this import, which
// is exactly why DispatchWorkItem/DispatchQueue/UUID/.concurrent/.barrier
// all failed to resolve on a newer Xcode/Swift toolchain (Codemagic's).
// See third_party/easy_video_editor/PATCH_NOTES.md in the Flutter project
// for the full story.
import Foundation

class OperationManager {
    static let shared = OperationManager()
    
    internal var operations: [String: DispatchWorkItem] = [:]
    internal let queue = DispatchQueue(label: "com.easyvideoeditor.operation", attributes: .concurrent)
    
    private init() {}

    /// Generate a unique `operationId`  
    func generateOperationId() -> String {
        return UUID().uuidString
    }

    /// Register a new operation with its ID and work item
    func registerOperation(id: String, workItem: DispatchWorkItem) {
        queue.async(flags: .barrier) {
            self.operations[id] = workItem
        }
    }

    /// Remove a completed operation without canceling it.
    func unregisterOperation(_ id: String) {
        queue.async(flags: .barrier) {
            self.operations.removeValue(forKey: id)
        }
    }

    /// Cancel a specific operation by its ID
    func cancelOperation(_ id: String) {
        queue.async(flags: .barrier) {
            if let workItem = self.operations[id] {
                workItem.cancel()
                self.operations.removeValue(forKey: id)
            }
        }
    }

    /// Cancel all operations
    func cancelAllOperations() {
        queue.async(flags: .barrier) {
            for (_, workItem) in self.operations {
                workItem.cancel()
            }
            self.operations.removeAll()
        }
    }
}
