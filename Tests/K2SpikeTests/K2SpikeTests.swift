import XCTest
import HeliumLogger

@testable import K2Spike

class K2SpikeTests: XCTestCase {
    func testResponseOK() {
        let request = HTTPRequest(method: .GET, target:"/echo", httpVersion: (1, 1), headers: HTTPHeaders([("X-foo", "bar")]))
        let resolver = TestResponseResolver(request: request, requestBody: Data())
        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/echo", verb:.GET): EchoWebApp()]))
        resolver.resolveHandler(coordinator.handle)
        XCTAssertNotNil(resolver.response)
        XCTAssertNotNil(resolver.responseBody)
        XCTAssertEqual(HTTPResponseStatus.ok.code, resolver.response?.status.code ?? 0)
    }

    func testEcho() {
        let testString="This is a test"
        let request = HTTPRequest(method: .POST, target:"/echo", httpVersion: (1, 1), headers: HTTPHeaders([("X-foo", "bar")]))
        let resolver = TestResponseResolver(request: request, requestBody: testString.data(using: .utf8)!)
        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/echo", verb:.POST): EchoWebApp()]))
        resolver.resolveHandler(coordinator.handle)
        XCTAssertNotNil(resolver.response)
        XCTAssertNotNil(resolver.responseBody)
        XCTAssertEqual(HTTPResponseStatus.ok.code, resolver.response?.status.code ?? 0)
        XCTAssertEqual(testString, String(data: resolver.responseBody ?? Data(), encoding: .utf8) ?? "Nil")
    }
    
    func testHello() {
        let request = HTTPRequest(method: .GET, target:"/helloworld", httpVersion: (1, 1), headers: HTTPHeaders([("X-foo", "bar")]))
        let resolver = TestResponseResolver(request: request, requestBody: Data())
        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/helloworld", verb:.GET): HelloWorldWebApp()]))
        resolver.resolveHandler(coordinator.handle)
        XCTAssertNotNil(resolver.response)
        XCTAssertNotNil(resolver.responseBody)
        XCTAssertEqual(HTTPResponseStatus.ok.code, resolver.response?.status.code ?? 0)
        XCTAssertEqual("Hello, World!", String(data: resolver.responseBody ?? Data(), encoding: .utf8) ?? "Nil")
    }


