# CNStraSwift

Graph-routed, type-safe orchestration for reactive Swift apps — no global event bus.

This is a Swift implementation of the original [CNStra TypeScript library](https://www.npmjs.com/package/@cnstra/core) ([GitHub](https://github.com/abaikov/cnstra)).

## 🧠 What is CNStraSwift?

CNStraSwift models your app as a typed neuron graph.
You explicitly start a run with `cns.stimulate(...)`; CNStra then performs a deterministic, hop-bounded traversal from collateral → dendrite → returned signal, step by step.

- Zero dependencies: suitable for iOS, macOS, tvOS, watchOS, server-side Swift.
- Not pub/sub: there are no ambient listeners or global emit. Only the signal you return from a dendrite continues the traversal; returning `nil` ends that branch.

## 💡 Why CNStra

We follow ERG (Event → Reaction → Graph), not a raw Flux/event-bus.

- Deterministic routing: signals are delivered along an explicit neuron graph, not broadcast to whoever “happens to listen”.
- Readable, reliable flows: each step is local and typed; branches are explicit; debugging is straightforward.
- Backpressure & concurrency: built‑in per‑neuron concurrency limits keep workloads controlled.
- Saga‑grade orchestration: ERG models long‑running, multi‑step reactions with cancel hooks, so you rarely need to hand‑roll “sagas”.
- Safer than ad‑hoc events: no hidden global listeners; every continuation must be returned explicitly.

## 🏗️ Core Model

### Neurons
Units of logic with clear DI and boundaries:

- Name — unique `name`
- Axon — the neuron's output channels (its collaterals)
- Dendrites — input receptors (typed reactions bound to specific collaterals)

### Collaterals
Typed output channels that mint signals:

- Type — string identifier (e.g., "user:created")
- Payload — the data carried by the signal
- `createSignal(payload)` → `CNSSignal<Payload>`

### Signals
The data structures that flow through the system:

- `collateralType` — string type of the collateral that created this signal
- `payload` — the typed data being transmitted

## 🚀 Quick Start

Add CNStraSwift as a SwiftPM dependency and import the module where needed.

```swift
import CNStraSwift

// Define collaterals (communication channels)
let userCreated = CNSCollateral<(id: String, name: String)>("user:created")
let userRegistered = CNSCollateral<(userId: String, status: String)>("user:registered")

// Create axon via DSL
let axon = CNSAxon.make { def in
    def.userRegistered((userId: String, status: String).self)
}

// Create a neuron
let userService = CNSNeuron(
    name: "user-service",
    axon: axon,
    dendrites: [
        CNSDendrite(inputCollateral: userCreated) { payload, axon, _ in
            guard let p = payload else { return nil }
            return axon.userRegistered.createSignal((userId: p.id, status: "completed"))
        }
    ]
)

// Create the CNS system
let cns = CNS([userService])

// Stimulate the system
cns.stimulate(userCreated.createSignal((id: "123", name: "John Doe")))
```

## 📚 API Reference

### Collateral

```swift
let userEvent = CNSCollateral<(userId: String)>("user:event")
let simpleEvent = CNSCollateral<Void>("simple:event")
```

### Axon DSL and access

```swift
let axon = CNSAxon.make { def in
    def.output(String.self)
    def.count(Int.self)
}

// Dynamic member access
// Force (throws fatalError if not registered):
let forced: CNSCollateral<String> = axon.output
// Safe (optional):
let safe: CNSCollateral<String>? = axon.safe.output
```

### Neuron and Dendrite

```swift
let input = CNSCollateral<Int>("input")
let axon = CNSAxon.make { def in def.output(String.self) }

let neuron = CNSNeuron(
    name: "worker",
    axon: axon,
    dendrites: [
        CNSDendrite(inputCollateral: input) { payload, axon, ctx in
            guard let v = payload else { return nil }
            // Context example
            let prev = (ctx.get() as? Int) ?? 0
            ctx.set(prev + v)
            return axon.output.createSignal("sum=\(prev + v)")
        }
    ]
)
```

### CNS

```swift
// Global listener
_ = cns.addResponseListener { r in
    // r.input, r.output, r.error, r.queueLength
}

// Options
// - autoCleanupContexts: enable SCC-based context cleanup
// - scheduler: CNSSyncScheduler (default) or CNSAsyncScheduler for background execution
let cns = CNS([neuron], options: CNSOptions(autoCleanupContexts: true, scheduler: CNSSyncScheduler()))
```

### stimulate

```swift
// Simple
cns.stimulate(input.createSignal(5))

// With local onResponse and cancel token
let token = CNSCancellationToken()
let opts = CNSStimulationOptions<Int, String>(
    onResponse: { r in
        if let err = r.error { print("error: \(err)") }
        if let out = r.output { print("signal: \(out.collateralType)") }
        if r.queueLength == 0 { print("done") }
    },
    cancelToken: token
)
cns.stimulate(input.createSignal(5), opts)
```

## ⚙️ Stimulation Options (Swift)

- `onResponse: (CNSResponse<TIn, TOut>) -> Void` — unified callback with `input`, `output`, `error`, `queueLength`.
- `cancelToken: CNSCancellationToken?` — graceful stop for the current stimulation.
- `maxHops: Int?` — limit total hop count in the run.
- `runConcurrency: Int?` — run-level concurrency gate.
- `CNSOptions(autoCleanupContexts: Bool, scheduler: CNSScheduler?)` — SCC cleanup and execution policy.

### Scheduling (Sync vs Async)

What it is
- Chooses where CNSEventual.future completions run before they’re queued back into the same run.
- Sync: handle on current thread. Async: handle on background queue.

What it’s not
- No new processes/runs. No implicit UI hops (do `DispatchQueue.main.async` yourself).
- Gates still apply: per‑neuron `concurrency`, `runConcurrency`.

When to pick
- Sync (default): UI/model‑centric flows; predictable in‑thread handling.
- Async: many IO‑heavy futures; keep completion handling off the current thread.

How to set
```swift
// Global
let cns = CNS(neurons, options: CNSOptions(scheduler: CNSSyncScheduler()))
let cnsAsync = CNS(neurons, options: CNSOptions(scheduler: CNSAsyncScheduler()))

// Per run override
let opts = CNSStimulationOptions<Input, Output>(scheduler: CNSAsyncScheduler(), runConcurrency: 4)
cns.stimulate(input.createSignal(...), opts)
```

Typical pattern (heavy off-main, UI on main)
```swift
let d = CNSDendrite(inputCollateral: input) { (v: Int?, ax, _) in
  guard let v else { return nil }
  return CNSEventual.future { complete in
    Task.detached {
      let text = try? await api.fetchText(id: v)
      DispatchQueue.main.async { complete(ax.done.createSignal(text ?? "")) }
    }
  }
}
```

## 🔄 Signal Flow Patterns

### Basic Chain

```swift
let input = CNSCollateral<(value: Int)>("input")
let middle = CNSCollateral<(doubled: Int)>("middle")
let output = CNSCollateral<(result: String)>("output")

let ax1 = CNSAxon.make { def in def.middle((doubled: Int).self) }
let ax2 = CNSAxon.make { def in def.output((result: String).self) }

let step1 = CNSNeuron(name: "step1", axon: ax1, dendrites: [
    CNSDendrite(inputCollateral: input) { p, axon, _ in
        guard let v = p else { return nil }
        return axon.middle.createSignal((doubled: v.value * 2))
    }
])

let step2 = CNSNeuron(name: "step2", axon: ax2, dendrites: [
    CNSDendrite(inputCollateral: middle) { p, axon, _ in
        guard let v = p else { return nil }
        return axon.output.createSignal((result: "Final: \(v.doubled)"))
    }
])

let cns = CNS([step1, step2])
cns.stimulate(input.createSignal((value: 5)))
```

### Fan‑out

```swift
let trigger = CNSCollateral<(data: String)>("trigger")
let branch1 = CNSCollateral<(result: String)>("branch1")
let branch2 = CNSCollateral<(result: String)>("branch2")

let ax1 = CNSAxon.make { def in def.branch1((result: String).self) }
let ax2 = CNSAxon.make { def in def.branch2((result: String).self) }

let proc1 = CNSNeuron(name: "proc1", axon: ax1, dendrites: [
    CNSDendrite(inputCollateral: trigger) { p, axon, _ in
        guard let v = p else { return nil }
        return axon.branch1.createSignal((result: "A-\(v.data)"))
    }
])

let proc2 = CNSNeuron(name: "proc2", axon: ax2, dendrites: [
    CNSDendrite(inputCollateral: trigger) { p, axon, _ in
        guard let v = p else { return nil }
        return axon.branch2.createSignal((result: "B-\(v.data)"))
    }
])

let cns = CNS([proc1, proc2])
cns.stimulate(trigger.createSignal((data: "test")))

// If you need background execution for heavy/IO work:
// let cns = CNS([proc1, proc2], options: CNSOptions(scheduler: CNSAsyncScheduler()))
```

### Context‑Aware with Abort

```swift
let input = CNSCollateral<(increment: Int)>("input")
let output = CNSCollateral<(count: Int)>("output")
let ax = CNSAxon.make { def in def.output((count: Int).self) }

let counter = CNSNeuron(name: "counter", axon: ax, dendrites: [
    CNSDendrite(inputCollateral: input) { payload, axon, ctx in
        if ctx.abortToken?.isCancelled == true { return nil }
        let current = (ctx.get() as? Int) ?? 0
        let newTotal = current + (payload?.increment ?? 0)
        ctx.set(newTotal)
        return axon.output.createSignal((count: newTotal))
    }
])

let cns = CNS([counter])
cns.stimulate(input.createSignal((increment: 5)))
```

## 🧠 Topology & Performance

- Subscriber/owner indexes: `getSubscribers`, `getParentNeuronByCollateralType`.
- Strongly Connected Components (SCC): Tarjan SCC, SCC DAG, ancestor precompute.
- `getSCCSetByNeuronName`, `getSccIndexByNeuronName`, `canNeuronBeGuaranteedDone`.
- Auto context cleanup (optional) based on SCC.

Performance notes:

- Sync‑first core. `CNSEventual.future` is non‑blocking; results are posted back into the same run deterministically.
- Per‑neuron concurrency gates to prevent resource exhaustion.
- SCC building has overhead; enable `autoCleanupContexts` only when memory pressure warrants it.

When to pick a scheduler:
- Use `CNSSyncScheduler` (default) for UI/model updates on main and small flows.
- Use `CNSAsyncScheduler` for fan‑out network/IO heavy steps; combine with per‑neuron `concurrency` and `runConcurrency`.

## 🚨 Error Handling

Errors are delivered via `onResponse.error`. Alternatively, use throwing dendrites with typed error collaterals.

```swift
let opts = CNSStimulationOptions<Int, String>(onResponse: { r in
    if let err = r.error { print("Error: \(err)") }
})
```

## 🔧 Advanced Configuration

```swift
// Auto cleanup contexts (SCC-based) + Async scheduler
let cns = CNS(neurons, options: CNSOptions(autoCleanupContexts: true, scheduler: CNSAsyncScheduler()))

// Per-neuron concurrency
let n = CNSNeuron(name: "worker", axon: ax, dendrites: ds, concurrency: 2)
```

---

CNStraSwift provides deterministic, type‑safe orchestration without the complexity of traditional event systems. Build reliable, maintainable reactive applications with clear data flow and predictable behavior.
