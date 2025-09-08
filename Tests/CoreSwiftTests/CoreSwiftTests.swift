import XCTest
@testable import CNStraSwift

final class CoreSwiftTests: XCTestCase {
    // Cleaned: remove unused helper
    func testBasicFlow() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.output(String.self)
        }
        
        // Type-safe dendrite with full axon access
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Dynamic member access
            return axon.output.createSignal(stringPayload)
        }
        let n = CNSNeuron(name: "N", axon: axon, dendrites: [d])
        let cns = CNS([n])

        var seen: [String] = []
        _ = cns.addResponseListener { r in
            if let o = r.output as? CNSSignal<String> { seen.append(o.collateralType) }
            else if let i = r.input as? CNSSignal<String> { seen.append(i.collateralType) }
        }
        cns.stimulate(input.createSignal("hi"))
        XCTAssertEqual(seen, ["input", "output"])
    }

    func testComplexPayloadsAndDebugOrder() {
        struct User { let id: Int; let name: String }
        struct Profile { let id: Int; let nickname: String }
        let input = CNSCollateral<User>("user")
        let axon = CNSAxon.make { def in
            def.profile(Profile.self)
            def.log(String.self)
        }
        // D1: User -> Profile
        let d1 = CNSDendrite(inputCollateral: input) { (payload: User?, axon, _) in
            guard let u = payload else { return nil }
            return axon.profile.createSignal(Profile(id: u.id, nickname: u.name.lowercased()))
        }
        // D2: Profile -> log
        let d2 = CNSDendrite(inputCollateral: CNSCollateral<Profile>("profile")) { (payload: Profile?, axon, _) in
            guard let p = payload else { return nil }
            return axon.log.createSignal("profile: #\(p.id) \(p.nickname)")
        }
        let cns = CNS([CNSNeuron(name: "Pipe", axon: axon, dendrites: [d1, d2])])

        var seen: [String] = []
        var lastQueueLengths: [Int] = []
        _ = cns.addResponseListener { r in
            if r.output is CNSSignal<Profile> { seen.append("profile:") }
            if r.output is CNSSignal<String> { seen.append("log:") }
            lastQueueLengths.append(r.queueLength)
        }
        cns.stimulate(input.createSignal(User(id: 1, name: "Andrei")))
        XCTAssertEqual(seen, ["profile:", "log:"])
        // queueLength should be 0 only on the last response
        XCTAssertTrue(lastQueueLengths.last == 0)
        XCTAssertTrue(lastQueueLengths.dropLast().allSatisfy { $0 > 0 })
    }

    func testAbortSignals() {
        let input = CNSCollateral<Int>("in")
        let axon = CNSAxon.make { def in def.out(String.self) }
        let cancel = CNSCancellationToken()
        var passed = false
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, axon, ctx) in
            guard let v = p else { return nil }
            if v == 1 { ctx.abortToken?.cancel() }
            passed = true
            return axon.out.createSignal("x")
        }
        let cns = CNS([CNSNeuron(name: "N", axon: axon, dendrites: [d])])
        let opts = CNSStimulationOptions<Int, String>(onResponse: nil, cancelToken: cancel)
        cns.stimulate(input.createSignal(1), opts)
        // We cancelled quickly; handler ran, but no further queue appends
        XCTAssertTrue(passed)
    }

    func testContextPropagation() {
        let input = CNSCollateral<Int>("in")
        let axon = CNSAxon.make { def in def.mid(Int.self); def.out(Int.self) }
        let d1 = CNSDendrite(inputCollateral: input) { (p: Int?, axon, ctx) in
            ctx.set( (p ?? 0) + 1 )
            return axon.mid.createSignal((p ?? 0) + 10)
        }
        let d2 = CNSDendrite(inputCollateral: CNSCollateral<Int>("mid")) { (p: Int?, axon, ctx) in
            let local = (ctx.get() as? Int) ?? -1
            return axon.out.createSignal((p ?? 0) + local)
        }
        let cns = CNS([CNSNeuron(name: "AB", axon: axon, dendrites: [d1, d2])])
        var result: Int?
        _ = cns.addResponseListener { r in if let o = r.output as? CNSSignal<Int> { result = o.payload } }
        cns.stimulate(input.createSignal(5))
        XCTAssertEqual(result, 5 + 10 + (5 + 1))
    }

    func testConcurrencyWithinRun() {
        let input = CNSCollateral<Int>("in")
        let axon = CNSAxon.make { def in def.mid(Int.self); def.out(Int.self) }
        let d1 = CNSDendrite(inputCollateral: input) { (p: Int?, axon, _) in
            return axon.mid.createSignal((p ?? 0))
        }
        let d2 = CNSDendrite(inputCollateral: CNSCollateral<Int>("mid")) { (p: Int?, axon, _) in
            return axon.out.createSignal((p ?? 0))
        }
        let n = CNSNeuron(name: "N", axon: axon, dendrites: [d1, d2], concurrency: 1)
        let cns = CNS([n])
        var count = 0
        _ = cns.addResponseListener { r in if r.output is CNSSignal<Int> { count += 1 } }
        cns.stimulate(input.createSignal(1))
        XCTAssertEqual(count, 2)
    }

    func testConcurrencyAcrossMultipleRuns() {
        let input = CNSCollateral<Int>("in")
        let axon = CNSAxon.make { def in def.out(Int.self) }
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, axon, _) in
            return axon.out.createSignal((p ?? 0))
        }
        let n = CNSNeuron(name: "N", axon: axon, dendrites: [d], concurrency: 1)
        let cns = CNS([n])
        var total = 0
        _ = cns.addResponseListener { r in if let s = r.output as? CNSSignal<Int> { total += s.payload ?? 0 } }
        for i in 0..<100 { cns.stimulate(input.createSignal(i)) }
        XCTAssertEqual(total, (0..<100).reduce(0,+))
    }
    
    func testTypeSafeDendrite() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.output(Int.self)
        }
        
        // Type-safe dendrite with different input/output types
        let d = CNSDendrite(inputCollateral: input) { (payload: String?, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Dynamic member access to typed output
            return axon.output.createSignal(stringPayload.count) // Convert string length to int
        }
        
        let n = CNSNeuron(name: "N", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var result: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<Int> {
                result = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("hello"))
        XCTAssertEqual(result, 5) // "hello" has 5 characters
    }
    
    func testDendriteWithAxonCollateralAccess() {
        let input = CNSCollateral<String>("input")
        let output = CNSCollateral<String>("output")
        let axon = CNSAxon()
        axon.register(output)
        
        // Dendrite has full access to the axon
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Dynamic member access on axon
            return axon.output.createSignal("processed: \(stringPayload)")
        }
        
        let n = CNSNeuron(name: "Processor", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var result: String?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                result = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(result, "processed: test")
    }
    
    func testMultipleAxonCollaterals() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.stringOutput(String.self)
            def.intOutput(Int.self)
        }
        
        // Dendrite can choose which output collateral to use from the axon
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Use dynamic member
            return axon.stringOutput.createSignal("processed: \(stringPayload)")
        }
        
        let n = CNSNeuron(name: "MultiOutput", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.output as? CNSSignal<Int> {
                intResult = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(stringResult, "processed: test")
        XCTAssertNil(intResult) // No int output in this case
    }
    
    func testMultipleOutputCollaterals() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.stringOutput(String.self)
            def.intOutput(Int.self)
        }
        
        // Two dendrites using different output collaterals from the same axon
        let stringDendrite = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            return axon.stringOutput.createSignal("string: \(stringPayload)")
        }
        
        let intDendrite = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            return axon.intOutput.createSignal(stringPayload.count)
        }
        
        let n = CNSNeuron(name: "MultiOutput", axon: axon, dendrites: [stringDendrite, intDendrite])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.output as? CNSSignal<Int> {
                intResult = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("hello"))
        XCTAssertEqual(stringResult, "string: hello")
        XCTAssertEqual(intResult, 5)
    }
    
    func testDendriteUsingMultipleAxonCollaterals() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.stringOutput(String.self)
            def.intOutput(Int.self)
            def.boolOutput(Bool.self)
        }
        
        // Dendrite that uses multiple collaterals from the same axon
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            
            // Much cleaner via dynamic members
            let stringCollateral: CNSCollateral<String>? = axon.safe.stringOutput
            let intCollateral: CNSCollateral<Int>? = axon.safe.intOutput
            let boolCollateral: CNSCollateral<Bool>? = axon.safe.boolOutput
            
            // Return the first available signal (in practice, you might want to return multiple signals)
            if let stringCollateral = stringCollateral {
                return stringCollateral.createSignal("processed: \(stringPayload)")
            } else if let intCollateral = intCollateral {
                return intCollateral.createSignal(stringPayload.count)
            } else if let boolCollateral = boolCollateral {
                return boolCollateral.createSignal(!stringPayload.isEmpty)
            }
            return nil
        }
        
        let n = CNSNeuron(name: "MultiCollateral", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        var boolResult: Bool?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.output as? CNSSignal<Int> {
                intResult = outputSignal.payload
            } else if let outputSignal = r.output as? CNSSignal<Bool> {
                boolResult = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(stringResult, "processed: test")
        XCTAssertNil(intResult)
        XCTAssertNil(boolResult)
    }
    
    func testAxonConvenienceMethods() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.stringOutput(String.self)
            def.intOutput(Int.self)
        }
        
        // Test safe access (returns optional)
        let d1 = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Safe access - returns optional
            guard let outputCollateral: CNSCollateral<String> = axon.get("stringOutput", String.self) else { return nil }
            return outputCollateral.createSignal("safe: \(stringPayload)")
        }
        
        // Test direct access (force unwrap - use when you're sure it exists)
        let d2 = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            // Direct access - no optional, but will crash if collateral doesn't exist
            return axon.getForce("stringOutput", String.self).createSignal("direct: \(stringPayload)")
        }
        
        let n = CNSNeuron(name: "ConvenienceTest", axon: axon, dendrites: [d1, d2])
        let cns = CNS([n])
        
        var results: [String] = []
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                results.append(outputSignal.payload!)
            }
        }
        
        cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains("safe: test"))
        XCTAssertTrue(results.contains("direct: test"))
    }
    
    func testAxonCreateCollaterals() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon()
        
        // Create collaterals directly in the axon - no external references needed!
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            
            // Create output collaterals directly in the axon
            let stringOutput = axon.create("stringOutput", String.self)
            let intOutput = axon.create("intOutput", Int.self)
            
            // Use the created collaterals
            if stringPayload.count > 3 {
                return stringOutput.createSignal("long: \(stringPayload)")
            } else {
                return intOutput.createSignal(stringPayload.count)
            }
        }
        
        let n = CNSNeuron(name: "AxonCreator", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var stringResult: String?
        var intResult: Int?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                stringResult = outputSignal.payload
            } else if let outputSignal = r.output as? CNSSignal<Int> {
                intResult = outputSignal.payload
            }
        }
        
        // Test with long string
        cns.stimulate(input.createSignal("hello"))
        XCTAssertEqual(stringResult, "long: hello")
        XCTAssertNil(intResult)
        
        // Reset results
        stringResult = nil
        intResult = nil
        
        // Test with short string
        cns.stimulate(input.createSignal("hi"))
        XCTAssertNil(stringResult)
        XCTAssertEqual(intResult, 2)
    }
    
    func testAxonCreateCollateralsSimplified() {
        let input = CNSCollateral<String>("input")
        let axon = CNSAxon.make { def in
            def.output(String.self)
        }
        
        // Use dynamic members
        let d = CNSDendrite(inputCollateral: input) { (payload, axon, _) in
            guard let stringPayload = payload else { return nil }
            return axon.output.createSignal("processed: \(stringPayload)")
        }
        
        let n = CNSNeuron(name: "SimpleCreator", axon: axon, dendrites: [d])
        let cns = CNS([n])
        
        var result: String?
        _ = cns.addResponseListener { r in
            if let outputSignal = r.output as? CNSSignal<String> {
                result = outputSignal.payload
            }
        }
        
        cns.stimulate(input.createSignal("test"))
        XCTAssertEqual(result, "processed: test")
    }

    func testAsyncDendriteWithFuture() {
        let input = CNSCollateral<Int>("in")
        let axon = CNSAxon.make { def in def.out(String.self) }
        let d = CNSDendrite(inputCollateral: input) { (p: Int?, axon, _) in
            guard let v = p else { return nil }
            return CNSEventual.future { complete in
                DispatchQueue.global().async {
                    complete(axon.out.createSignal("v=\(v)"))
                }
            }
        }
        let cns = CNS([CNSNeuron(name: "N", axon: axon, dendrites: [d])])
        var outputs: [String] = []
        var qlens: [Int] = []
        _ = cns.addResponseListener { r in
            if let s = r.output as? CNSSignal<String>, let payload = s.payload { outputs.append(payload) }
            qlens.append(r.queueLength)
        }
        cns.stimulate(input.createSignal(7))
        XCTAssertEqual(outputs, ["v=7"])
        XCTAssertEqual(qlens.last, 0)
    }
}


