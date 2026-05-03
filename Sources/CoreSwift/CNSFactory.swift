import Foundation

// MARK: - TS `factory/index` helpers

/// TS `collateral()` — identity-only collateral; `type` is an auto-generated debug label.
public func collateral<TPayload>() -> CNSCollateral<TPayload> {
    CNSCollateral<TPayload>()
}

/// TS `afferentPath(parent?)`
public func afferentPath(parent: CNSAfferentPath? = nil) -> CNSAfferentPath {
    CNSAfferentPath(parentAfferentPath: parent)
}

/// TS `modality({ ... })`
public func modality(afferentPaths: [AnyHashable: CNSAfferentPath]) -> CNSModality {
    CNSModality(afferentPaths: afferentPaths)
}

public typealias CNSModalityResultHandler<Result> = (_ payload: Any?, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Result
public typealias CNSModalityOutput<Result> = (_ result: Result, _ axon: CNSAxon, _ ctx: CNSLocalCtx) -> Any?

public struct CNSModalityDendriteConfig<Result> {
    public let modality: CNSModality
    public let afferentPaths: [CNSAfferentPath: CNSModalityResultHandler<Result>]
    public let defaultHandler: CNSModalityResultHandler<Result>?

    public init(
        modality: CNSModality,
        afferentPaths: [CNSAfferentPath: CNSModalityResultHandler<Result>] = [:],
        default defaultHandler: CNSModalityResultHandler<Result>? = nil
    ) {
        self.modality = modality
        self.afferentPaths = afferentPaths
        self.defaultHandler = defaultHandler
    }
}

/// TS `modalityDendrite(...)` helper.
///
/// Swift cannot model JS Promise return values directly here; async-style outputs should return `CNSEventual.future`.
public func modalityDendrite<Result>(
    collateral: AnyObject,
    modality singleModality: CNSModality,
    afferentPaths: [CNSAfferentPath: CNSModalityResultHandler<Result>] = [:],
    default defaultHandler: CNSModalityResultHandler<Result>? = nil,
    output: @escaping CNSModalityOutput<Result>
) -> CNSDendrite {
    modalityDendrite(
        collateral: collateral,
        modalities: [
            CNSModalityDendriteConfig(
                modality: singleModality,
                afferentPaths: afferentPaths,
                default: defaultHandler
            )
        ],
        default: defaultHandler,
        output: output
    )
}

private func makeModalityDendrite<Result>(
    collateral: AnyObject,
    modalities: [CNSModalityDendriteConfig<Result>],
    default globalDefaultHandler: CNSModalityResultHandler<Result>? = nil,
    output: @escaping CNSModalityOutput<Result>
) -> CNSDendrite {
    CNSDendrite(inputCollateral: collateral) { payload, axon, ctx in
        func runGlobalDefault() -> Any? {
            guard let globalDefaultHandler else {
                fatalError("modalityDendrite: No handler found for modality and no default handler provided")
            }
            return output(globalDefaultHandler(payload, axon, ctx), axon, ctx)
        }

        guard let stimModality = ctx.stimulation?.modality else {
            return runGlobalDefault()
        }

        guard let matchingConfig = modalities.first(where: { $0.modality == stimModality }) else {
            return runGlobalDefault()
        }

        let stimAfferentPath = ctx.stimulation?.afferentPath
        let handler: CNSModalityResultHandler<Result>? = {
            if let stimAfferentPath, let h = matchingConfig.afferentPaths[stimAfferentPath] {
                return h
            }
            return matchingConfig.defaultHandler ?? globalDefaultHandler
        }()

        guard let handler else {
            fatalError("modalityDendrite: No handler found for afferent path in modality and no default handler provided")
        }

        return output(handler(payload, axon, ctx), axon, ctx)
    }
}

/// TS `modalityDendrite({ modalities: [...] })` helper.
public func modalityDendrite<Result>(
    collateral: AnyObject,
    modalities: [CNSModalityDendriteConfig<Result>],
    default globalDefaultHandler: CNSModalityResultHandler<Result>? = nil,
    output: @escaping CNSModalityOutput<Result>
) -> CNSDendrite {
    makeModalityDendrite(
        collateral: collateral,
        modalities: modalities,
        default: globalDefaultHandler,
        output: output
    )
}

public final class CNSNeuronBuilder {
    public let axon: CNSAxon
    public private(set) var dendrites: [CNSDendrite] = []
    public private(set) var concurrency: Int?
    public private(set) var maxDurationMillis: Int?

    public init(axon: CNSAxon) {
        self.axon = axon
    }

    @discardableResult
    public func setConcurrency(_ n: Int?) -> CNSNeuronBuilder {
        concurrency = n
        return self
    }

    @discardableResult
    public func setMaxDuration(_ ms: Int?) -> CNSNeuronBuilder {
        maxDurationMillis = ms
        return self
    }

    @discardableResult
    public func dendrite(_ d: CNSDendrite) -> CNSNeuronBuilder {
        dendrites.append(d)
        return self
    }

    @discardableResult
    public func dendrite(collateral: AnyObject, response: @escaping CNSDendriteResponse) -> CNSNeuronBuilder {
        dendrites.append(CNSDendrite(inputCollateral: collateral, response: response))
        return self
    }

    @discardableResult
    public func dendrites(collaterals: [AnyObject], response: @escaping CNSDendriteResponse) -> CNSNeuronBuilder {
        for collateral in collaterals {
            dendrites.append(CNSDendrite(inputCollateral: collateral, response: response))
        }
        return self
    }

    @discardableResult
    public func bind(_ bindings: [(collateral: AnyObject, response: CNSDendriteResponse)]) -> CNSNeuronBuilder {
        for binding in bindings {
            dendrites.append(CNSDendrite(inputCollateral: binding.collateral, response: binding.response))
        }
        return self
    }

    @discardableResult
    public func modalityDendrite<Result>(
        collateral: AnyObject,
        modalities: [CNSModalityDendriteConfig<Result>],
        default globalDefaultHandler: CNSModalityResultHandler<Result>? = nil,
        output: @escaping CNSModalityOutput<Result>
    ) -> CNSNeuronBuilder {
        dendrites.append(
            makeModalityDendrite(
                collateral: collateral,
                modalities: modalities,
                default: globalDefaultHandler,
                output: output
            )
        )
        return self
    }

    public func build() -> CNSNeuron {
        CNSNeuron(
            axon: axon,
            dendrites: dendrites,
            concurrency: concurrency,
            maxDurationMillis: maxDurationMillis
        )
    }
}

/// TS `neuron(axon)` builder.
public func neuron(axon: CNSAxon) -> CNSNeuronBuilder {
    CNSNeuronBuilder(axon: axon)
}

public func neuron(
    axon: CNSAxon,
    dendrites: [CNSDendrite],
    concurrency: Int? = nil,
    maxDurationMillis: Int? = nil
) -> CNSNeuron {
    CNSNeuron(
        axon: axon,
        dendrites: dendrites,
        concurrency: concurrency,
        maxDurationMillis: maxDurationMillis
    )
}

/// Mirrors TS `withCtx<TContext>().neuron(...)` — `ContextValue` is documentation-only for port parity.
public enum WithCtx<ContextValue> {
    public static func neuron(
        axon: CNSAxon,
        dendrites: [CNSDendrite],
        concurrency: Int? = nil,
        maxDurationMillis: Int? = nil
    ) -> CNSNeuron {
        CNSNeuron(
            axon: axon,
            dendrites: dendrites,
            concurrency: concurrency,
            maxDurationMillis: maxDurationMillis
        )
    }
}
