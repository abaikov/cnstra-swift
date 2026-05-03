import Foundation

// MARK: - TS `CNSTaskQueue`

public final class CNSTaskQueue {
    public typealias Completion = () -> Void
    public typealias TaskBody = () -> Completion?

    private struct Item {
        let task: TaskBody
    }

    private var pumping = false
    private var needsPump = false
    private var activeOperations = 0
    private var items: [Item] = []
    private let concurrency: Int?

    public init(concurrency: Int? = nil) {
        self.concurrency = concurrency
    }

    private var canStartOperation: Bool {
        activeOperations < (concurrency ?? Int.max)
    }

    public func enqueue(_ task: @escaping TaskBody) {
        items.append(Item(task: task))
        if !pumping {
            pump()
        } else {
            needsPump = true
        }
    }

    private func pump() {
        if pumping {
            needsPump = true
            return
        }
        pumping = true

        while canStartOperation && !items.isEmpty {
            let item = items.removeFirst()
            activeOperations += 1
            let completion = item.task()
            completion?()
            activeOperations = max(0, activeOperations - 1)
        }

        pumping = false
        if needsPump {
            needsPump = false
            pump()
        }
    }
}
