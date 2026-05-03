import Foundation

// MARK: - TS `CNSDrainGuard`

public enum CNSDrainGuardSignal<TPayload> {
    case signal(CNSSignal<TPayload>)
    case signals([CNSSignal<TPayload>])
}

public struct CNSDrainGuardOptions<TIn, TOut> {
    public var cns: CNS
    public var signal: CNSDrainGuardSignal<TIn>
    public var options: CNSStimulationOptions<TIn, TOut>?

    public init(
        cns: CNS,
        signal: CNSDrainGuardSignal<TIn>,
        options: CNSStimulationOptions<TIn, TOut>? = nil
    ) {
        self.cns = cns
        self.signal = signal
        self.options = options
    }
}

public final class CNSDrainGuard<TIn, TOut> {
    private let guardOptions: CNSDrainGuardOptions<TIn, TOut>
    private var currentStimulation: CNSStimulation?
    private var currentDrain: Task<Void, Never>?
    private var currentAbortController: CNSCancellationToken?

    public init(_ guardOptions: CNSDrainGuardOptions<TIn, TOut>) {
        self.guardOptions = guardOptions
    }

    public convenience init(cns: CNS, signal: CNSSignal<TIn>, options: CNSStimulationOptions<TIn, TOut>? = nil) {
        self.init(CNSDrainGuardOptions(cns: cns, signal: .signal(signal), options: options))
    }

    public convenience init(cns: CNS, signals: [CNSSignal<TIn>], options: CNSStimulationOptions<TIn, TOut>? = nil) {
        self.init(CNSDrainGuardOptions(cns: cns, signal: .signals(signals), options: options))
    }

    public func isDraining() -> Bool {
        currentDrain != nil
    }

    public func getCurrentStimulation() -> CNSStimulation? {
        currentStimulation
    }

    public func drain() async {
        if let currentDrain {
            await currentDrain.value
            return
        }

        let stimulation = guardOptions.cns.stimulate(
            guardOptions.signal,
            createStimulationOptions()
        )

        let drain = Task { await stimulation.waitUntilComplete() }
        currentStimulation = stimulation
        currentDrain = drain
        await drain.value

        currentDrain = nil
        currentStimulation = nil
        currentAbortController = nil
    }

    @discardableResult
    public func abort() -> Bool {
        guard let currentAbortController, !currentAbortController.isAborted else { return false }
        currentAbortController.cancel()
        return true
    }

    private func createStimulationOptions() -> CNSStimulationOptions<TIn, TOut> {
        guard var options = guardOptions.options else {
            let token = CNSCancellationToken()
            currentAbortController = token
            return CNSStimulationOptions<TIn, TOut>(abortSignal: token)
        }

        if options.abortSignal != nil {
            return options
        }

        let token = CNSCancellationToken()
        currentAbortController = token
        options.abortSignal = token
        return options
    }
}

private extension CNS {
    func stimulate<TIn, TOut>(
        _ signalOrSignals: CNSDrainGuardSignal<TIn>,
        _ options: CNSStimulationOptions<TIn, TOut>
    ) -> CNSStimulation {
        switch signalOrSignals {
        case .signal(let signal):
            return stimulate(signal, options)
        case .signals(let signals):
            return stimulate(signals, options)
        }
    }
}
