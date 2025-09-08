import Foundation

public struct CNSSignal<Payload> {
    public let collateralType: String
    public let payload: Payload?
}

protocol CNSAnySignalProtocol {
    var collateralType: String { get }
    var payloadAny: Any? { get }
}

extension CNSSignal: CNSAnySignalProtocol {
    var payloadAny: Any? { return payload }
}

public final class CNSCollateral<Payload> {
    public let type: String
    public init(_ type: String) { self.type = type }
    public func createSignal(_ payload: Payload? = nil) -> CNSSignal<Payload> {
        return CNSSignal(collateralType: type, payload: payload)
    }
}

// Strongly-typed collateral identifier (phantom typed)
public struct CNSCollateralID<Payload> {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public extension CNSCollateral {
    var id: CNSCollateralID<Payload> { CNSCollateralID<Payload>(self.type) }
}

@dynamicMemberLookup
public final class CNSAxon {
    public private(set) var byType: [String: Any] = [:]
    public init() {}
    public func register<T>(_ collateral: CNSCollateral<T>) { byType[collateral.type] = collateral }
    public func contains(_ t: String) -> Bool { byType.keys.contains(t) }
    
    // Convenience methods for getting typed collaterals
    public func get<T>(_ type: String) -> CNSCollateral<T>? {
        return byType[type] as? CNSCollateral<T>
    }
    
    public func get<T>(_ collateral: CNSCollateral<T>) -> CNSCollateral<T>? {
        return byType[collateral.type] as? CNSCollateral<T>
    }
    
    // String-based typed accessors (no external references required)
    public func register<T>(_ type: String, _ payloadType: T.Type) {
        let c = CNSCollateral<T>(type)
        register(c)
    }
    
    public func get<T>(_ type: String, _ payloadType: T.Type) -> CNSCollateral<T>? { byType[type] as? CNSCollateral<T> }
    public func get<T>(_ id: CNSCollateralID<T>) -> CNSCollateral<T>? { byType[id.rawValue] as? CNSCollateral<T> }
    
    public func getForce<T>(_ type: String, _ payloadType: T.Type) -> CNSCollateral<T> {
        if let c = byType[type] as? CNSCollateral<T> { return c }
        preconditionFailure("[CNSAxon] Missing collateral '\(type)' of type \(T.self)")
    }
    public func getForce<T>(_ id: CNSCollateralID<T>) -> CNSCollateral<T> {
        if let c = byType[id.rawValue] as? CNSCollateral<T> { return c }
        preconditionFailure("[CNSAxon] Missing collateral '\(id.rawValue)' of type \(T.self)")
    }
    
    // Force unwrap version for when you're sure the collateral exists
    public func getForce<T>(_ collateral: CNSCollateral<T>) -> CNSCollateral<T> {
        return byType[collateral.type] as! CNSCollateral<T>
    }
    
    // Create and register a new collateral directly in the axon
    public func create<T>(_ type: String) -> CNSCollateral<T> {
        let collateral = CNSCollateral<T>(type)
        register(collateral)
        return collateral
    }
    
    // Create and register a new collateral with a specific type
    public func create<T>(_ type: String, _ payloadType: T.Type) -> CNSCollateral<T> {
        let collateral = CNSCollateral<T>(type)
        register(collateral)
        return collateral
    }
    public func register<T>(_ id: CNSCollateralID<T>) { byType[id.rawValue] = CNSCollateral<T>(id.rawValue) }

    // Dynamic member access: axon.output -> CNSCollateral<T>
    public subscript<T>(dynamicMember member: String) -> CNSCollateral<T> {
        if let c: CNSCollateral<T> = get(member, T.self) { return c }
        preconditionFailure("[CNSAxon] Missing collateral '\(member)' of type \(T.self)")
    }

