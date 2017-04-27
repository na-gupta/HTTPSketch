/*
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import Dispatch

import LoggerAPI
import Socket

/// This class processes the data sent by the client after the data was read. The data
/// is parsed, filling in a `HTTPServerRequest` object. When the parsing is complete, the
/// `ServerDelegate` is invoked.
public class IncomingHTTPSocketProcessor: IncomingSocketProcessor {
    
    /// A back reference to the `IncomingSocketHandler` processing the socket that
    /// this `IncomingDataProcessor` is processing.
    public weak var handler: IncomingSocketHandler?
        
    private weak var delegate: ServerDelegate?
    
    /// Keep alive timeout for idle sockets in seconds
    static let keepAliveTimeout: TimeInterval = 60
    
    /// A flag indicating that the client has requested that the socket be kept alive
    private(set) var clientRequestedKeepAlive = false
    
    /// The socket if idle will be kep alive until...
    public var keepAliveUntil: TimeInterval = 0.0
    
    /// A flag indicating that the client has requested that the prtocol be upgraded
    private(set) var isUpgrade = false
    
    /// A flag that indicates that there is a request in progress
    public var inProgress = true
    
    ///HTTP Parser
    private let httpParser: HTTPParser
    
    /// The number of remaining requests that will be allowed on the socket being handled by this handler
    private(set) var numberOfRequests = 100
    
    /// Should this socket actually be kept alive?
    var isKeepAlive: Bool { return clientRequestedKeepAlive && numberOfRequests > 0 }
    
    let socket: Socket
    
    /// An enum for internal state
    enum State {
        case reset, readingMessage, messageCompletelyRead
    }
    
    /// The state of this handler
    private(set) var state = State.readingMessage
    
    /// Location in the buffer to start parsing from
    private var parseStartingFrom = 0
    
    init(socket: Socket, using: ServerDelegate) {
        delegate = using
        self.httpParser = HTTPParser(isRequest: true)
        self.socket = socket
    }
    
    /// Process data read from the socket. It is either passed to the HTTP parser or
    /// it is saved in the Pseudo synchronous reader to be read later on.
    ///
    /// - Parameter buffer: An NSData object that contains the data read from the socket.
    ///
    /// - Returns: true if the data was processed, false if it needs to be processed later.
    public func process(_ buffer: NSData) -> Bool {
        let result: Bool
        
        switch(state) {
        case .reset:
            httpParser.reset()
            state = .readingMessage
            fallthrough

        case .readingMessage:
            inProgress = true
            parse(buffer)
            result = parseStartingFrom == 0
            
        case .messageCompletelyRead:
            result = parseStartingFrom == 0 && buffer.length == 0
            break
        }
        
        return result
    }
    
    /// Write data to the socket
    ///
    /// - Parameter data: An NSData object containing the bytes to be written to the socket.
    public func write(from data: NSData) {
        handler?.write(from: data)
    }
    
    /// Write a sequence of bytes in an array to the socket
    ///
    /// - Parameter from: An UnsafeRawPointer to the sequence of bytes to be written to the socket.
    /// - Parameter length: The number of bytes to write to the socket.
    public func write(from bytes: UnsafeRawPointer, length: Int) {
        handler?.write(from: bytes, length: length)
    }
    
    /// Close the socket and mark this handler as no longer in progress.
    public func close() {
        keepAliveUntil=0.0
        inProgress = false
        clientRequestedKeepAlive = false
        handler?.prepareToClose()
    }
    
    /// Called by the `IncomingSocketHandler` to tell us that the socket has been closed
    /// by the remote side. 
    public func socketClosed() {
        keepAliveUntil=0.0
        inProgress = false
        clientRequestedKeepAlive = false
    }
    
    /// Parse the message
    ///
    /// - Parameter buffer: An NSData object contaning the data to be parsed
    /// - Parameter from: From where in the buffer to start parsing
    /// - Parameter completeBuffer: An indication that the complete buffer is being passed in.
    ///                            If true and the entire buffer is parsed, an EOF indication
    ///                            will be passed to the http_parser.
    func parse (_ buffer: NSData, from: Int, completeBuffer: Bool=false) -> HTTPParserStatus {
        var status = HTTPParserStatus()
        let length = buffer.length - from
        
        guard length > 0  else {
            /* Handle unexpected EOF. Usually just close the connection. */
            status.error = .unexpectedEOF
            return status
        }
                
        // If we were reset because of keep alive
        if  status.state == .reset  {
            return status
        }
        
        let bytes = buffer.bytes.assumingMemoryBound(to: Int8.self) + from
        let (numberParsed, upgrade) = httpParser.execute(bytes, length: length)
        
        if completeBuffer && numberParsed == length {
            // Tell parser we reached the end
            _ = httpParser.execute(bytes, length: 0)
        }
        
        if upgrade == 1 {
            status.upgrade = true
        }
        
        status.bytesLeft = length - numberParsed
        
        if httpParser.completed {
            status.state = .messageComplete
            status.keepAlive = httpParser.isKeepAlive() 
            return status
        }
        else if numberParsed != length  {
            /* Handle error. Usually just close the connection. */
            status.error = .parsedLessThanRead
        }
        
        return status
    }
    
    /// Invoke the HTTP parser against the specified buffer of data and
    /// convert the HTTP parser's status to our own.
    private func parse(_ buffer: NSData) {
        let parsingStatus = parse(buffer, from: parseStartingFrom)
        
        if parsingStatus.bytesLeft == 0 {
            parseStartingFrom = 0
        }
        else {
            parseStartingFrom = buffer.length - parsingStatus.bytesLeft
        }
        
        guard  parsingStatus.error == nil  else  {
            Log.error("Failed to parse a request. \(parsingStatus.error!)")
            let response = HTTPServerResponse(processor: self, request: nil)
            response.statusCode = .badRequest
            do {
                try response.end()
            }
            catch {}

            return
        }
        
        switch(parsingStatus.state) {
        case .initial:
            break
        case .messageComplete:
            isUpgrade = parsingStatus.upgrade
            clientRequestedKeepAlive = parsingStatus.keepAlive && !isUpgrade
            parsingComplete()
        case .reset:
            state = .reset
            break
        }
    }
    
    /// Parsing has completed. Invoke the ServerDelegate to handle the request
    private func parsingComplete() {
        state = .messageCompletelyRead
        
        let request = HTTPServerRequest(socket: socket, httpParser: httpParser)
        request.parsingCompleted()
        
        let response = HTTPServerResponse(processor: self, request: request)

        // If the IncomingSocketHandler was freed, we can't handle the request
        guard let handler = handler else {
            Log.error("IncomingSocketHandler not set or freed before parsing complete")
            return
        }
        
        if isUpgrade {
            ConnectionUpgrader.instance.upgradeConnection(handler: handler, request: request, response: response)
            inProgress = false
        }
        else {
            weak var weakRequest = request
            DispatchQueue.global().async() { [weak self] in
                if let strongSelf = self, let strongRequest = weakRequest {
                    Monitor.delegate?.started(request: strongRequest, response: response)
                    strongSelf.delegate?.serve(req: strongRequest, res: httpResponseWriter)
                }
            }
        }
    }
    
    /// A socket can be kept alive for future requests. Set it up for future requests and mark how long it can be idle.
    func keepAlive() {
        state = .reset
        numberOfRequests -= 1
        inProgress = false
        keepAliveUntil = Date(timeIntervalSinceNow: IncomingHTTPSocketProcessor.keepAliveTimeout).timeIntervalSinceReferenceDate
        handler?.handleBufferedReadData()
    }
}
