//
//  WebAppFailureHandler.swift
//  Kitura-Next-Perf
//
//  Created by Carl Brown on 5/8/17.
//
//

import Foundation

class WebAppFailureHandler: ResponseCreating {
    func serve(req: HTTPRequest, context: RequestContext, res: HTTPResponseWriter ) -> HTTPBodyProcessing {
        //Assume the router gave us the right request - at least for now
        res.writeResponse(HTTPResponse(httpVersion: req.httpVersion,
                                       status: .notFound,
                                       transferEncoding: .chunked,
                                       headers: HTTPHeaders()))
        return .processBody { (chunk, stop) in
            switch chunk {
            case .chunk(_, let finishedProcessing):
                finishedProcessing()
            case .end:
                res.done()
            default:
                stop = true /* don't call us anymore */
                res.abort()
            }
        }
    }
}