    // Safe dynamic member namespace: axon.safe.output -> CNSCollateral<T>?
    public var safe: CNSAxonSafe { CNSAxonSafe(axon: self) }
}

@dynamicMemberLookup
public struct CNSAxonSafe {
    let axon: CNSAxon
    public subscript<T>(dynamicMember member: String) -> CNSCollateral<T>? {
        axon.get(member, T.self)
    }
}

// MARK: Axon builder DSL

@dynamicMemberLookup
public struct CNSAxonDefiner {
    let axon: CNSAxon
    // Usage: def.output(String.self) or def.intOutput(Int.self)
    public subscript<T>(dynamicMember key: String) -> (_ type: T.Type) -> Void {
        { t in axon.register(key, t) }
    }
    // Explicit generic add
    public func add<T>(_ key: String, _ type: T.Type) { axon.register(key, type) }
}

public extension CNSAxon {
    static func make(_ define: (CNSAxonDefiner) -> Void) -> CNSAxon {
        let axon = CNSAxon()
        define(CNSAxonDefiner(axon: axon))
        return axon
    }
}

public final class CNSCancellationToken {
    private var cancelled: Bool = false
    public init() {}
    public func cancel() { cancelled = true }
    public var isCancelled: Bool { cancelled }
    // Bridge from Swift concurrency Task
    public static func fromTask() -> CNSCancellationToken {
        let t = CNSCancellationToken()
        if Task.isCancelled { t.cancel() }
        return t
    }
}

// MARK: Scheduling
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

// MARK: Creator-style API for collaterals

public protocol CNSCollateralCreator {
    associatedtype Payload
    associatedtype Output
    var key: String { get }
    func make(_ payload: Payload) -> Output
}

public extension CNSAxon {
    // Safe emit (optional) – returns nil if collateral is not registered
    func tryEmit<C: CNSCollateralCreator>(_ creator: C, _ payload: C.Payload) -> CNSSignal<C.Output>? {
        guard let collateral: CNSCollateral<C.Output> = get(creator.key, C.Output.self) else { return nil }
        return collateral.createSignal(creator.make(payload))
    }
    // Force emit – crashes if collateral with key is missing (use in controlled environments/tests)
    func emit<C: CNSCollateralCreator>(_ creator: C, _ payload: C.Payload) -> CNSSignal<C.Output> {
        let collateral: CNSCollateral<C.Output> = getForce(creator.key, C.Output.self)
        return collateral.createSignal(creator.make(payload))
    }
}

public final class CNSLocalCtx {
    public let get: () -> Any?
    public let set: (Any?) -> Void
    public let abortToken: CNSCancellationToken?
    public weak var cns: CNS?
    public init(get: @escaping () -> Any?, set: @escaping (Any?) -> Void, abortToken: CNSCancellationToken?, cns: CNS) {
        self.get = get
        self.set = set
        self.abortToken = abortToken
        self.cns = cns
    }
}

// Typed context helpers
public struct CNSContextKey<T> { public init() {} }
public extension CNSLocalCtx {
    func get<T>(_ key: CNSContextKey<T>) -> T? { get() as? T }
    func set<T>(_ key: CNSContextKey<T>, _ value: T?) { set(value) }
}

public typealias CNSDendriteResponse = (_ payload: Any?, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?

// Eventual response helper to support async dendrite responses (compatible with Any? return)
public enum CNSEventual {
    case immediate(Any?)
    case future((_ complete: @escaping (Any?) -> Void) -> Void)
}

// Protocol for type erasure
public protocol CNSAnyCollateral {
    var type: String { get }
    func createSignal<Payload>(_ payload: Payload?) -> CNSSignal<Payload>
}

extension CNSCollateral: CNSAnyCollateral {
    public func createSignal<NewPayload>(_ payload: NewPayload?) -> CNSSignal<NewPayload> {
        return CNSSignal(collateralType: self.type, payload: payload)
    }
}

// Type-safe dendrite response with full axon access
public typealias CNSTypedDendriteResponse<Input> = (_ payload: Input?, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?

public struct CNSDendrite {
    public let inputCollateralType: String
    public let response: CNSDendriteResponse
    
    // Type-safe initializer with full axon access
    public init<Input>(inputCollateral: CNSCollateral<Input>, typedResponse: @escaping CNSTypedDendriteResponse<Input>) {
        self.inputCollateralType = inputCollateral.type
        self.response = { payload, axon, ctx in
            guard let typedPayload = payload as? Input else { return nil }
            return typedResponse(typedPayload, axon, ctx)
        }
    }

    // Strict non-optional payload initializer; use Input == Void to model no-payload
    public init<Input>(inputCollateral: CNSCollateral<Input>, strictResponse: @escaping (_ payload: Input, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?) {
        self.inputCollateralType = inputCollateral.type
        self.response = { payload, axon, ctx in
            if Input.self == Void.self {
                // Treat Void as no payload
                return strictResponse(() as! Input, axon, ctx)
            }
            guard let p = payload as? Input else { return nil }
            return strictResponse(p, axon, ctx)
        }
    }

    // Throwing response routed to a dedicated error collateral (instance)
    public init<Input, E: Error>(inputCollateral: CNSCollateral<Input>, errorCollateral: CNSCollateral<E>, throwingResponse: @escaping (_ payload: Input, _ axon: CNSAxon, _ ctx: CNSLocalCtx) throws -> Any?) {
        self.inputCollateralType = inputCollateral.type
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
                // Fallback to error channel via onResponse error path
                return nil
            }
        }
    }

    // Throwing response routed to a dedicated error collateral (by ID, resolved at runtime from axon)
    public init<Input, E: Error>(inputCollateral: CNSCollateral<Input>, errorCollateralId: CNSCollateralID<E>, throwingResponse: @escaping (_ payload: Input, _ axon: CNSAxon, _ ctx: CNSLocalCtx) throws -> Any?) {
        self.inputCollateralType = inputCollateral.type
        self.response = { payload, axon, ctx in
            do {
                if Input.self == Void.self {
                    return try throwingResponse(() as! Input, axon, ctx)
                }
                guard let p = payload as? Input else { return nil }
                return try throwingResponse(p, axon, ctx)
            } catch let e as E {
                let ch: CNSCollateral<E> = axon.getForce(errorCollateralId)
                return ch.createSignal(e)
            } catch {
                return nil
            }
        }
    }
    
    // Legacy initializer for backward compatibility
    public init(collateralType: String, response: @escaping CNSDendriteResponse) {
        self.inputCollateralType = collateralType
        self.response = response
    }
    
    // Computed property for backward compatibility
    public var collateralType: String {
        return inputCollateralType
    }
}

public final class CNSNeuron {
    public let name: String
    public let axon: CNSAxon
    public let dendrites: [CNSDendrite]
    public var concurrency: Int?
    public init(name: String, axon: CNSAxon, dendrites: [CNSDendrite], concurrency: Int? = nil) {
        self.name = name
        self.axon = axon
        self.dendrites = dendrites
        self.concurrency = concurrency
    }
}

public struct CNSResponse<TIn, TOut> {
    public let input: CNSSignal<TIn>?
    public let output: CNSSignal<TOut>?
    public let error: Error?
    public let queueLength: Int
}

public struct CNSStimulationOptions<TIn, TOut> {
    public var onResponse: ((_ response: CNSResponse<TIn, TOut>) -> Void)?
    public var cancelToken: CNSCancellationToken?
    public var maxHops: Int?
    public var runConcurrency: Int?
    public var scheduler: CNSScheduler?
    public init(
        onResponse: ((_ response: CNSResponse<TIn, TOut>) -> Void)? = nil,
        cancelToken: CNSCancellationToken? = nil,
        maxHops: Int? = nil,
        runConcurrency: Int? = nil,
        scheduler: CNSScheduler? = nil
    ) {
        self.onResponse = onResponse
        self.cancelToken = cancelToken
        self.maxHops = maxHops
        self.runConcurrency = runConcurrency
        self.scheduler = scheduler
    }
}

public struct CNSOptions {
    public var autoCleanupContexts: Bool
    public var scheduler: CNSScheduler?
    public init(autoCleanupContexts: Bool = false, scheduler: CNSScheduler? = nil) {
        self.autoCleanupContexts = autoCleanupContexts
        self.scheduler = scheduler
    }
}

public final class CNS {
    private let neurons: [CNSNeuron]
    private let options: CNSOptions?
    private let scheduler: CNSScheduler

    // Global listeners (untyped response)
    public struct CNSAnyResponse {
        public let input: Any?
        public let output: Any?
        public let error: Error?
        public let queueLength: Int
    }
    private var globalListeners: [(_ r: CNSAnyResponse) -> Void] = []

    // Global per-neuron gates (simple counting, single-threaded expected)
    private var neuronGates: [String: (limit: Int, active: Int, waiters: [() -> Void]) ] = [:]

    // Indexes/topology
    private var subIndex: [String: [(CNSNeuron, CNSDendrite)]] = [:]
    private var parentNeuronByCollateralId: [String: CNSNeuron] = [:]
    public private(set) var stronglyConnectedComponents: [Set<String>] = []
    private var neuronToSCC: [String: Int] = [:]
    private var sccDag: [Int: Set<Int>] = [:]
    private var sccAncestors: [Int: Set<Int>] = [:]

    public init(_ neurons: [CNSNeuron], options: CNSOptions? = nil) {
        self.neurons = neurons
        self.options = options
        self.scheduler = options?.scheduler ?? CNSSyncScheduler()
        self.validateUniqueIdentifiers()
        self.buildIndexes()
        if options?.autoCleanupContexts == true { self.buildSCC() }
    }

    // MARK: Unique validation
    private func validateUniqueIdentifiers() {
        var errors: [String] = []
        var seenNames = Set<String>()
        var typeOwner: [String: String] = [:]

        for n in neurons {
            if n.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Neuron has empty name") }
            if seenNames.contains(n.name) { errors.append("Duplicate neuron name: \(n.name)") } else { seenNames.insert(n.name) }
            for t in n.axon.byType.keys {
                if let prev = typeOwner[t], prev != n.name { errors.append("Collateral type \(t) is owned by both \(prev) and \(n.name)") }
                else { typeOwner[t] = n.name }
            }
        }
        if !errors.isEmpty { fatalError("[CNS] Uniqueness failed:\n - " + errors.joined(separator: "\n - ")) }
    }

    // MARK: Indexes
    private func buildIndexes() {
        subIndex.removeAll()
        parentNeuronByCollateralId.removeAll()
        for n in neurons {
            for d in n.dendrites {
                subIndex[d.inputCollateralType, default: []].append((n, d))
            }
            for t in n.axon.byType.keys { parentNeuronByCollateralId[t] = n }
        }
    }

    public func getSubscribers(collateralType: String) -> [(CNSNeuron, CNSDendrite)] {
        return subIndex[collateralType] ?? []
    }

    public func getParentNeuronByCollateralId(collateralType: String) -> CNSNeuron? {
        return parentNeuronByCollateralId[collateralType]
    }

    // MARK: SCC Graph
    private func buildNeuronGraph() -> [String: Set<String>] {
        var graph: [String: Set<String>] = [:]
        let neuronIds = neurons.map { $0.name }
        neuronIds.forEach { graph[$0] = Set<String>() }
        // edges: neuron -> neurons it can reach via its axon's collaterals
        for n in neurons {
            var reachable = Set<String>()
            for t in n.axon.byType.keys {
                if let subs = subIndex[t] {
                    for (target, _) in subs { reachable.insert(target.name) }
                }
            }
            graph[n.name] = reachable
        }
        return graph
    }

    private func buildSCC() {
        let graph = buildNeuronGraph()
        let neuronIds = neurons.map { $0.name }
        var index: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack = Set<String>()
        var stack: [String] = []
        var components: [Set<String>] = []
        var currentIndex = 0

        func strongConnect(_ v: String) {
            index[v] = currentIndex
            lowlink[v] = currentIndex
            currentIndex += 1
            stack.append(v)
            onStack.insert(v)
            for w in graph[v] ?? Set<String>() {
                if index[w] == nil {
                    strongConnect(w)
                    lowlink[v] = min(lowlink[v]!, lowlink[w]!)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v]!, index[w]!)
                }
            }
            if lowlink[v] == index[v] {
                var component = Set<String>()
                var w: String
                repeat {
                    w = stack.removeLast()
                    onStack.remove(w)
                    component.insert(w)
                } while w != v
                components.append(component)
            }
        }

        for v in neuronIds { if index[v] == nil { strongConnect(v) } }
        stronglyConnectedComponents = components
        neuronToSCC.removeAll()
        for (i, comp) in components.enumerated() { for v in comp { neuronToSCC[v] = i } }
        buildSCCDAG(graph: graph)
        buildSCCAncestors()
    }

