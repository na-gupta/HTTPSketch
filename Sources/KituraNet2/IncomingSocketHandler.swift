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

import Dispatch

import Foundation

import LoggerAPI
import Socket

/// This class handles incoming sockets to the HTTPServer. The data sent by the client
/// is read and passed to the current `IncomingDataProcessor`.
///
/// - Note: The IncomingDataProcessor can change due to an Upgrade request.
///
/// - Note: This class uses different underlying technologies depending on:
///
///     1. On Linux, if no special compile time options are specified, epoll is used
///     2. On OSX, DispatchSource is used
///     3. On Linux, if the compile time option -Xswiftc -DGCD_ASYNCH is specified,
///        DispatchSource is used, as it is used on OSX.
public class IncomingSocketHandler {
    
    static let socketWriterQueue = DispatchQueue(label: "Socket Writer")
    
    #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
        static let socketReaderQueues = [DispatchQueue(label: "Socket Reader A"), DispatchQueue(label: "Socket Reader B")]
    
        // Note: This var is optional to enable it to be constructed in the init function
        var readerSource: DispatchSourceRead!
        var writerSource: DispatchSourceWrite?
    
        private let numberOfSocketReaderQueues = IncomingSocketHandler.socketReaderQueues.count
    
        private func socketReaderQueue(fd: Int32) -> DispatchQueue {
            return IncomingSocketHandler.socketReaderQueues[Int(fd) % numberOfSocketReaderQueues];
        }
    #endif

    let socket: Socket

    /// The `IncomingSocketProcessor` instance that processes data read from the underlying socket.
    public var processor: IncomingHTTPSocketProcessor?
    
    private weak var manager: IncomingSocketManager?
    
    private let readBuffer = NSMutableData()
    private let writeBuffer = NSMutableData()
    private var writeBufferPosition = 0

    /// preparingToClose is set when prepareToClose() gets called or anytime we detect the socket has errored or was closed,
    /// so we try to close and cleanup as long as there is no data waiting to be written and a socket read/write is not in progress.
    private var preparingToClose = false

    /// isOpen is set to false when:
    ///   - close() is invoked AND
    ///   - it is safe to close the socket (there is no data waiting to be written and a socket read/write is not in progress).
    /// This lets other threads know to not start reads/writes on this socket anymore, which could cause a crash.
    private var isOpen = true

    /// write() sets this when it starts and unsets it when finished so other threads do not close `socket` during that time,
    /// which could cause a crash. If any other threads tried to close during that time, write() re-attempts close when it's done
    private var writeInProgress = false

    /// handleWrite() sets this when it starts and unsets it when finished so other threads do not close `socket` during that time,
    /// which could cause a crash. If any other threads tried to close during that time, handleWrite() re-attempts close when it's done
    private var handleWriteInProgress = false

    /// handleRead() sets this when it starts and unsets it when finished so other threads do not close `socket` during that time,
    /// which could cause a crash. If any other threads tried to close during that time, handleRead() re-attempts close when it's done
    private var handleReadInProgress = false

    /// The file descriptor of the incoming socket
    var fileDescriptor: Int32 { return socket.socketfd }
    
    init(socket: Socket, using: IncomingSocketProcessor, managedBy: IncomingSocketManager) {
        self.socket = socket
        processor = using as? IncomingHTTPSocketProcessor
        manager = managedBy
        processor?.handler = self
        
        #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
            readerSource = DispatchSource.makeReadSource(fileDescriptor: socket.socketfd,
                                                         queue: socketReaderQueue(fd: socket.socketfd))
        
            readerSource.setEventHandler() {
                _ = self.handleRead()
            }
            readerSource.setCancelHandler(handler: self.handleCancel)
            readerSource.resume()
        #endif
    }
    
