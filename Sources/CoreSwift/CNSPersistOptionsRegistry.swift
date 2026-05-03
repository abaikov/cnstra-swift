import Foundation

// MARK: - TS `TCNSPersist`

public struct CNSNeuronPersistOptions {
    public var name: String
    public var neuron: CNSNeuron

    public init(name: String, neuron: CNSNeuron) {
        self.name = name
        self.neuron = neuron
    }
}

public struct CNSCollateralPersistOptions {
    public var name: String
    public var collateral: AnyObject

    public init(name: String, collateral: AnyObject) {
        self.name = name
        self.collateral = collateral
    }
}

public struct CNSStimulationPersistOptions {
    public var stimulationId: String

    public init(stimulationId: String) {
        self.stimulationId = stimulationId
    }
}

public typealias CNSStimulationSerializedContextValue = [String: Any]

// MARK: - TS `CNSPersistOptionsRegistry`

public final class CNSPersistOptionsRegistry {
    private var neurons: [String: CNSNeuron] = [:]
    private var neuronNames: [ObjectIdentifier: String] = [:]
    private var collaterals: [String: AnyObject] = [:]
    private var stimulations: [String: CNSStimulation] = [:]

    public init() {}

    public func addNeuron(_ neuron: CNSNeuron, options: CNSNeuronPersistOptions) {
        neurons[options.name] = neuron
        neuronNames[ObjectIdentifier(neuron)] = options.name
    }

    public func getNeuron(_ name: String) -> CNSNeuron? {
        neurons[name]
    }

    public func getNeuronName(_ neuron: CNSNeuron) -> String? {
        neuronNames[ObjectIdentifier(neuron)]
    }

    public func removeNeuron(_ name: String) {
        if let neuron = neurons[name] {
            neuronNames.removeValue(forKey: ObjectIdentifier(neuron))
        }
        neurons.removeValue(forKey: name)
    }

    public func addCollateral(_ collateral: AnyObject, options: CNSCollateralPersistOptions) {
        collaterals[options.name] = collateral
    }

    public func getCollateral(_ name: String) -> AnyObject? {
        collaterals[name]
    }

    public func removeCollateral(_ name: String) {
        collaterals.removeValue(forKey: name)
    }

    public func addStimulation(_ stimulation: CNSStimulation, options: CNSStimulationPersistOptions) {
        stimulations[options.stimulationId] = stimulation
    }

    public func getStimulation(_ stimulationId: String) -> CNSStimulation? {
        stimulations[stimulationId]
    }

    public func removeStimulation(_ stimulationId: String) {
        stimulations.removeValue(forKey: stimulationId)
    }
}