    private func buildSCCDAG(graph: [String: Set<String>]) {
        sccDag.removeAll()
        for i in 0..<(stronglyConnectedComponents.count) { sccDag[i] = Set<Int>() }
        for (i, scc) in stronglyConnectedComponents.enumerated() {
            for neuronId in scc {
                for neighbor in graph[neuronId] ?? Set<String>() {
                    if let neighborScc = neuronToSCC[neighbor], neighborScc != i {
                        sccDag[neighborScc, default: Set<Int>()].insert(i)
                    }
                }
            }
        }
    }

    private func buildSCCAncestors() {
        sccAncestors.removeAll()
        for i in 0..<(stronglyConnectedComponents.count) { sccAncestors[i] = Set<Int>() }
        // in-degree
        var inDegree: [Int: Int] = [:]
        var queue: [Int] = []
        for i in 0..<(stronglyConnectedComponents.count) {
            let incoming = sccDag[i]?.count ?? 0
            inDegree[i] = incoming
            if incoming == 0 { queue.append(i) }
        }
        while !queue.isEmpty {
            let current = queue.removeFirst()
            // outgoing edges: all scc that have current as incoming
            let outgoing = getOutgoingEdges(sccIndex: current)
            for neighbor in outgoing {
                var set = sccAncestors[neighbor] ?? Set<Int>()
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
        for (target, incoming) in sccDag {
            if incoming.contains(sccIndex) { outgoing.insert(target) }
        }
        return outgoing
    }

    public func getSCCSetByNeuronName(_ neuronName: String) -> Set<String>? {
        guard let idx = neuronToSCC[neuronName] else { return nil }
        return stronglyConnectedComponents[idx]
    }

    public func getSccIndexByNeuronName(_ neuronName: String) -> Int? { neuronToSCC[neuronName] }

    public func canNeuronBeGuaranteedDone(neuronName: String, activeSccCounts: [Int: Int]) -> Bool {
        guard let sccIndex = neuronToSCC[neuronName] else { return true }
        if let cnt = activeSccCounts[sccIndex], cnt > 0 { return false }
        guard let ancestors = sccAncestors[sccIndex] else { return true }
        for anc in ancestors { if let cnt = activeSccCounts[anc], cnt > 0 { return false } }
        return true
    }

    // MARK: Listeners
    @discardableResult
    public func addResponseListener(_ f: @escaping (_ r: CNSAnyResponse) -> Void) -> () -> Void {
        globalListeners.append(f)
        var active = true
        return { [weak self] in
            guard let self = self, active else { return }
            active = false
            if let i = self.globalListeners.firstIndex(where: { ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(f as AnyObject) }) {
                self.globalListeners.remove(at: i)
            }
        }
    }

    private func wrapOnResponse<TIn, TOut>(_ local: ((_ r: CNSResponse<TIn, TOut>) -> Void)?) -> (_ r: CNSAnyResponse) -> Void {
        if globalListeners.isEmpty && local == nil { return { _ in } }
        return { [weak self] anyR in
            if let local = local {
                let r = CNSResponse<TIn, TOut>(
                    input: anyR.input as? CNSSignal<TIn>,
                    output: anyR.output as? CNSSignal<TOut>,
                    error: anyR.error,
                    queueLength: anyR.queueLength
                )
                local(r)
            }
            self?.globalListeners.forEach { $0(anyR) }
        }
    }

    // MARK: Gates
    private func runWithConcurrency(neuron: CNSNeuron, _ fn: @escaping () -> Void) {
        guard let limit = neuron.concurrency, limit > 0 else { fn(); return }
        var gate = neuronGates[neuron.name] ?? (limit, 0, [])
        gate.limit = limit
        if gate.active < gate.limit {
            gate.active += 1
            neuronGates[neuron.name] = gate
            fn()
        } else {
            gate.waiters.append { [weak self] in
                guard var g = self?.neuronGates[neuron.name] else { fn(); return }
                g.active += 1
                self?.neuronGates[neuron.name] = g
                fn()
            }
            neuronGates[neuron.name] = gate
        }
    }

    private func releaseGate(for neuron: CNSNeuron) {
        guard var gate = neuronGates[neuron.name] else { return }
        gate.active = max(0, gate.active - 1)
        if !gate.waiters.isEmpty {
            let next = gate.waiters.removeFirst()
            neuronGates[neuron.name] = gate
            next()
        } else {
            neuronGates[neuron.name] = gate
        }
    }

    // MARK: Stimulate
    public func stimulate<TIn, TOut>(_ signal: CNSSignal<TIn>, _ options: CNSStimulationOptions<TIn, TOut> = .init()) {
        let onResp = wrapOnResponse(options.onResponse)
        var queue: [Any] = [signal]
        var inFlight = 0
        var store: [String: Any] = [:]
        var activeSccCounts: [Int: Int] = [:]
        var hopCount = 0

        // Run-level concurrency gate
        var runGate: (limit: Int, active: Int, waiters: [() -> Void]) = (limit: max(0, options.runConcurrency ?? 0), active: 0, waiters: [])
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

        func notifyDebug(_ input: Any?, _ output: Any?, _ error: Error?) { /* removed */ }

        func incScc(for neuron: CNSNeuron) {
            if options.cancelToken?.isCancelled == true { return }
            if let idx = getSccIndexByNeuronName(neuron.name) {
                activeSccCounts[idx] = (activeSccCounts[idx] ?? 0) + 1
            }
        }
        func decSccAndMaybeCleanup(for neuron: CNSNeuron) {
            if let idx = getSccIndexByNeuronName(neuron.name) {
                activeSccCounts[idx] = max(0, (activeSccCounts[idx] ?? 0) - 1)
                if (options.cancelToken?.isCancelled != true) && (self.options?.autoCleanupContexts == true) {
                    if self.canNeuronBeGuaranteedDone(neuronName: neuron.name, activeSccCounts: activeSccCounts) {
                        store[neuron.name] = nil
                    }
                }
            }
        }

        // initial trace for input signal
        onResp(CNSAnyResponse(input: signal, output: nil, error: nil, queueLength: queue.count + inFlight))

        let wake = DispatchSemaphore(value: 0)
        while true {
            if options.cancelToken?.isCancelled == true { break }
            let anySig: Any
            if !queue.isEmpty {
                anySig = queue.removeFirst()
            } else if inFlight > 0 {
                wake.wait()
                continue
            } else { break }
            guard let sig = anySig as? CNSAnySignalProtocol else { continue }
            let subs = self.getSubscribers(collateralType: sig.collateralType)
            for (neuron, dendrite) in subs {
                if options.cancelToken?.isCancelled == true { continue }
                incScc(for: neuron)
                runWithRunConcurrency {
                    self.runWithConcurrency(neuron: neuron) {
                        let ctx = CNSLocalCtx(
                            get: { store[neuron.name] },
                            set: { v in store[neuron.name] = v },
                            abortToken: options.cancelToken,
                            cns: self
                        )
                        let out = dendrite.response(sig.payloadAny, neuron.axon, ctx)
                        func handleImmediate(_ val: Any?) {
                            self.releaseGate(for: neuron)
                            releaseRunGate()
                            defer { decSccAndMaybeCleanup(for: neuron) }
                            if let outSig = val as? CNSAnySignalProtocol {
                                hopCount += 1
                                let willAppend: Bool = {
                                    if let maxHops = options.maxHops { return hopCount <= maxHops }
                                    return true
                                }()
                                let nextQLen = (queue.count + inFlight) + (willAppend ? 1 : 0)
                                onResp(CNSAnyResponse(input: anySig, output: val, error: nil, queueLength: nextQLen))
                                if willAppend { queue.append(outSig) }
                            } else {
                                let nextQLen = queue.count + inFlight
                                onResp(CNSAnyResponse(input: anySig, output: nil, error: nil, queueLength: nextQLen))
                            }
                        }
                        if let ev = out as? CNSEventual {
                            switch ev {
                            case .immediate(let v):
                                handleImmediate(v)
                            case .future(let producer):
                                inFlight += 1
                                producer { v in
                                    (options.scheduler ?? self.scheduler).perform {
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
        onResp(CNSAnyResponse(input: nil, output: nil, error: nil, queueLength: 0))
    }

    // Convenience overloads to help type inference
    public func stimulate<TIn>(_ signal: CNSSignal<TIn>) {
        let opts = CNSStimulationOptions<TIn, Any>()
        self.stimulate(signal, opts)
    }

    public func stimulate<TIn, TOut>(_ signal: CNSSignal<TIn>, onResponse: ((_ r: CNSResponse<TIn, TOut>) -> Void)?) {
        let opts = CNSStimulationOptions<TIn, TOut>(onResponse: onResponse)
        self.stimulate(signal, opts)
    }
}


