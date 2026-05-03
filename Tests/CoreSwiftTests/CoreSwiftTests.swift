import XCTest
@testable import CNStra

final class CoreSwiftTests: XCTestCase {
    func testBasicFlow() {
        let input = CNSCollateral<String>()
        let output = CNSCollateral<String>()
        let axon = CNSAxon(output)

        let d = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return output.createSignal(stringPayload)
        }
        let n = CNSNeuron(axon: axon, dendrites: [d])
        let cns = CNS([n])

        var seen: [ObjectIdentifier] = []
        _ = cns.addResponseListener { r in
            if let o = r.outputSignal as? CNSSignal<String> { seen.append(ObjectIdentifier(o.collateral)) }
            else if let i = r.inputSignal as? CNSSignal<String> { seen.append(ObjectIdentifier(i.collateral)) }
        }
        _ = cns.stimulate(input.createSignal("hi"))
        XCTAssertEqual(seen, [ObjectIdentifier(input), ObjectIdentifier(output)])
    }

    func testComplexPayloadsAndDebugOrder() {
        struct User { let id: Int; let name: String }
        struct Profile { let id: Int; let nickname: String }
        let input = CNSCollateral<User>()
        let profile = CNSCollateral<Profile>()
        let log = CNSCollateral<String>()
        let axon = CNSAxon(profile, log)
        let d1 = CNSDendrite(inputCollateral: input) { (payload: User?, _, _) in
            guard let u = payload else { return nil }
            return profile.createSignal(Profile(id: u.id, nickname: u.name.lowercased()))
        }
        let d2 = CNSDendrite(inputCollateral: profile) { (payload: Profile?, _, _) in
            guard let p = payload else { return nil }
            return log.createSignal("profile: #\(p.id) \(p.nickname)")
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d1, d2])])

        var seen: [String] = []
        var lastQueueLengths: [Int] = []
        _ = cns.addResponseListener { r in
            if r.outputSignal is CNSSignal<Profile> { seen.append("profile:") }
            if r.outputSignal is CNSSignal<String> { seen.append("log:") }
            lastQueueLengths.append(r.queueLength)
        }
        _ = cns.stimulate(input.createSignal(User(id: 1, name: "Andrei")))
        XCTAssertEqual(seen, ["profile:", "log:"])
        // queueLength should be 0 only on the last response
        XCTAssertTrue(lastQueueLengths.last == 0)
        XCTAssertTrue(lastQueueLengths.dropLast().allSatisfy { $0 > 0 })
    }

    func testAbortSignals() {
        let input = CNSCollateral<Int>()
        let out = CNSCollateral<String>()
        let axon = CNSAxon(out)
        let cancel = CNSCancellationToken()
        var passed = false
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, _, ctx) in
            guard let v = p else { return nil }
            if v == 1 { (ctx.abortSignal as? CNSCancellationToken)?.cancel() }
            passed = true
            return out.createSignal("x")
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])
        let opts = CNSStimulationOptions<Int, String>(onResponse: nil, abortSignal: cancel)
        _ = cns.stimulate(input.createSignal(1), opts)
        // We cancelled quickly; handler ran, but no further queue appends
        XCTAssertTrue(passed)
    }

    func testContextPropagation() {
        let input = CNSCollateral<Int>()
        let mid = CNSCollateral<Int>()
        let out = CNSCollateral<Int>()
        let axon = CNSAxon(mid, out)
        let d1 = CNSDendrite(inputCollateral: input) { (p: Int?, _, ctx) in
            ctx.set( (p ?? 0) + 1 )
            return mid.createSignal((p ?? 0) + 10)
        }
        let d2 = CNSDendrite(inputCollateral: mid) { (p: Int?, _, ctx) in
            let local = (ctx.get() as? Int) ?? -1
            return out.createSignal((p ?? 0) + local)
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d1, d2])])
        var result: Int?
        _ = cns.addResponseListener { r in if let o = r.outputSignal as? CNSSignal<Int> { result = o.payload } }
        _ = cns.stimulate(input.createSignal(5))
        XCTAssertEqual(result, 5 + 10 + (5 + 1))
    }

    func testConcurrencyWithinRun() {
        let input = CNSCollateral<Int>()
        let mid = CNSCollateral<Int>()
        let out = CNSCollateral<Int>()
        let axon = CNSAxon(mid, out)
        let d1 = CNSDendrite(inputCollateral: input) { (p: Int?, _, _) in
            return mid.createSignal((p ?? 0))
        }
        let d2 = CNSDendrite(inputCollateral: mid) { (p: Int?, _, _) in
            return out.createSignal((p ?? 0))
        }
        let n = CNSNeuron(axon: axon, dendrites: [d1, d2], concurrency: 1)
        let cns = CNS([n])
        var count = 0
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<Int>, s.collateral !== input { count += 1 }
        }
        _ = cns.stimulate(input.createSignal(1))
        XCTAssertEqual(count, 2)
    }

    func testConcurrencyAcrossMultipleRuns() {
        let input = CNSCollateral<Int>()
        let out = CNSCollateral<Int>()
        let axon = CNSAxon(out)
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, _, _) in
            return out.createSignal((p ?? 0))
        }
        let n = CNSNeuron(axon: axon, dendrites: [d], concurrency: 1)
        let cns = CNS([n])
        var total = 0
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<Int>, s.collateral !== input { total += s.payload ?? 0 }
        }
        for i in 0..<100 { _ = cns.stimulate(input.createSignal(i)) }
        XCTAssertEqual(total, (0..<100).reduce(0,+))
    }
    
    func testTypeSafeDendrite() {
        let input = CNSCollateral<String>()
        let output = CNSCollateral<Int>()
        let axon = CNSAxon(output)
        let d = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return output.createSignal(stringPayload.count)
        }
        
        let n = CNSNeuron(axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var result: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.outputSignal as? CNSSignal<Int> {
                result = outputSignal.payload
            }
        }
        
        _ = cns.stimulate(input.createSignal("hello"))
        XCTAssertEqual(result, 5) // "hello" has 5 characters
    }
    
    func testDendriteWithAxonCollateralAccess() {
        let input = CNSCollateral<String>()
        let output = CNSCollateral<String>()
        let axon = CNSAxon(output)
        let d = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return output.createSignal("processed: \(stringPayload)")
        }
        
        let n = CNSNeuron(axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var result: String?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.outputSignal as? CNSSignal<String> {
                result = outputSignal.payload
            }
        }
        
        _ = cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(result, "processed: test")
    }
    
    func testMultipleAxonCollaterals() {
        let input = CNSCollateral<String>()
        let stringOutput = CNSCollateral<String>()
        let intOutput = CNSCollateral<Int>()
        let axon = CNSAxon(stringOutput, intOutput)
        let d = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return stringOutput.createSignal("processed: \(stringPayload)")
        }
        
        let n = CNSNeuron(axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.outputSignal as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.outputSignal as? CNSSignal<Int> {
                intResult = outputSignal.payload
            }
        }
        
        _ = cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(stringResult, "processed: test")
        XCTAssertNil(intResult) // No int output in this case
    }
    
    func testMultipleOutputCollaterals() {
        let input = CNSCollateral<String>()
        let stringOutput = CNSCollateral<String>()
        let intOutput = CNSCollateral<Int>()
        let axon = CNSAxon(stringOutput, intOutput)
        let stringDendrite = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return stringOutput.createSignal("string: \(stringPayload)")
        }
        let intDendrite = CNSDendrite(inputCollateral: input) { (payload: String?, _, _) in
            guard let stringPayload = payload else { return nil }
            return intOutput.createSignal(stringPayload.count)
        }
        
        let n = CNSNeuron(axon: axon, dendrites: [stringDendrite, intDendrite])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.outputSignal as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.outputSignal as? CNSSignal<Int> {
                intResult = outputSignal.payload
            }
        }
        
        _ = cns.stimulate(input.createSignal("hello"))
        XCTAssertEqual(stringResult, "string: hello")
        XCTAssertEqual(intResult, 5)
    }
    
    func testDendriteUsingMultipleAxonCollaterals() {
        let input = CNSCollateral<String>()
        let stringOutput = CNSCollateral<String>()
        let intOutput = CNSCollateral<Int>()
        let boolOutput = CNSCollateral<Bool>()
        let axon = CNSAxon(stringOutput, intOutput, boolOutput)
        let d = CNSDendrite(inputCollateral: input) { (payload: String?, axon, _) in
            guard let stringPayload = payload else { return nil }
            if axon.contains(stringOutput) {
                return stringOutput.createSignal("processed: \(stringPayload)")
            } else if axon.contains(intOutput) {
                return intOutput.createSignal(stringPayload.count)
            } else if axon.contains(boolOutput) {
                return boolOutput.createSignal(!stringPayload.isEmpty)
            }
            return nil
        }
        
        let n = CNSNeuron(axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        var boolResult: Bool?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.outputSignal as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.outputSignal as? CNSSignal<Int> {
                intResult = outputSignal.payload
            } else if let outputSignal = r.outputSignal as? CNSSignal<Bool> {
                boolResult = outputSignal.payload
            }
        }
        
        _ = cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(stringResult, "processed: test")
        XCTAssertNil(intResult)
        XCTAssertNil(boolResult)
    }
    
    func testAsyncDendriteWithFuture() {
        let input = CNSCollateral<Int>()
        let out = CNSCollateral<String>()
        let axon = CNSAxon(out)
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, _, _) in
            guard let v = p else { return nil }
            return CNSEventual.future { complete in
                DispatchQueue.global().async {
                    complete(out.createSignal("v=\(v)"))
                }
            }
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])
        var outputs: [String] = []
        var qlens: [Int] = []
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<String>, let payload = s.payload { outputs.append(payload) }
            qlens.append(r.queueLength)
        }
        _ = cns.stimulate(input.createSignal(7))
        XCTAssertEqual(outputs, ["v=7"])
        XCTAssertEqual(qlens.last, 0)
    }

    func testFutureCompletionResumesOnStimulateLane() {
        let input = CNSCollateral<Int>()
        let out = CNSCollateral<String>()
        let axon = CNSAxon(out)
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, _, _) in
            guard let v = p else { return nil }
            return CNSEventual.future { complete in
                DispatchQueue.global().async {
                    complete(out.createSignal("v=\(v)"))
                }
            }
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])

        let stimulateThread = Thread.current
        var outputHandledOnStimulateThread = false
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<String>, s.collateral === out {
                outputHandledOnStimulateThread = Thread.current == stimulateThread
            }
        }

        _ = cns.stimulate(input.createSignal(7))
        XCTAssertTrue(outputHandledOnStimulateThread)
    }

    func testPerfSmokeRoutingThroughput() throws {
        guard ProcessInfo.processInfo.environment["CNS_PERF_SMOKE"] == "1" else {
            throw XCTSkip("Set CNS_PERF_SMOKE=1 to run the routing throughput smoke test.")
        }

        let input = CNSCollateral<Int>()
        let out = CNSCollateral<Int>()
        let axon = CNSAxon(out)
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, _, _) in
            out.createSignal((p ?? 0) + 1)
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])

        var outputCount = 0
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<Int>, s.collateral === out {
                outputCount += 1
            }
        }

        let iterations = 100_000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            _ = cns.stimulate(input.createSignal(i))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let throughput = Double(iterations) / elapsed

        print("CNS_PERF_SMOKE routing: \(iterations) stimulations in \(String(format: "%.4f", elapsed))s (\(Int(throughput))/s)")
        XCTAssertEqual(outputCount, iterations)
    }

    func testDeepSignalChainDoesNotOverflowCallStack() {
        let depth = ProcessInfo.processInfo.environment["CNS_DEEP_STACK_SMOKE"] == "1" ? 20_000 : 2_000
        let collaterals = (0...depth).map { _ in CNSCollateral<Int>() }
        var neurons: [CNSNeuron] = []

        neurons.reserveCapacity(depth)
        for i in 0..<depth {
            let input = collaterals[i]
            let output = collaterals[i + 1]
            let dendrite = CNSDendrite(inputCollateral: input) { (payload: Int?, _, _) in
                output.createSignal((payload ?? 0) + 1)
            }
            neurons.append(CNSNeuron(axon: CNSAxon(output), dendrites: [dendrite]))
        }

        let cns = CNS(neurons)
        var finalValue: Int?
        _ = cns.addResponseListener { r in
            if let signal = r.outputSignal as? CNSSignal<Int>, signal.collateral === collaterals[depth] {
                finalValue = signal.payload
            }
        }

        _ = cns.stimulate(collaterals[0].createSignal(0))
        XCTAssertEqual(finalValue, depth)
    }

    func testModalityDendriteSelectsAfferentPathHandler() {
        let input = CNSCollateral<String>()
        let out = CNSCollateral<String>()
        let axon = CNSAxon(out)
        let mode = modality(afferentPaths: [:])
        let path = afferentPath()
        let d = modalityDendrite(
            collateral: input,
            modality: mode,
            afferentPaths: [
                path: { payload, _, _ in
                    "path:\(payload as? String ?? "")"
                }
            ],
            default: { payload, _, _ in
                "default:\(payload as? String ?? "")"
            },
            output: { result, axon, _ in
                out.createSignal(result)
            }
        )
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])
        var result: String?
        _ = cns.addResponseListener { r in
            if let s = r.outputSignal as? CNSSignal<String> { result = s.payload }
        }
        _ = cns.stimulate(
            input.createSignal("x"),
            CNSStimulationOptions<String, String>(modality: mode, afferentPath: path)
        )
        XCTAssertEqual(result, "path:x")
    }

    func testContextStoreSetAllRestoresSnapshot() {
        let store = CNSStimulationContextStore()
        let key = NSObject()
        store.set(key: key, value: "value")
        let snapshot = store.getAll()
        store.delete(key: key)
        XCTAssertNil(store.get(key: key))
        store.setAll(snapshot)
        XCTAssertEqual(store.get(key: key) as? String, "value")
    }

    func testStimulationTracksFailedMaxHopTasks() {
        let input = CNSCollateral<Int>()
        let axon = CNSAxon()
        let d = CNSDendrite(inputCollateral: input) { (payload: Int?, _, _) in
            input.createSignal(payload ?? 0)
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])
        let stimulation = cns.stimulate(
            input.createSignal(1),
            CNSStimulationOptions<Int, Int>(maxNeuronHops: 1)
        )
        XCTAssertEqual(stimulation.getFailedTasks().count, 1)
        XCTAssertTrue(stimulation.getAllActivationTasks().isEmpty)
    }

    func testDrainGuardCompletes() async {
        let input = CNSCollateral<Int>()
        let out = CNSCollateral<Int>()
        let axon = CNSAxon(out)
        let d = CNSDendrite(inputCollateral: input) { (payload: Int?, _, _) in
            out.createSignal(payload ?? 0)
        }
        let cns = CNS([CNSNeuron(axon: axon, dendrites: [d])])
        let guarder = CNSDrainGuard<Int, Int>(cns: cns, signal: input.createSignal(3))
        await guarder.drain()
        XCTAssertFalse(guarder.isDraining())
        XCTAssertNil(guarder.getCurrentStimulation())
    }
}


