import Foundation

// MARK: - Signals

public struct CNSSignal<Payload> {
    public let collateral: CNSCollateral<Payload>
    public let payload: Payload?

    public init(collateral: CNSCollateral<Payload>, payload: Payload? = nil) {
        self.collateral = collateral
        self.payload = payload
    }
}

protocol CNSAnySignalProtocol {
    var collateralObject: AnyObject { get }
    var payloadAny: Any? { get }
}

extension CNSSignal: CNSAnySignalProtocol {
    var collateralObject: AnyObject { collateral }
    var payloadAny: Any? { payload }
}

// MARK: - Collateral

public protocol ICNSCollateral {
    associatedtype Payload
    func createSignal(_ payload: Payload?) -> CNSSignal<Payload>
}

public final class CNSCollateral<Payload>: ICNSCollateral {
    public init() {}
    public func createSignal(_ payload: Payload? = nil) -> CNSSignal<Payload> {
        CNSSignal(collateral: self, payload: payload)
    }
}

// MARK: - Axon

public final class CNSAxon {
    private var collateralObjects: [AnyObject]

    public init(_ collaterals: AnyObject...) {
        self.collateralObjects = collaterals
    }

    public init(collaterals: [AnyObject]) {
        self.collateralObjects = collaterals
    }

    public func register<T>(_ collateral: CNSCollateral<T>) {
        guard !collateralObjects.contains(where: { $0 === collateral }) else { return }
        collateralObjects.append(collateral)
    }

    public func contains(_ collateral: AnyObject) -> Bool {
        collateralObjects.contains { $0 === collateral }
    }

    func collateralInstances() -> [AnyObject] {
        collateralObjects
    }
}

// MARK: - Abort / cancellation

public protocol CNSAbortSignal: AnyObject {
    var isAborted: Bool { get }
}

public final class CNSCancellationToken: CNSAbortSignal {
    private var cancelled: Bool = false
    public init() {}
    public func cancel() { cancelled = true }
    public var isCancelled: Bool { cancelled }
    public var isAborted: Bool { cancelled }

    public static func fromTask() -> CNSCancellationToken {
        let t = CNSCancellationToken()
        if Task.isCancelled { t.cancel() }
        return t
    }
}

// MARK: - Scheduling (optional; global stimulation scheduler was removed from TS `TCNSOptions`)

public protocol CNSScheduler {
    func perform(_ work: @escaping () -> Void)
}

public final class CNSSyncScheduler: CNSScheduler {
    public init() {}
    public func perform(_ work: @escaping () -> Void) { work() }
}

public final class CNSAsyncScheduler: CNSScheduler {
    private let queue: DispatchQueue
    public init(qos: DispatchQoS = .userInitiated, label: String = "cnstra.scheduler.async") {
        self.queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
    }
    public func perform(_ work: @escaping () -> Void) { queue.async(execute: work) }
}

// MARK: - Stimulation context store (TS `ICNSStimulationContextStore`; class instances as keys)

public protocol CNSStimulationContextStoreProtocol: AnyObject {
    func get(key: AnyObject) -> Any?
    func set(key: AnyObject, value: Any?)
    func delete(key: AnyObject)
    /// Snapshot of context entries (Swift uses `ObjectIdentifier` instead of JS `Map<object, …>` keys).
    func getAll() -> [ObjectIdentifier: Any]
    func setAll(_ snapshot: [ObjectIdentifier: Any])
}

public final class CNSStimulationContextStore: CNSStimulationContextStoreProtocol {
    private var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public func get(key: AnyObject) -> Any? {
        storage[ObjectIdentifier(key)]
    }

    public func set(key: AnyObject, value: Any?) {
        if let value {
            storage[ObjectIdentifier(key)] = value
        } else {
            storage.removeValue(forKey: ObjectIdentifier(key))
        }
    }

    public func delete(key: AnyObject) {
        storage.removeValue(forKey: ObjectIdentifier(key))
    }

    public func getAll() -> [ObjectIdentifier: Any] {
        storage
    }

    public func setAll(_ snapshot: [ObjectIdentifier: Any]) {
        storage = snapshot
    }
}

// MARK: - Local dendrite context

public final class CNSLocalCtx {
    public let get: () -> Any?
    public let set: (Any?) -> Void
    public let delete: () -> Void
    public let abortSignal: CNSAbortSignal?
    public weak var cns: CNS?
    public weak var stimulation: CNSStimulation?

    public init(
        get: @escaping () -> Any?,
        set: @escaping (Any?) -> Void,
        delete: @escaping () -> Void,
        abortSignal: CNSAbortSignal?,
        cns: CNS,
        stimulation: CNSStimulation?
    ) {
        self.get = get
        self.set = set
        self.delete = delete
        self.abortSignal = abortSignal
        self.cns = cns
        self.stimulation = stimulation
    }
}

public struct CNSContextKey<T> { public init() {} }

public extension CNSLocalCtx {
    func get<T>(_ key: CNSContextKey<T>) -> T? { get() as? T }
    func set<T>(_ key: CNSContextKey<T>, _ value: T?) { set(value) }
}