    func testHelloEndToEnd() {
        HeliumLogger.use(.info)
        let receivedExpectation = self.expectation(description: "Received web response")
        
        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/helloworld", verb:.GET): HelloWorldWebApp()]))

        do {
            let server = try HTTPServer.listen(on: 0, delegate: coordinator.handle)
            let session = URLSession(configuration: URLSessionConfiguration.default)
            let url = URL(string: "http://localhost:\(server.port!)/helloworld")!
            let dataTask = session.dataTask(with: url) { (responseBody, rawResponse, error) in
                let response = rawResponse as? HTTPURLResponse
                XCTAssertNil(error, "\(error!.localizedDescription)")
                XCTAssertNotNil(response)
                XCTAssertNotNil(responseBody)
                XCTAssertEqual(Int(HTTPResponseStatus.ok.code), response?.statusCode ?? 0)
                XCTAssertEqual("Hello, World!", String(data: responseBody ?? Data(), encoding: .utf8) ?? "Nil")
                receivedExpectation.fulfill()
            }
            dataTask.resume()
            self.waitForExpectations(timeout: 10) { (error) in
                if let error = error {
                    XCTFail("\(error)")
                }
            }
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }
    
    func testRequestEchoEndToEnd() {
        HeliumLogger.use(.info)
        let receivedExpectation = self.expectation(description: "Received web response")
        let testString="This is a test"

        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/echo", verb:.POST): EchoWebApp()]))
        
        do {
            let server = try HTTPServer.listen(on: 0, delegate: coordinator.handle)
            let session = URLSession(configuration: URLSessionConfiguration.default)
            let url = URL(string: "http://localhost:\(server.port!)/echo")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = testString.data(using: .utf8)
            let dataTask = session.dataTask(with: request) { (responseBody, rawResponse, error) in
                let response = rawResponse as? HTTPURLResponse
                XCTAssertNil(error, "\(error!.localizedDescription)")
                XCTAssertNotNil(response)
                XCTAssertNotNil(responseBody)
                XCTAssertEqual(Int(HTTPResponseStatus.ok.code), response?.statusCode ?? 0)
                XCTAssertEqual(testString, String(data: responseBody ?? Data(), encoding: .utf8) ?? "Nil")
                receivedExpectation.fulfill()
            }
            dataTask.resume()
            self.waitForExpectations(timeout: 10) { (error) in
                if let error = error {
                    XCTFail("\(error)")
                }
            }
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }

    func testHelloCookieEndToEnd() {
        HeliumLogger.use(.info)
        let receivedExpectation = self.expectation(description: "Received web response")
        
        let coordinator = RequestHandlingCoordinator.init(router: Router(map: [Path(path:"/helloworld", verb:.GET): HelloWorldWebApp()]))
        let badCookieHandler = BadCookieWritingMiddleware(cookieName: "OurCookie")
        
        coordinator.addPreProcessor(badCookieHandler.preProcess)
        coordinator.addPostProcessor(badCookieHandler.postProcess)
        
        do {
            let server = try HTTPServer.listen(on: 0, delegate: coordinator.handle)
            let session = URLSession(configuration: URLSessionConfiguration.default)
            let url = URL(string: "http://localhost:\(server.port!)/helloworld")!
            let dataTask = session.dataTask(with: url) { (responseBody, rawResponse, error) in
                let response = rawResponse as? HTTPURLResponse
                XCTAssertNil(error, "\(error!.localizedDescription)")
                XCTAssertNotNil(response)
                XCTAssertNotNil(responseBody)
                XCTAssertEqual(Int(HTTPResponseStatus.ok.code), response?.statusCode ?? 0)
                XCTAssertEqual("Hello, World!", String(data: responseBody ?? Data(), encoding: .utf8) ?? "Nil")
                #if os(Linux)
                    //print("\(response!.allHeaderFields.debugDescription)")
                    XCTAssertNotNil(response?.allHeaderFields["Set-Cookie"])
                    let ourCookie = response?.allHeaderFields["Set-Cookie"] as? String
                    let ourCookieString = ourCookie ?? ""
                    let index = ourCookieString.index(ourCookieString.startIndex, offsetBy: 10)
                    XCTAssertTrue(ourCookieString.substring(to: index) == "OurCookie=")
                #else
                    let fields = response?.allHeaderFields as? [String : String] ?? [:]
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                    XCTAssertNotNil(cookies)
                    print("\(cookies.debugDescription)")
                    var ourCookie: HTTPCookie? = nil
                    var missingCookie: HTTPCookie? = nil //We should not find this
                    for cookie in cookies {
                        if cookie.name == "OurCookie" {
                            ourCookie = cookie
                        }
                        if cookie.name == "MissingCookie" {
                            missingCookie = cookie
                        }
                    }
                    
                    XCTAssertNotNil(ourCookie)
                    XCTAssertNil(missingCookie)
                #endif
                receivedExpectation.fulfill()
            }
            dataTask.resume()
            self.waitForExpectations(timeout: 10) { (error) in
                if let error = error {
                    XCTFail("\(error)")
                }
            }
            server.stop()
        } catch {
            XCTFail("Error listening on port \(0): \(error). Use server.failed(callback:) to handle")
        }
    }

    
    static var allTests = [
        ("testEcho", testEcho),
        ("testHello", testHello),
        ("testResponseOK", testResponseOK),
        ("testHelloEndToEnd", testHelloEndToEnd),
        ("testRequestEchoEndToEnd", testRequestEchoEndToEnd),
        ("testHelloCookieEndToEnd", testHelloCookieEndToEnd),
        ]
}