    /// Read in the available data and hand off to common processing code
    ///
    /// - Returns: true if the data read in was processed
    func handleRead() -> Bool {
        handleReadInProgress = true
        defer {
            handleReadInProgress = false // needs to be unset before calling close() as it is part of the guard in close()
            if preparingToClose {
                close()
            }
        }

        // Set handleReadInProgress flag to true before the guard below to avoid another thread
        // invoking close() in between us clearing the guard and setting the flag.
        guard isOpen && socket.socketfd > -1 else {
            preparingToClose = true // flag the function defer clause to cleanup if needed
            return true
        }

        var result = true
        
        do {
            var length = 1
            while  length > 0  {
                length = try socket.read(into: readBuffer)
            }
            if  readBuffer.length > 0  {
                result = handleReadHelper()
            }
            else {
                if socket.remoteConnectionClosed  {
                    Log.debug("socket remoteConnectionClosed in handleRead()")
                    processor?.socketClosed()
                    preparingToClose = true
                }
            }
        }
        catch let error as Socket.Error {
            if error.errorCode == Int32(Socket.SOCKET_ERR_CONNECTION_RESET) {
                Log.debug("Read from socket (file descriptor \(socket.socketfd)) reset. Error = \(error).")
            } else {
                Log.error("Read from socket (file descriptor \(socket.socketfd)) failed. Error = \(error).")
            }
            preparingToClose = true
        } catch {
            Log.error("Unexpected error...")
            preparingToClose = true
        }

        return result
    }
    
    private func handleReadHelper() -> Bool {
        guard let processor = processor else { return true }
        
        let processed = processor.process(readBuffer)
        if  processed {
            readBuffer.length = 0
        }
        return processed
    }
    
    /// Helper function for handling data read in while the processor couldn't
    /// process it, if there is any
    func handleBufferedReadDataHelper() -> Bool {
        let result : Bool
        
        if  readBuffer.length > 0  {
            result = handleReadHelper()
        }
        else {
            result = true
        }
        return result
    }
    
    /// Handle data read in while the processor couldn't process it, if there is any
    ///
    /// - Note: On Linux, the `IncomingSocketManager` should call `handleBufferedReadDataHelper`
    ///        directly.
    public func handleBufferedReadData() {
        #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
            if socket.socketfd != Socket.SOCKET_INVALID_DESCRIPTOR {
                socketReaderQueue(fd: socket.socketfd).sync() { [unowned self] in
                    _ = self.handleBufferedReadDataHelper()
                }
            }
        #endif
    }
    
    /// Write out any buffered data now that the socket can accept more data
    func handleWrite() {
        #if !GCD_ASYNCH  &&  os(Linux)
            IncomingSocketHandler.socketWriterQueue.sync() { [unowned self] in
                self.handleWriteHelper()
            }
        #endif
    }
    
    /// Inner function to write out any buffered data now that the socket can accept more data,
    /// invoked in serial queue.
    private func handleWriteHelper() {
        handleWriteInProgress = true
        defer {
            handleWriteInProgress = false // needs to be unset before calling close() as it is part of the guard in close()
            if preparingToClose {
                close()
            }
        }

        if  writeBuffer.length != 0 {
            defer {
                #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
                    if writeBuffer.length == 0, let writerSource = writerSource {
                        writerSource.cancel()
                    }
                #endif
            }

            // Set handleWriteInProgress flag to true before the guard below to avoid another thread
            // invoking close() in between us clearing the guard and setting the flag.
            guard isOpen && socket.socketfd > -1 else {
                Log.warning("Socket closed with \(writeBuffer.length - writeBufferPosition) bytes still to be written")
                writeBuffer.length = 0
                writeBufferPosition = 0
                preparingToClose = true // flag the function defer clause to cleanup if needed
                return
            }

            do {
                let amountToWrite = writeBuffer.length - writeBufferPosition
                
                let written: Int
                    
                if amountToWrite > 0 {
                    written = try socket.write(from: writeBuffer.bytes + writeBufferPosition,
                                               bufSize: amountToWrite)
                }
                else {
                    if amountToWrite < 0 {
                        Log.error("Amount of bytes to write to file descriptor \(socket.socketfd) was negative \(amountToWrite)")
                    }
                    
                    written = amountToWrite
                }
                
                if written != amountToWrite {
                    writeBufferPosition += written
                }
                else {
                    writeBuffer.length = 0
                    writeBufferPosition = 0
                }
            }
            catch let error {
                if let error = error as? Socket.Error, error.errorCode == Int32(Socket.SOCKET_ERR_CONNECTION_RESET) {
                    Log.debug("Write to socket (file descriptor \(socket.socketfd)) failed. Error = \(error).")
                } else {
                    Log.error("Write to socket (file descriptor \(socket.socketfd)) failed. Error = \(error).")
                }
                
                // There was an error writing to the socket, close the socket
                writeBuffer.length = 0
                writeBufferPosition = 0
                preparingToClose = true
            }
        }
    }
    