public typealias CNSDendriteResponse = (_ payload: Any?, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?

public enum CNSEventual {
    case immediate(Any?)
    case future((_ complete: @escaping (Any?) -> Void) -> Void)
}

public typealias CNSTypedDendriteResponse<Input> = (_ payload: Input?, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?

// MARK: - Modality / afferent path (TS parity)

public final class CNSAfferentPath: Hashable, @unchecked Sendable {
    public let parentAfferentPath: CNSAfferentPath?

    public init(parentAfferentPath: CNSAfferentPath? = nil) {
        self.parentAfferentPath = parentAfferentPath
    }

    public static func == (lhs: CNSAfferentPath, rhs: CNSAfferentPath) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public final class CNSModality: Hashable, @unchecked Sendable {
    public var afferentPaths: [AnyHashable: CNSAfferentPath]

    public init(afferentPaths: [AnyHashable: CNSAfferentPath] = [:]) {
        self.afferentPaths = afferentPaths
    }

    public static func == (lhs: CNSModality, rhs: CNSModality) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - Dendrite

public struct CNSDendrite {
    public let inputCollateral: AnyObject
    public let response: CNSDendriteResponse

    func matchesInputCollateral(_ obj: AnyObject) -> Bool {
        ObjectIdentifier(obj) == ObjectIdentifier(inputCollateral)
    }

    public init(inputCollateral: AnyObject, response: @escaping CNSDendriteResponse) {
        self.inputCollateral = inputCollateral
        self.response = response
    }

    public init<Input>(inputCollateral: CNSCollateral<Input>, typedResponse: @escaping CNSTypedDendriteResponse<Input>) {
        self.inputCollateral = inputCollateral
        self.response = { payload, axon, ctx in
            guard let typedPayload = payload as? Input else { return nil }
            return typedResponse(typedPayload, axon, ctx)
        }
    }

    public init<Input>(inputCollateral: CNSCollateral<Input>, strictResponse: @escaping (_ payload: Input, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?) {
        self.inputCollateral = inputCollateral
        self.response = { payload, axon, ctx in
            if Input.self == Void.self {
                return strictResponse(() as! Input, axon, ctx)
            }
            guard let p = payload as? Input else { return nil }
            return strictResponse(p, axon, ctx)
        }
    }

    public init<Input, E: Error>(inputCollateral: CNSCollateral<Input>, errorCollateral: CNSCollateral<E>, throwingResponse: @escaping (_ payload: Input, _ axon: CNSAxon, _ ctx: CNSLocalCtx) throws -> Any?) {
        self.inputCollateral = inputCollateral
        self.response = { payload, axon, ctx in
            do {
                if Input.self == Void.self {
                    return try throwingResponse(() as! Input, axon, ctx)
                }
                guard let p = payload as? Input else { return nil }
                return try throwingResponse(p, axon, ctx)
            } catch let e as E {
                return errorCollateral.createSignal(e)
            } catch {
                return nil
            }
        }
    }

}

// MARK: - Neuron

public final class CNSNeuron: Hashable {
    public let axon: CNSAxon
    public let dendrites: [CNSDendrite]
    public var concurrency: Int?
    /// Mirrors TS `maxDuration` metadata. Swift cannot safely terminate arbitrary synchronous closures.
    public var maxDurationMillis: Int?

    public init(axon: CNSAxon, dendrites: [CNSDendrite], concurrency: Int? = nil, maxDurationMillis: Int? = nil) {
        self.axon = axon
        self.dendrites = dendrites
        self.concurrency = concurrency
        self.maxDurationMillis = maxDurationMillis
    }

    public static func == (lhs: CNSNeuron, rhs: CNSNeuron) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - Responses

public struct CNSResponse<TIn, TOut> {
    public let inputSignal: CNSSignal<TIn>?
    public let outputSignal: CNSSignal<TOut>?
    public let error: Error?
    public let queueLength: Int
    public let modality: CNSModality?
    public let afferentPath: CNSAfferentPath?
    /// TS `contextValue` — snapshot of stimulation context store (object keys → `ObjectIdentifier` in Swift).
    public let contextValue: [ObjectIdentifier: Any]
    public let hops: Int?
    public let stimulation: CNSStimulation?

    public init(
        inputSignal: CNSSignal<TIn>?,
        outputSignal: CNSSignal<TOut>?,
        error: Error?,
        queueLength: Int,
        modality: CNSModality? = nil,
        afferentPath: CNSAfferentPath? = nil,
        contextValue: [ObjectIdentifier: Any] = [:],
        hops: Int? = nil,
        stimulation: CNSStimulation? = nil
    ) {
        self.inputSignal = inputSignal
        self.outputSignal = outputSignal
        self.error = error
        self.queueLength = queueLength
        self.modality = modality
        self.afferentPath = afferentPath
        self.contextValue = contextValue
        self.hops = hops
        self.stimulation = stimulation
    }
}

public struct CNSStimulationOptions<TIn, TOut> {
    public var onResponse: ((_ response: CNSResponse<TIn, TOut>) -> Void)?
    public var abortSignal: CNSAbortSignal?
    public var maxNeuronHops: Int?
    public var concurrency: Int?
    public var ctx: CNSStimulationContextStoreProtocol?
    public var modality: CNSModality?
    public var afferentPath: CNSAfferentPath?
    public var stimulationContext: Any?
    /// Dispatches async `CNSEventual.future` completions; defaults to a global queue.
    public var continuationScheduler: CNSScheduler?

    public init(
        onResponse: ((_ response: CNSResponse<TIn, TOut>) -> Void)? = nil,
        abortSignal: CNSAbortSignal? = nil,
        maxNeuronHops: Int? = nil,
        concurrency: Int? = nil,
        ctx: CNSStimulationContextStoreProtocol? = nil,
        modality: CNSModality? = nil,
        afferentPath: CNSAfferentPath? = nil,
        stimulationContext: Any? = nil,
        continuationScheduler: CNSScheduler? = nil
    ) {
        self.onResponse = onResponse
        self.abortSignal = abortSignal
        self.maxNeuronHops = maxNeuronHops
        self.concurrency = concurrency
        self.ctx = ctx
        self.modality = modality
        self.afferentPath = afferentPath
        self.stimulationContext = stimulationContext
        self.continuationScheduler = continuationScheduler
    }
}

/// Global `TCNSOptions`: only `autoCleanupContexts` remains in the TS core.
public struct CNSOptions {
    public var autoCleanupContexts: Bool
    public init(autoCleanupContexts: Bool = false) {
        self.autoCleanupContexts = autoCleanupContexts
    }
}

// MARK: - Per-instance neuron queue (TS `CNSInstanceNeuronQueue`)

public final class CNSInstanceNeuronQueue {
    private var gates: [ObjectIdentifier: (limit: Int, active: Int, waiters: [() -> Void])] = [:]

    public init() {}

    public func run(neuron: CNSNeuron, _ fn: @escaping () -> Void) {
        guard let limit = neuron.concurrency, limit > 0 else {
            fn()
            return
        }
        let oid = ObjectIdentifier(neuron)
        var gate = gates[oid] ?? (limit, 0, [])
        gate.limit = limit
        if gate.active < gate.limit {
            gate.active += 1
            gates[oid] = gate
            fn()
        } else {
            gate.waiters.append { [weak self] in
                guard let self else {
                    fn()
                    return
                }
                var g = self.gates[oid] ?? (limit, 0, [])
                g.active += 1
                self.gates[oid] = g
                fn()
            }
            gates[oid] = gate
        }
    }

    func release(neuron: CNSNeuron) {
        let oid = ObjectIdentifier(neuron)
        guard var gate = gates[oid] else { return }
        gate.active = max(0, gate.active - 1)
        if !gate.waiters.isEmpty {
            let next = gate.waiters.removeFirst()
            gates[oid] = gate
            next()
        } else {
            gates[oid] = gate
        }
    }
}

// MARK: - Network graph

public final class CNSNetwork {
    private let neurons: [CNSNeuron]

    public private(set) var stronglyConnectedComponents: [Set<CNSNeuron>] = []
    private var neuronToSCC: [ObjectIdentifier: Int] = [:]
    private var sccDag: [Int: Set<Int>] = [:]
    private var sccAncestors: [Int: Set<Int>] = [:]

    private var subIndex: [ObjectIdentifier: [(CNSNeuron, CNSDendrite)]] = [:]
    private var parentNeuronByCollateral: [ObjectIdentifier: CNSNeuron] = [:]

    public init(neurons: [CNSNeuron]) {
        self.neurons = neurons
        buildIndexes()
        buildSCC()
    }

    private func buildIndexes() {
        subIndex.removeAll()
        parentNeuronByCollateral.removeAll()
        for n in neurons {
            for d in n.dendrites {
                let key = ObjectIdentifier(d.inputCollateral)
                subIndex[key, default: []].append((n, d))
            }
            for collateralObj in n.axon.collateralInstances() {
                parentNeuronByCollateral[ObjectIdentifier(collateralObj)] = n
            }
        }
    }

    public func getSubscribers(collateral: AnyObject) -> [(CNSNeuron, CNSDendrite)] {
        subIndex[ObjectIdentifier(collateral)] ?? []
    }

    public func getParentNeuron(forCollateral collateral: AnyObject) -> CNSNeuron? {
        parentNeuronByCollateral[ObjectIdentifier(collateral)]
    }

    private func buildNeuronGraph() -> [ObjectIdentifier: Set<ObjectIdentifier>] {
        var graph: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        for n in neurons {
            graph[ObjectIdentifier(n)] = []
        }
        for n in neurons {
            var reachable = Set<ObjectIdentifier>()
            for collateralObj in n.axon.collateralInstances() {
                for (target, _) in getSubscribers(collateral: collateralObj) {
                    reachable.insert(ObjectIdentifier(target))
                }
            }
            graph[ObjectIdentifier(n)] = reachable
        }
        return graph
    }

    private func buildSCC() {
        let graphOID = buildNeuronGraph()
        let neuronIds = neurons.map { ObjectIdentifier($0) }
        var oidToNeuron: [ObjectIdentifier: CNSNeuron] = [:]
        for n in neurons { oidToNeuron[ObjectIdentifier(n)] = n }

        var index: [ObjectIdentifier: Int] = [:]
        var lowlink: [ObjectIdentifier: Int] = [:]
        var onStack = Set<ObjectIdentifier>()
        var stack: [ObjectIdentifier] = []
        var components: [Set<ObjectIdentifier>] = []
        var currentIndex = 0

        func strongConnect(_ v: ObjectIdentifier) {
            index[v] = currentIndex
            lowlink[v] = currentIndex
            currentIndex += 1
            stack.append(v)
            onStack.insert(v)
            for w in graphOID[v] ?? [] {
                if index[w] == nil {
                    strongConnect(w)
                    lowlink[v] = min(lowlink[v]!, lowlink[w]!)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v]!, index[w]!)
                }
            }
            if lowlink[v] == index[v] {
                var component = Set<ObjectIdentifier>()
                var w: ObjectIdentifier
                repeat {
                    w = stack.removeLast()
                    onStack.remove(w)
                    component.insert(w)
                } while w != v
                components.append(component)
            }
        }

        for v in neuronIds where index[v] == nil {
            strongConnect(v)
        }

        stronglyConnectedComponents = components.map { oidSet in
            Set(oidSet.compactMap { oidToNeuron[$0] })
        }

        neuronToSCC.removeAll()
        for (i, comp) in stronglyConnectedComponents.enumerated() {
            for neuron in comp {
                neuronToSCC[ObjectIdentifier(neuron)] = i
            }
        }
        buildSCCDAG(graphOID: graphOID)
        buildSCCAncestors()
    }

    private func buildSCCDAG(graphOID: [ObjectIdentifier: Set<ObjectIdentifier>]) {
        sccDag.removeAll()
        for i in 0..<stronglyConnectedComponents.count { sccDag[i] = [] }
        for (i, scc) in stronglyConnectedComponents.enumerated() {
            for neuron in scc {
                let oid = ObjectIdentifier(neuron)
                for neighborOID in graphOID[oid] ?? [] {
                    guard let neighbor = neurons.first(where: { ObjectIdentifier($0) == neighborOID }),
                          let neighborScc = neuronToSCC[ObjectIdentifier(neighbor)],
                          neighborScc != i else { continue }
                    sccDag[neighborScc, default: []].insert(i)
                }
            }
        }
    }

    private func buildSCCAncestors() {
        sccAncestors.removeAll()
        for i in 0..<stronglyConnectedComponents.count { sccAncestors[i] = [] }
        var inDegree: [Int: Int] = [:]
        var queue: [Int] = []
        for i in 0..<stronglyConnectedComponents.count {
            let incoming = sccDag[i]?.count ?? 0
            inDegree[i] = incoming
            if incoming == 0 { queue.append(i) }
        }
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let outgoing = getOutgoingEdges(sccIndex: current)
            for neighbor in outgoing {
                var set = sccAncestors[neighbor] ?? []
                set.insert(current)
                if let currAnc = sccAncestors[current] { set.formUnion(currAnc) }
                sccAncestors[neighbor] = set
                let newIn = (inDegree[neighbor] ?? 0) - 1
                inDegree[neighbor] = newIn
                if newIn == 0 { queue.append(neighbor) }
            }
        }
    }

    private func getOutgoingEdges(sccIndex: Int) -> Set<Int> {
        var outgoing = Set<Int>()
        for (target, incoming) in sccDag where incoming.contains(sccIndex) {
            outgoing.insert(target)
        }
        return outgoing
    }

    public func getSCCSet(neuron: CNSNeuron) -> Set<CNSNeuron>? {
        guard let idx = neuronToSCC[ObjectIdentifier(neuron)] else { return nil }
        return stronglyConnectedComponents[idx]
    }

    public func getSccIndex(neuron: CNSNeuron) -> Int? {
        neuronToSCC[ObjectIdentifier(neuron)]
    }

    public func canNeuronBeGuaranteedDone(neuron: CNSNeuron, activeSccCounts: [Int: Int]) -> Bool {
        guard let sccIndex = neuronToSCC[ObjectIdentifier(neuron)] else { return true }
        if let cnt = activeSccCounts[sccIndex], cnt > 0 { return false }
        guard let ancestors = sccAncestors[sccIndex] else { return true }
        for anc in ancestors {
            if let cnt = activeSccCounts[anc], cnt > 0 { return false }
        }
        return true
    }
}

// MARK: - Activation task (TS `TCNSNeuronActivationTask`)

public final class CNSNeuronActivationTask {
    public let neuron: CNSNeuron
    public let dendriteCollateral: AnyObject
    public let input: Any?

    public init(neuron: CNSNeuron, dendriteCollateral: AnyObject, input: Any?) {
        self.neuron = neuron
        self.dendriteCollateral = dendriteCollateral
        self.input = input
    }
}

// MARK: - Activation task failure (TS `TCNSNeuronActivationTaskFailure`)

public struct CNSNeuronActivationTaskFailure {
    public let task: CNSNeuronActivationTask
    public let error: Error
    public let aborted: Bool

    public init(task: CNSNeuronActivationTask, error: Error, aborted: Bool) {
        self.task = task
        self.error = error
        self.aborted = aborted
    }
}

// MARK: - Stimulation handle

public final class CNSStimulation {
    public weak var cns: CNS?
    public private(set) var isComplete: Bool = false

    /// Mirrors TS fields read from `stimulation.options` inside dendrites / modality helpers.
    public private(set) var modality: CNSModality?
    public private(set) var afferentPath: CNSAfferentPath?
    public private(set) var stimulationContext: Any?
    public private(set) var maxNeuronHops: Int?

    private var queuedTasks: [CNSNeuronActivationTask] = []
    private var activeTasks: [CNSNeuronActivationTask] = []
    private var failedTasks: [CNSNeuronActivationTaskFailure] = []

    public init(cns: CNS) {
        self.cns = cns
    }

    func attachOptions<TIn, TOut>(_ options: CNSStimulationOptions<TIn, TOut>) {
        modality = options.modality
        afferentPath = options.afferentPath
        stimulationContext = options.stimulationContext
        maxNeuronHops = options.maxNeuronHops
    }

    func markComplete() {
        isComplete = true
    }

    func queueTask(_ task: CNSNeuronActivationTask) {
        queuedTasks.append(task)
    }

    func startTask(_ task: CNSNeuronActivationTask) {
        if let idx = queuedTasks.firstIndex(where: { $0 === task }) {
            queuedTasks.remove(at: idx)
        }
        activeTasks.append(task)
    }

    func finishTask(_ task: CNSNeuronActivationTask) {
        if let idx = activeTasks.firstIndex(where: { $0 === task }) {
            activeTasks.remove(at: idx)
        }
    }

    func failTask(_ task: CNSNeuronActivationTask, error: Error, aborted: Bool) {
        finishTask(task)
        if let idx = queuedTasks.firstIndex(where: { $0 === task }) {
            queuedTasks.remove(at: idx)
        }
        failedTasks.append(CNSNeuronActivationTaskFailure(task: task, error: error, aborted: aborted))
    }

    func failQueuedTasks(error: Error, aborted: Bool) {
        for task in queuedTasks {
            failedTasks.append(CNSNeuronActivationTaskFailure(task: task, error: error, aborted: aborted))
        }
        queuedTasks.removeAll()
    }

    public func getAllActivationTasks() -> [CNSNeuronActivationTask] {
        queuedTasks + activeTasks
    }

    public func getFailedTasks() -> [CNSNeuronActivationTaskFailure] {
        failedTasks
    }

    /// TS parity hook; synchronous Swift core completes before this is awaited.
    public func waitUntilComplete() async {
        await Task.yield()
    }
}

// MARK: - ICNS (TS `ICNS`)

public protocol ICNS: AnyObject {
    var network: CNSNetwork { get }
    var options: CNSOptions? { get }

    @discardableResult
    func addResponseListener(_ listener: @escaping (_ response: CNS.CNSAnyResponse) -> Void) -> () -> Void

    func stimulate<TIn, TOut>(_ signal: CNSSignal<TIn>, _ options: CNSStimulationOptions<TIn, TOut>) -> CNSStimulation
    func stimulate<TIn, TOut>(_ signals: [CNSSignal<TIn>], _ options: CNSStimulationOptions<TIn, TOut>) -> CNSStimulation
    func activate<TIn, TOut>(_ tasks: [CNSNeuronActivationTask], _ options: CNSStimulationOptions<TIn, TOut>) -> CNSStimulation
}

// MARK: - CNS

public final class CNS: ICNS {
    private let neurons: [CNSNeuron]
    public let options: CNSOptions?

    public let network: CNSNetwork
    fileprivate let instanceNeuronQueue = CNSInstanceNeuronQueue()
    private let defaultContinuationScheduler: CNSScheduler

    public struct CNSAnyResponse {
        public let inputSignal: Any?
        public let outputSignal: Any?
        public let error: Error?
        public let queueLength: Int
        public let modality: CNSModality?
        public let afferentPath: CNSAfferentPath?
        public let contextValue: [ObjectIdentifier: Any]
        public let hops: Int?
        public let stimulation: CNSStimulation?
    }

    private var globalListeners: [(_ r: CNSAnyResponse) -> Void] = []

    public init(_ neurons: [CNSNeuron], options: CNSOptions? = nil, continuationScheduler: CNSScheduler = CNSAsyncScheduler()) {
        self.neurons = neurons
        self.options = options
        self.network = CNSNetwork(neurons: neurons)
        self.defaultContinuationScheduler = continuationScheduler
    }

    @discardableResult
    public func addResponseListener(_ f: @escaping (_ r: CNSAnyResponse) -> Void) -> () -> Void {
        globalListeners.append(f)
        var active = true
        return { [weak self] in
            guard let self, active else { return }
            active = false
            if let i = self.globalListeners.firstIndex(where: { ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(f as AnyObject) }) {
                self.globalListeners.remove(at: i)
            }
        }
    }

    private func wrapOnResponse<TIn, TOut>(_ local: ((_ r: CNSResponse<TIn, TOut>) -> Void)?, modality: CNSModality?, afferentPath: CNSAfferentPath?, contextValue: @escaping () -> [ObjectIdentifier: Any], hopsProvider: @escaping () -> Int?) -> (_ r: CNSAnyResponse) -> Void {
        if globalListeners.isEmpty && local == nil { return { _ in } }
        return { [weak self] anyR in
            if let local {
                let r = CNSResponse<TIn, TOut>(
                    inputSignal: anyR.inputSignal as? CNSSignal<TIn>,
                    outputSignal: anyR.outputSignal as? CNSSignal<TOut>,
                    error: anyR.error,
                    queueLength: anyR.queueLength,
                    modality: anyR.modality ?? modality,
                    afferentPath: anyR.afferentPath ?? afferentPath,
                    contextValue: anyR.contextValue,
                    hops: anyR.hops ?? hopsProvider(),
                    stimulation: anyR.stimulation
                )
                local(r)
            }
            self?.globalListeners.forEach { $0(anyR) }
        }
    }

    private func continuationScheduler<TIn, TOut>(for options: CNSStimulationOptions<TIn, TOut>) -> CNSScheduler {
        options.continuationScheduler ?? defaultContinuationScheduler
    }

    private func collectOutputs(from response: Any?) -> [any CNSAnySignalProtocol] {
        if let arr = response as? [Any] {
            return arr.compactMap { $0 as? any CNSAnySignalProtocol }
        }
        if let sig = response as? any CNSAnySignalProtocol {
            return [sig]
        }
        return []
    }

    /// Primary stimulation entry (TS `stimulate`).
    @discardableResult
    public func stimulate<TIn, TOut>(_ signal: CNSSignal<TIn>, _ options: CNSStimulationOptions<TIn, TOut> = .init()) -> CNSStimulation {
        let stimulation = CNSStimulation(cns: self)
        stimulation.attachOptions(options)
        let ctxStore = options.ctx ?? CNSStimulationContextStore()
        let scheduler = continuationScheduler(for: options)
        let onResp = wrapOnResponse(
            options.onResponse,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: { ctxStore.getAll() },
            hopsProvider: { nil }
        )

        var queue: [any CNSAnySignalProtocol] = [signal as any CNSAnySignalProtocol]
        var inFlight = 0
        var activeSccCounts: [Int: Int] = [:]
        var neuronVisitCounts: [ObjectIdentifier: Int] = [:]
        let wake = DispatchSemaphore(value: 0)

        func hopCount(for neuron: CNSNeuron) -> Int {
            neuronVisitCounts[ObjectIdentifier(neuron), default: 0]
        }

        func tryIncrementVisit(neuron: CNSNeuron) -> Bool {
            guard let maxHops = options.maxNeuronHops else { return true }
            let oid = ObjectIdentifier(neuron)
            let next = neuronVisitCounts[oid, default: 0] + 1
            if next > maxHops { return false }
            neuronVisitCounts[oid] = next
            return true
        }

        func incScc(for neuron: CNSNeuron) {
            if options.abortSignal?.isAborted == true { return }
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = (activeSccCounts[idx] ?? 0) + 1
            }
        }

        func decSccAndMaybeCleanup(for neuron: CNSNeuron) {
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = max(0, (activeSccCounts[idx] ?? 0) - 1)
                if options.abortSignal?.isAborted != true, self.options?.autoCleanupContexts == true {
                    if network.canNeuronBeGuaranteedDone(neuron: neuron, activeSccCounts: activeSccCounts) {
                        ctxStore.delete(key: neuron)
                    }
                }
            }
        }

        var runGate: (limit: Int, active: Int, waiters: [() -> Void]) = (limit: max(0, options.concurrency ?? 0), active: 0, waiters: [])
        func runWithRunConcurrency(_ fn: @escaping () -> Void) {
            if runGate.limit <= 0 {
                fn()
                return
            }
            if runGate.active < runGate.limit {
                runGate.active += 1
                fn()
            } else {
                runGate.waiters.append {
                    runGate.active += 1
                    fn()
                }
            }
        }

        func releaseRunGate() {
            if runGate.limit <= 0 { return }
            runGate.active = max(0, runGate.active - 1)
            if !runGate.waiters.isEmpty {
                let next = runGate.waiters.removeFirst()
                next()
            }
        }

        if options.abortSignal?.isAborted == true {
            stimulation.failQueuedTasks(
                error: NSError(domain: "CNS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stimulation aborted"]),
                aborted: true
            )
        }

        onResp(CNSAnyResponse(
            inputSignal: nil,
            outputSignal: signal,
            error: nil,
            queueLength: queue.count + inFlight,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: ctxStore.getAll(),
            hops: nil,
            stimulation: stimulation
        ))

        while true {
            if options.abortSignal?.isAborted == true { break }
            let anySig: (any CNSAnySignalProtocol)?
            if !queue.isEmpty {
                anySig = queue.removeFirst()
            } else if inFlight > 0 {
                wake.wait()
                continue
            } else {
                break
            }
            guard let sig = anySig else { continue }
            let subs = network.getSubscribers(collateral: sig.collateralObject)
            for (neuron, dendrite) in subs {
                if options.abortSignal?.isAborted == true { continue }
                guard dendrite.matchesInputCollateral(sig.collateralObject) else { continue }
                let task = CNSNeuronActivationTask(neuron: neuron, dendriteCollateral: dendrite.inputCollateral, input: sig)
                stimulation.queueTask(task)
                guard tryIncrementVisit(neuron: neuron) else {
                    stimulation.failTask(
                        task,
                        error: NSError(domain: "CNS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Max neuron hops reached when trying to enqueue subscriber"]),
                        aborted: false
                    )
                    continue
                }
                incScc(for: neuron)
                runWithRunConcurrency {
                    self.instanceNeuronQueue.run(neuron: neuron) {
                        stimulation.startTask(task)
                        let ctx = CNSLocalCtx(
                            get: { ctxStore.get(key: neuron) },
                            set: { ctxStore.set(key: neuron, value: $0) },
                            delete: { ctxStore.delete(key: neuron) },
                            abortSignal: options.abortSignal,
                            cns: self,
                            stimulation: stimulation
                        )
                        let out = dendrite.response(sig.payloadAny, neuron.axon, ctx)

                        func handleImmediate(_ val: Any?) {
                            stimulation.finishTask(task)
                            self.instanceNeuronQueue.release(neuron: neuron)
                            releaseRunGate()
                            defer { decSccAndMaybeCleanup(for: neuron) }

                            let outs = self.collectOutputs(from: val)
                            if outs.isEmpty {
                                let nextQLen = queue.count + inFlight
                                onResp(CNSAnyResponse(
                                    inputSignal: sig,
                                    outputSignal: nil,
                                    error: nil,
                                    queueLength: nextQLen,
                                    modality: options.modality,
                                    afferentPath: options.afferentPath,
                                    contextValue: ctxStore.getAll(),
                                    hops: hopCount(for: neuron),
                                    stimulation: stimulation
                                ))
                                return
                            }
                            for outSig in outs {
                                let nextQLen = (queue.count + inFlight) + 1
                                onResp(CNSAnyResponse(
                                    inputSignal: sig,
                                    outputSignal: outSig,
                                    error: nil,
                                    queueLength: nextQLen,
                                    modality: options.modality,
                                    afferentPath: options.afferentPath,
                                    contextValue: ctxStore.getAll(),
                                    hops: hopCount(for: neuron),
                                    stimulation: stimulation
                                ))
                                queue.append(outSig)
                            }
                        }

                        if let ev = out as? CNSEventual {
                            switch ev {
                            case .immediate(let v):
                                handleImmediate(v)
                            case .future(let producer):
                                inFlight += 1
                                producer { v in
                                    scheduler.perform {
                                        inFlight = max(0, inFlight - 1)
                                        handleImmediate(v)
                                        wake.signal()
                                    }
                                }
                            }
                        } else {
                            handleImmediate(out)
                        }
                    }
                }
            }
        }

        if options.abortSignal?.isAborted == true {
            stimulation.failQueuedTasks(
                error: NSError(domain: "CNS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stimulation aborted"]),
                aborted: true
            )
        }

        onResp(CNSAnyResponse(
            inputSignal: nil,
            outputSignal: nil,
            error: nil,
            queueLength: 0,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: ctxStore.getAll(),
            hops: nil,
            stimulation: stimulation
        ))
        stimulation.markComplete()
        return stimulation
    }

    /// TS `stimulate` with multiple seed signals.
    @discardableResult
    public func stimulate<TIn, TOut>(_ signals: [CNSSignal<TIn>], _ options: CNSStimulationOptions<TIn, TOut> = .init()) -> CNSStimulation {
        guard !signals.isEmpty else {
            let stimulation = CNSStimulation(cns: self)
            stimulation.markComplete()
            return stimulation
        }
        let stimulation = CNSStimulation(cns: self)
        stimulation.attachOptions(options)
        let ctxStore = options.ctx ?? CNSStimulationContextStore()
        let scheduler = continuationScheduler(for: options)
        let onResp = wrapOnResponse(
            options.onResponse,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: { ctxStore.getAll() },
            hopsProvider: { nil }
        )

        var queue: [any CNSAnySignalProtocol] = signals.map { $0 as any CNSAnySignalProtocol }
        var inFlight = 0
        var activeSccCounts: [Int: Int] = [:]
        var neuronVisitCounts: [ObjectIdentifier: Int] = [:]
        let wake = DispatchSemaphore(value: 0)

        func hopCount(for neuron: CNSNeuron) -> Int {
            neuronVisitCounts[ObjectIdentifier(neuron), default: 0]
        }

        func tryIncrementVisit(neuron: CNSNeuron) -> Bool {
            guard let maxHops = options.maxNeuronHops else { return true }
            let oid = ObjectIdentifier(neuron)
            let next = neuronVisitCounts[oid, default: 0] + 1
            if next > maxHops { return false }
            neuronVisitCounts[oid] = next
            return true
        }

        func incScc(for neuron: CNSNeuron) {
            if options.abortSignal?.isAborted == true { return }
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = (activeSccCounts[idx] ?? 0) + 1
            }
        }

        func decSccAndMaybeCleanup(for neuron: CNSNeuron) {
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = max(0, (activeSccCounts[idx] ?? 0) - 1)
                if options.abortSignal?.isAborted != true, self.options?.autoCleanupContexts == true {
                    if network.canNeuronBeGuaranteedDone(neuron: neuron, activeSccCounts: activeSccCounts) {
                        ctxStore.delete(key: neuron)
                    }
                }
            }
        }

        var runGate: (limit: Int, active: Int, waiters: [() -> Void]) = (limit: max(0, options.concurrency ?? 0), active: 0, waiters: [])
        func runWithRunConcurrency(_ fn: @escaping () -> Void) {
            if runGate.limit <= 0 {
                fn()
                return
            }
            if runGate.active < runGate.limit {
                runGate.active += 1
                fn()
            } else {
                runGate.waiters.append {
                    runGate.active += 1
                    fn()
                }
            }
        }

        func releaseRunGate() {
            if runGate.limit <= 0 { return }
            runGate.active = max(0, runGate.active - 1)
            if !runGate.waiters.isEmpty {
                runGate.waiters.removeFirst()()
            }
        }

        for s in signals {
            onResp(CNSAnyResponse(
                inputSignal: nil,
                outputSignal: s,
                error: nil,
                queueLength: queue.count + inFlight,
                modality: options.modality,
                afferentPath: options.afferentPath,
                contextValue: ctxStore.getAll(),
                hops: nil,
                stimulation: stimulation
            ))
        }

        while true {
            if options.abortSignal?.isAborted == true { break }
            let anySig: (any CNSAnySignalProtocol)?
            if !queue.isEmpty {
                anySig = queue.removeFirst()
            } else if inFlight > 0 {
                wake.wait()
                continue
            } else {
                break
            }
            guard let sig = anySig else { continue }
            let subs = network.getSubscribers(collateral: sig.collateralObject)
            for (neuron, dendrite) in subs {
                if options.abortSignal?.isAborted == true { continue }
                guard dendrite.matchesInputCollateral(sig.collateralObject) else { continue }
                let task = CNSNeuronActivationTask(neuron: neuron, dendriteCollateral: dendrite.inputCollateral, input: sig)
                stimulation.queueTask(task)
                guard tryIncrementVisit(neuron: neuron) else {
                    stimulation.failTask(
                        task,
                        error: NSError(domain: "CNS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Max neuron hops reached when trying to enqueue subscriber"]),
                        aborted: false
                    )
                    continue
                }
                incScc(for: neuron)
                runWithRunConcurrency {
                    self.instanceNeuronQueue.run(neuron: neuron) {
                        stimulation.startTask(task)
                        let ctx = CNSLocalCtx(
                            get: { ctxStore.get(key: neuron) },
                            set: { ctxStore.set(key: neuron, value: $0) },
                            delete: { ctxStore.delete(key: neuron) },
                            abortSignal: options.abortSignal,
                            cns: self,
                            stimulation: stimulation
                        )
                        let out = dendrite.response(sig.payloadAny, neuron.axon, ctx)

                        func handleImmediate(_ val: Any?) {
                            stimulation.finishTask(task)
                            self.instanceNeuronQueue.release(neuron: neuron)
                            releaseRunGate()
                            defer { decSccAndMaybeCleanup(for: neuron) }

                            let outs = self.collectOutputs(from: val)
                            if outs.isEmpty {
                                let nextQLen = queue.count + inFlight
                                onResp(CNSAnyResponse(
                                    inputSignal: sig,
                                    outputSignal: nil,
                                    error: nil,
                                    queueLength: nextQLen,
                                    modality: options.modality,
                                    afferentPath: options.afferentPath,
                                    contextValue: ctxStore.getAll(),
                                    hops: hopCount(for: neuron),
                                    stimulation: stimulation
                                ))
                                return
                            }
                            for outSig in outs {
                                let nextQLen = (queue.count + inFlight) + 1
                                onResp(CNSAnyResponse(
                                    inputSignal: sig,
                                    outputSignal: outSig,
                                    error: nil,
                                    queueLength: nextQLen,
                                    modality: options.modality,
                                    afferentPath: options.afferentPath,
                                    contextValue: ctxStore.getAll(),
                                    hops: hopCount(for: neuron),
                                    stimulation: stimulation
                                ))
                                queue.append(outSig)
                            }
                        }

                        if let ev = out as? CNSEventual {
                            switch ev {
                            case .immediate(let v):
                                handleImmediate(v)
                            case .future(let producer):
                                inFlight += 1
                                producer { v in
                                    scheduler.perform {
                                        inFlight = max(0, inFlight - 1)
                                        handleImmediate(v)
                                        wake.signal()
                                    }
                                }
                            }
                        } else {
                            handleImmediate(out)
                        }
                    }
                }
            }
        }

        if options.abortSignal?.isAborted == true {
            stimulation.failQueuedTasks(
                error: NSError(domain: "CNS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stimulation aborted"]),
                aborted: true
            )
        }

        onResp(CNSAnyResponse(
            inputSignal: nil,
            outputSignal: nil,
            error: nil,
            queueLength: 0,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: ctxStore.getAll(),
            hops: nil,
            stimulation: stimulation
        ))
        stimulation.markComplete()
        return stimulation
    }

    /// TS `activate`: enqueue explicit dendrite activations (simplified synchronous propagation).
    @discardableResult
    public func activate<TIn, TOut>(_ tasks: [CNSNeuronActivationTask], _ options: CNSStimulationOptions<TIn, TOut> = .init()) -> CNSStimulation {
        let wrappedSignals: [CNSSignal<TIn>] = tasks.compactMap { task in
            guard let input = task.input else { return nil }
            return input as? CNSSignal<TIn>
        }
        if wrappedSignals.count == tasks.count, !wrappedSignals.isEmpty {
            return stimulate(wrappedSignals, options)
        }

        let stimulation = CNSStimulation(cns: self)
        stimulation.attachOptions(options)
        let ctxStore = options.ctx ?? CNSStimulationContextStore()
        let scheduler = continuationScheduler(for: options)
        let onResp = wrapOnResponse(
            options.onResponse,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: { ctxStore.getAll() },
            hopsProvider: { nil }
        )

        var queue: [any CNSAnySignalProtocol] = []
        var inFlight = 0
        var activeSccCounts: [Int: Int] = [:]
        var neuronVisitCounts: [ObjectIdentifier: Int] = [:]
        let wake = DispatchSemaphore(value: 0)

        func hopCount(for neuron: CNSNeuron) -> Int {
            neuronVisitCounts[ObjectIdentifier(neuron), default: 0]
        }

        func tryIncrementVisit(neuron: CNSNeuron) -> Bool {
            guard let maxHops = options.maxNeuronHops else { return true }
            let oid = ObjectIdentifier(neuron)
            let next = neuronVisitCounts[oid, default: 0] + 1
            if next > maxHops { return false }
            neuronVisitCounts[oid] = next
            return true
        }

        func incScc(for neuron: CNSNeuron) {
            if options.abortSignal?.isAborted == true { return }
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = (activeSccCounts[idx] ?? 0) + 1
            }
        }

        func decSccAndMaybeCleanup(for neuron: CNSNeuron) {
            if let idx = network.getSccIndex(neuron: neuron) {
                activeSccCounts[idx] = max(0, (activeSccCounts[idx] ?? 0) - 1)
                if options.abortSignal?.isAborted != true, self.options?.autoCleanupContexts == true {
                    if network.canNeuronBeGuaranteedDone(neuron: neuron, activeSccCounts: activeSccCounts) {
                        ctxStore.delete(key: neuron)
                    }
                }
            }
        }

        var runGate: (limit: Int, active: Int, waiters: [() -> Void]) = (limit: max(0, options.concurrency ?? 0), active: 0, waiters: [])
        func runWithRunConcurrency(_ fn: @escaping () -> Void) {
            if runGate.limit <= 0 {
                fn()
                return
            }
            if runGate.active < runGate.limit {
                runGate.active += 1
                fn()
            } else {
                runGate.waiters.append {
                    runGate.active += 1
                    fn()
                }
            }
        }

        func releaseRunGate() {
            if runGate.limit <= 0 { return }
            runGate.active = max(0, runGate.active - 1)
            if !runGate.waiters.isEmpty {
                runGate.waiters.removeFirst()()
            }
        }

        func processDirect(neuron: CNSNeuron, dendrite: CNSDendrite, sig: (any CNSAnySignalProtocol)?) {
            let task = CNSNeuronActivationTask(neuron: neuron, dendriteCollateral: dendrite.inputCollateral, input: sig)
            stimulation.queueTask(task)
            guard tryIncrementVisit(neuron: neuron) else {
                stimulation.failTask(
                    task,
                    error: NSError(domain: "CNS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Max neuron hops reached when trying to enqueue subscriber"]),
                    aborted: false
                )
                return
            }
            incScc(for: neuron)
            runWithRunConcurrency {
                self.instanceNeuronQueue.run(neuron: neuron) {
                    stimulation.startTask(task)
                    let ctx = CNSLocalCtx(
                        get: { ctxStore.get(key: neuron) },
                        set: { ctxStore.set(key: neuron, value: $0) },
                        delete: { ctxStore.delete(key: neuron) },
                        abortSignal: options.abortSignal,
                        cns: self,
                        stimulation: stimulation
                    )
                    let out = dendrite.response(sig?.payloadAny, neuron.axon, ctx)

                    func handleImmediate(_ val: Any?) {
                        stimulation.finishTask(task)
                        self.instanceNeuronQueue.release(neuron: neuron)
                        releaseRunGate()
                        defer { decSccAndMaybeCleanup(for: neuron) }

                        let outs = self.collectOutputs(from: val)
                        if outs.isEmpty {
                            let nextQLen = queue.count + inFlight
                            onResp(CNSAnyResponse(
                                inputSignal: sig,
                                outputSignal: nil,
                                error: nil,
                                queueLength: nextQLen,
                                modality: options.modality,
                                afferentPath: options.afferentPath,
                                contextValue: ctxStore.getAll(),
                                hops: hopCount(for: neuron),
                                stimulation: stimulation
                            ))
                            return
                        }
                        for outSig in outs {
                            let nextQLen = (queue.count + inFlight) + 1
                            onResp(CNSAnyResponse(
                                inputSignal: sig,
                                outputSignal: outSig,
                                error: nil,
                                queueLength: nextQLen,
                                modality: options.modality,
                                afferentPath: options.afferentPath,
                                contextValue: ctxStore.getAll(),
                                hops: hopCount(for: neuron),
                                stimulation: stimulation
                            ))
                            queue.append(outSig)
                        }
                    }

                    if let ev = out as? CNSEventual {
                        switch ev {
                        case .immediate(let v):
                            handleImmediate(v)
                        case .future(let producer):
                            inFlight += 1
                            producer { v in
                                scheduler.perform {
                                    inFlight = max(0, inFlight - 1)
                                    handleImmediate(v)
                                    wake.signal()
                                }
                            }
                        }
                    } else {
                        handleImmediate(out)
                    }
                }
            }
        }

        for task in tasks {
            guard let dendrite = task.neuron.dendrites.first(where: { $0.matchesInputCollateral(task.dendriteCollateral) }) else { continue }
            let sig = task.input as? any CNSAnySignalProtocol
            processDirect(neuron: task.neuron, dendrite: dendrite, sig: sig)
        }

        while true {
            if options.abortSignal?.isAborted == true { break }
            let anySig: (any CNSAnySignalProtocol)?
            if !queue.isEmpty {
                anySig = queue.removeFirst()
            } else if inFlight > 0 {
                wake.wait()
                continue
            } else {
                break
            }
            guard let sig = anySig else { continue }
            let subs = network.getSubscribers(collateral: sig.collateralObject)
            for (neuron, dendrite) in subs {
                if options.abortSignal?.isAborted == true { continue }
                guard dendrite.matchesInputCollateral(sig.collateralObject) else { continue }
                processDirect(neuron: neuron, dendrite: dendrite, sig: sig)
            }
        }

        onResp(CNSAnyResponse(
            inputSignal: nil,
            outputSignal: nil,
            error: nil,
            queueLength: 0,
            modality: options.modality,
            afferentPath: options.afferentPath,
            contextValue: ctxStore.getAll(),
            hops: nil,
            stimulation: stimulation
        ))
        stimulation.markComplete()
        return stimulation
    }

    public func stimulate<TIn>(_ signal: CNSSignal<TIn>) -> CNSStimulation {
        stimulate(signal, CNSStimulationOptions<TIn, Any>())
    }

    public func stimulate<TIn, TOut>(_ signal: CNSSignal<TIn>, onResponse: ((_ r: CNSResponse<TIn, TOut>) -> Void)?) -> CNSStimulation {
        stimulate(signal, CNSStimulationOptions<TIn, TOut>(onResponse: onResponse))
    }
}
