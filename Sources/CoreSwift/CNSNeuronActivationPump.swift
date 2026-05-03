import Foundation

// MARK: - TS `CNSNeuronActivationPump`

public final class CNSNeuronActivationPump {
    public typealias Processor = (_ task: CNSNeuronActivationTask) -> (() -> Void)?

    private var items: [CNSNeuronActivationTask] = []
    private var activeTasks: [CNSNeuronActivationTask] = []
    private var activeOperations = 0
    private var pumping = false
    private var needsPump = false

    private let processor: Processor
    private let concurrency: Int?
    private weak var abortSignal: CNSAbortSignal?

    public init(
        processor: @escaping Processor,
        concurrency: Int? = nil,
        abortSignal: CNSAbortSignal? = nil
    ) {
        self.processor = processor
        self.concurrency = concurrency
        self.abortSignal = abortSignal
    }

    private var canStartOperation: Bool {
        activeOperations < (concurrency ?? Int.max) && abortSignal?.isAborted != true
    }

    public func enqueue(_ task: CNSNeuronActivationTask) {
        items.append(task)
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
            let task = items.removeFirst()
            activeOperations += 1
            activeTasks.append(task)
            let completion = processor(task)
            activeOperations = max(0, activeOperations - 1)
            activeTasks.removeAll { $0 === task }
            completion?()
        }

        pumping = false
        if needsPump {
            needsPump = false
            pump()
        }
    }

    public var length: Int {
        items.count
    }

    public func getActiveOperationsCount() -> Int {
        activeOperations
    }

    public func getQueuedTasks() -> [CNSNeuronActivationTask] {
        items
    }

    public func getActiveTasks() -> [CNSNeuronActivationTask] {
        activeTasks
    }
}