    /// Create the writer source
    private func createWriterSource() {
        #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
            writerSource = DispatchSource.makeWriteSource(fileDescriptor: socket.socketfd,
                                                          queue: IncomingSocketHandler.socketWriterQueue)
            
            writerSource!.setEventHandler(handler: self.handleWriteHelper)
            writerSource!.setCancelHandler() {
                self.writerSource = nil
            }
            writerSource!.resume()
        #endif
    }
    
    /// Write as much data to the socket as possible, buffering the rest
    ///
    /// - Parameter data: The NSData object containing the bytes to write to the socket.
    public func write(from data: NSData) {
        write(from: data.bytes, length: data.length)
    }
    
    /// Write a sequence of bytes in an array to the socket
    ///
    /// - Parameter from: An UnsafeRawPointer to the sequence of bytes to be written to the socket.
    /// - Parameter length: The number of bytes to write to the socket.
    public func write(from bytes: UnsafeRawPointer, length: Int) {
        writeInProgress = true
        defer {
            writeInProgress = false // needs to be unset before calling close() as it is part of the guard in close()
            if preparingToClose {
                close()
            }
        }

        // Set writeInProgress flag to true before the guard below to avoid another thread
        // invoking close() in between us clearing the guard and setting the flag.
        guard isOpen && socket.socketfd > -1 else {
            Log.warning("IncomingSocketHandler write() called after socket \(socket.socketfd) closed")
            preparingToClose = true // flag the function defer clause to cleanup if needed
            return
        }

        do {
            let written: Int
            
            if  writeBuffer.length == 0 {
                written = try socket.write(from: bytes, bufSize: length)
            }
            else {
                written = 0
            }
            
            if written != length {
                IncomingSocketHandler.socketWriterQueue.sync() { [unowned self] in
                    self.writeBuffer.append(bytes + written, length: length - written)
                }
                
                #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
                    if writerSource == nil {
                        createWriterSource()
                    }
                #endif
            }
        }
        catch let error {
            if let error = error as? Socket.Error, error.errorCode == Int32(Socket.SOCKET_ERR_CONNECTION_RESET) {
                Log.debug("Write to socket (file descriptor \(socket.socketfd)) failed. Error = \(error).")
            } else {
                Log.error("Write to socket (file descriptor \(socket.socketfd)) failed. Error = \(error).")
            }
        }
    }

    /// If there is data waiting to be written, set a flag and the socket will
    /// be closed when all the buffered data has been written.
    /// Otherwise, immediately close the socket.
    public func prepareToClose() {
        preparingToClose = true
        close()
    }

    /// Close the socket and mark this handler as no longer in progress, if it is safe.
    /// (there is no data waiting to be written and a socket read/write is not in progress).
    ///
    /// - Note: On Linux closing the socket causes it to be dropped by epoll.
    /// - Note: On OSX the cancel handler will actually close the socket.
    private func close() {
        if isOpen {
            isOpen = false
            // Set isOpen to false before the guard below to avoid another thread invoking
            // a read/write function in between us clearing the guard and setting the flag.
            // Make sure to set it back to open if the guard fails and we don't actually close.
            // This guard needs to be here, not in handleCancel() as readerSource.cancel()
            // only invokes handleCancel() the first time it is called.
            guard !writeInProgress && !handleWriteInProgress && !handleReadInProgress
                && writeBuffer.length == writeBufferPosition else {
                    isOpen = true
                    return
            }

            #if os(OSX) || os(iOS) || os(tvOS) || os(watchOS) || GCD_ASYNCH
                readerSource.cancel()
            #else
                handleCancel()
            #endif
        }
    }

    /// DispatchSource cancel handler
    private func handleCancel() {
        isOpen = false // just in case something besides close() calls handleCancel()
        if socket.socketfd > -1 {
            socket.close()
        }

        processor?.inProgress = false
        processor?.keepAliveUntil = 0.0
        processor?.handler = nil
        processor?.close()
        processor = nil
    }
}
