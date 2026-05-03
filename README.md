# CNStra - Swift SDK

Graph-routed, type-safe orchestration for Swift apps. No global event bus, no string routing.

This package is a Swift port of the core ideas from the original [CNStra TypeScript library](https://www.npmjs.com/package/@cnstra/core) ([GitHub](https://github.com/abaikov/cnstra)).

## What Is CNStra?

CNStra models a workflow as a graph of neurons.

A run starts with `cns.stimulate(...)`. CNStra looks at the signal's collateral object, finds dendrites subscribed to that exact collateral instance, runs their response closures, and routes any returned signals to the next matching dendrites.

- Routing is by **collateral object identity**, not by string names.
- A dendrite continues the graph only by returning a `CNSSignal`.
- Returning `nil` ends that branch.
- Multiple outputs are supported by returning an array of signals.
- Per-neuron and per-run concurrency gates are available.

## Core Model

### Collateral

A `CNSCollateral<Payload>` is a typed channel object. It has no name or string type.

```swift
let userCreated = CNSCollateral<(id: String, name: String)>()
let userRegistered = CNSCollateral<(userId: String, status: String)>()

let signal = userCreated.createSignal((id: "123", name: "Ada"))
```

### Signal

A `CNSSignal<Payload>` carries:

- `collateral`: the exact collateral object that created the signal
- `payload`: optional typed payload

```swift
let s = userRegistered.createSignal((userId: "123", status: "completed"))
print(s.collateral === userRegistered) // true
```

### Axon

A `CNSAxon` declares which collateral instances a neuron may emit. The graph builder uses this to calculate reachability and SCC cleanup.

```swift
let output = CNSCollateral<String>()
let axon = CNSAxon(output)

// You can add more later if needed.
let error = CNSCollateral<Error>()
axon.register(error)
```

There is intentionally no dynamic member lookup and no string lookup.

### Dendrite

A `CNSDendrite` subscribes to one input collateral and returns zero, one, or many output signals.

```swift
let input = CNSCollateral<Int>()
let output = CNSCollateral<String>()

let dendrite = CNSDendrite(inputCollateral: input) { (value: Int?, _, ctx) in
    guard let value else { return nil }

    let previous = (ctx.get() as? Int) ?? 0
    ctx.set(previous + value)

    return output.createSignal("sum=\(previous + value)")
}
```

### Neuron

A `CNSNeuron` has no runtime name. Persist/debug labels live outside the core model.

```swift
let neuron = CNSNeuron(
    axon: CNSAxon(output),
    dendrites: [dendrite],
    concurrency: 2
)
```

## Quick Start

```swift
import CNStra

let userCreated = CNSCollateral<(id: String, name: String)>()
let userRegistered = CNSCollateral<(userId: String, status: String)>()

let userService = CNSNeuron(
    axon: CNSAxon(userRegistered),
    dendrites: [
        CNSDendrite(inputCollateral: userCreated) { payload, _, _ in
            guard let payload else { return nil }
            return userRegistered.createSignal((
                userId: payload.id,
                status: "completed"
            ))
        }
    ]
)

let cns = CNS([userService])

_ = cns.stimulate(userCreated.createSignal((id: "123", name: "Ada")))
```

## CNS And Responses

```swift
let unsubscribe = cns.addResponseListener { response in
    if let output = response.outputSignal {
        print("output:", output)
    }

    if response.queueLength == 0 {
        print("done")
    }
}
```

`CNSResponse<TIn, TOut>` and `CNS.CNSAnyResponse` expose:

- `inputSignal`
- `outputSignal`
- `error`
- `queueLength`
- `modality`
- `afferentPath`
- `contextValue`
- `hops`
- `stimulation`

## Stimulation Options

```swift
let abort = CNSCancellationToken()

let opts = CNSStimulationOptions<Int, String>(
    onResponse: { r in
        if let error = r.error {
            print("error:", error)
        }
    },
    abortSignal: abort,
    maxNeuronHops: 10,
    concurrency: 4,
    continuationScheduler: CNSSerialScheduler()
)

_ = cns.stimulate(input.createSignal(5), opts)
```

Options:

- `onResponse`: local response listener for the run
- `abortSignal`: cancellation signal
- `maxNeuronHops`: maximum visits per neuron during a run
- `concurrency`: per-run concurrency gate
- `ctx`: custom `CNSStimulationContextStoreProtocol`
- `modality`: selected modality object
- `afferentPath`: selected afferent path object
- `stimulationContext`: arbitrary user context
- `continuationScheduler`: where `CNSEventual.future` completion callbacks are accepted before CNS resumes them on its serial stimulation lane

Global options:

```swift
let cns = CNS(
    [neuron],
    options: CNSOptions(autoCleanupContexts: true)
)
```

## Execution Model

CNStra keeps orchestration serial by default. A `CNS` instance runs routing, context mutation, activation task state, cleanup, and response listeners on one stimulation lane.

This is intentional: dendrites should be small orchestration steps. If a dendrite needs CPU-heavy or blocking work, move that work outside CNS with Swift concurrency or a queue, then return the result through `CNSEventual.future`.

```swift
return CNSEventual.future { complete in
    Task.detached {
        let result = expensiveWork()
        complete(output.createSignal(result))
    }
}
```

Future completion callbacks may arrive from any thread. CNS accepts them through the configured `continuationScheduler`, then drains the resulting signals back on the same serial stimulation lane.

## Signal Flow Patterns

### Chain

```swift
let input = CNSCollateral<(value: Int)>()
let middle = CNSCollateral<(doubled: Int)>()
let output = CNSCollateral<(result: String)>()

let step1 = CNSNeuron(
    axon: CNSAxon(middle),
    dendrites: [
        CNSDendrite(inputCollateral: input) { payload, _, _ in
            guard let payload else { return nil }
            return middle.createSignal((doubled: payload.value * 2))
        }
    ]
)

let step2 = CNSNeuron(
    axon: CNSAxon(output),
    dendrites: [
        CNSDendrite(inputCollateral: middle) { payload, _, _ in
            guard let payload else { return nil }
            return output.createSignal((result: "Final: \(payload.doubled)"))
        }
    ]
)

let cns = CNS([step1, step2])
_ = cns.stimulate(input.createSignal((value: 5)))
```

### Fan-Out

```swift
let trigger = CNSCollateral<String>()
let branch1 = CNSCollateral<String>()
let branch2 = CNSCollateral<String>()

let proc1 = CNSNeuron(
    axon: CNSAxon(branch1),
    dendrites: [
        CNSDendrite(inputCollateral: trigger) { payload, _, _ in
            guard let payload else { return nil }
            return branch1.createSignal("A-\(payload)")
        }
    ]
)

let proc2 = CNSNeuron(
    axon: CNSAxon(branch2),
    dendrites: [
        CNSDendrite(inputCollateral: trigger) { payload, _, _ in
            guard let payload else { return nil }
            return branch2.createSignal("B-\(payload)")
        }
    ]
)

let cns = CNS([proc1, proc2])
_ = cns.stimulate(trigger.createSignal("test"))
```

### Multiple Outputs From One Dendrite

```swift
let trigger = CNSCollateral<String>()
let log = CNSCollateral<String>()
let metric = CNSCollateral<Int>()

let neuron = CNSNeuron(
    axon: CNSAxon(log, metric),
    dendrites: [
        CNSDendrite(inputCollateral: trigger) { payload, _, _ in
            guard let payload else { return nil }
            return [
                log.createSignal("received \(payload)"),
                metric.createSignal(payload.count)
            ]
        }
    ]
)
```

## Context And Cancellation

Each neuron gets a local context slot for the current stimulation.

```swift
let increment = CNSCollateral<Int>()
let count = CNSCollateral<Int>()
let abort = CNSCancellationToken()

let counter = CNSNeuron(
    axon: CNSAxon(count),
    dendrites: [
        CNSDendrite(inputCollateral: increment) { payload, _, ctx in
            guard ctx.abortSignal?.isAborted != true else { return nil }

            let current = (ctx.get() as? Int) ?? 0
            let next = current + (payload ?? 0)
            ctx.set(next)

            return count.createSignal(next)
        }
    ]
)

let cns = CNS([counter])
_ = cns.stimulate(
    increment.createSignal(5),
    CNSStimulationOptions<Int, Int>(abortSignal: abort)
)
```

For external context snapshots, use `CNSStimulationContextStore`:

```swift
let store = CNSStimulationContextStore()
let key = NSObject()

store.set(key: key, value: "cached")
let snapshot = store.getAll()
store.setAll(snapshot)
```

## Async Work

Dendrite closures are synchronous, but they can return `CNSEventual.future` to complete later.

```swift
let input = CNSCollateral<Int>()
let output = CNSCollateral<String>()

let worker = CNSNeuron(
    axon: CNSAxon(output),
    dendrites: [
        CNSDendrite(inputCollateral: input) { value, _, _ in
            guard let value else { return nil }

            return CNSEventual.future { complete in
                Task.detached {
                    let text = "value=\(value)"
                    complete(output.createSignal(text))
                }
            }
        }
    ]
)
```

`continuationScheduler` controls where future completion callbacks are accepted. CNS then drains those completions back on the stimulation lane, so routing, context mutation, task state, and response listeners stay serial.

```swift
let opts = CNSStimulationOptions<Int, String>(
    continuationScheduler: CNSSerialScheduler()
)
```

## Modality And Afferent Path

`modalityDendrite` mirrors the TypeScript factory helper: handler selection is by object identity.

```swift
let input = CNSCollateral<String>()
let output = CNSCollateral<String>()

let mobile = modality(afferentPaths: [:])
let pushPath = afferentPath()

let d = modalityDendrite(
    collateral: input,
    modality: mobile,
    afferentPaths: [
        pushPath: { payload, _, _ in
            "push:\(payload as? String ?? "")"
        }
    ],
    default: { payload, _, _ in
        "default:\(payload as? String ?? "")"
    },
    output: { result, _, _ in
        output.createSignal(result)
    }
)

let n = CNSNeuron(axon: CNSAxon(output), dendrites: [d])
let cns = CNS([n])

_ = cns.stimulate(
    input.createSignal("hello"),
    CNSStimulationOptions<String, String>(
        modality: mobile,
        afferentPath: pushPath
    )
)
```

## Factory Helpers

```swift
let input: CNSCollateral<Int> = collateral()
let output: CNSCollateral<String> = collateral()

let builder = neuron(axon: CNSAxon(output))
    .setConcurrency(2)
    .dendrite(collateral: input) { payload, _, _ in
        guard let payload = payload as? Int else { return nil }
        return output.createSignal("value=\(payload)")
    }

let n = builder.build()
```

## Drain Guard

`CNSDrainGuard` starts a stimulation and tracks its drain state. If no `abortSignal` is provided, it owns a `CNSCancellationToken`.

```swift
let guarder = CNSDrainGuard<Int, String>(
    cns: cns,
    signal: input.createSignal(1)
)

await guarder.drain()
print(guarder.isDraining()) // false
```

## Persistence Registry

Runtime neurons and collaterals remain identity-only. Persist names are external labels.

```swift
let registry = CNSPersistOptionsRegistry()
registry.addNeuron(neuron, options: CNSNeuronPersistOptions(name: "worker", neuron: neuron))
registry.addCollateral(output, options: CNSCollateralPersistOptions(name: "output", collateral: output))
```

## Topology And Performance

`CNSNetwork` builds indexes once at initialization:

- subscribers by collateral identity
- parent neuron by collateral identity
- strongly connected components
- SCC DAG ancestry for safe context cleanup

```swift
let subscribers = cns.network.getSubscribers(collateral: input)
let parent = cns.network.getParentNeuron(forCollateral: output)
```

Performance notes:

- Routing is identity-based and deterministic.
- CNS runs routing, context mutation, task state, and listeners on one serial stimulation lane.
- `CNSEventual.future` lets user code do work elsewhere and posts the result back into the same run.
- `concurrency` on `CNSNeuron` gates work for that neuron across runs.
- `CNSStimulationOptions.concurrency` gates work inside a single run.
- `autoCleanupContexts` can reduce retained context values in larger cyclic graphs.

Run the optional release-mode routing smoke test with:

```bash
CNS_PERF_SMOKE=1 swift test -c release --filter CoreSwiftTests/testPerfSmokeRoutingThroughput
```

Run the optional deep-chain stack smoke test with:

```bash
CNS_DEEP_STACK_SMOKE=1 swift test -c release --filter CoreSwiftTests/testDeepSignalChainDoesNotOverflowCallStack
```

## Error Handling

Throwing dendrites can route errors to a typed error collateral.

```swift
enum WorkerError: Error {
    case failed
}

let input = CNSCollateral<Int>()
let error = CNSCollateral<WorkerError>()

let d = CNSDendrite(
    inputCollateral: input,
    errorCollateral: error
) { (value: Int, _, _) in
    throw WorkerError.failed
}
```

You can also inspect task failures after a run:

```swift
let stimulation = cns.stimulate(
    input.createSignal(1),
    CNSStimulationOptions<Int, Int>(maxNeuronHops: 1)
)

let failed = stimulation.getFailedTasks()
```

## SwiftPM Versioning

SwiftPM package versions are git tags. `Package.swift` does not contain the library version.

After a release commit, run the release script with the next semver version:

```bash
scripts/release.sh 1.1.0
```

The script requires a clean working tree, fast-forwards `master` to the current commit, runs `swift test`, pushes `master`, then creates and pushes the annotated tag.

---

CNStra provides deterministic, typed orchestration without string-routed event buses.
