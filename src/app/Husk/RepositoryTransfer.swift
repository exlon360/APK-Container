// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A bounded, cancellable HTTPS transfer. Large APKs go straight to a temporary
/// file; neither repository metadata nor APK downloads can grow without a limit.
final class RepositoryTransfer: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    struct Response { let file: URL?; let status: Int; let etag: String? }
    private let destinationDirectory: URL?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var maximum: Int64 = 0
    private var progress: ((Double) -> Void)?

    init(destinationDirectory: URL? = nil) {
        self.destinationDirectory = destinationDirectory
        super.init()
    }

    func download(_ request: URLRequest, maximum: Int64, progress: ((Double) -> Void)? = nil) async throws -> Response {
        guard request.url.flatMap({ RepositoryCatalog.httpsURL($0.absoluteString) }) != nil else {
            throw RepositoryCatalog.Failure.message("Repository downloads must use HTTPS.")
        }
        self.maximum = maximum
        self.progress = progress
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 600
                config.urlCache = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }
    private func finish(_ result: Result<Response, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil; task = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
    private func checked(_ response: URLResponse?) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse,
              response.url.flatMap({ RepositoryCatalog.httpsURL($0.absoluteString) }) != nil else {
            throw RepositoryCatalog.Failure.message("The repository returned an invalid or insecure response.")
        }
        guard response.statusCode == 200 || response.statusCode == 304 else {
            if response.statusCode == 403 || response.statusCode == 429 {
                throw RepositoryCatalog.Failure.message("The repository's request limit was reached. Cached apps remain available; try again later.")
            }
            throw RepositoryCatalog.Failure.message("The repository returned HTTP \(response.statusCode).")
        }
        guard response.expectedContentLength <= maximum else { throw RepositoryCatalog.Failure.message("This repository download exceeds its size limit.") }
        return response
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url.flatMap({ RepositoryCatalog.httpsURL($0.absoluteString) }) != nil else {
            completionHandler(nil)
            finish(.failure(RepositoryCatalog.Failure.message("The repository redirected to an insecure address.")))
            task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            _ = try checked(downloadTask.response)
            guard totalBytesWritten <= maximum, totalBytesExpectedToWrite <= maximum else {
                throw RepositoryCatalog.Failure.message("This repository download exceeds its size limit.")
            }
            if totalBytesExpectedToWrite > 0 { progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
        } catch { finish(.failure(error)); downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let response = try checked(downloadTask.response)
            if response.statusCode == 304 {
                finish(.success(Response(file: nil, status: 304, etag: response.value(forHTTPHeaderField: "ETag")))); return
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size >= 0, size <= maximum else { throw RepositoryCatalog.Failure.message("This repository download exceeds its size limit.") }
            let directory = destinationDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RepositoryDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + ".apk")
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(Response(file: destination, status: 200, etag: response.value(forHTTPHeaderField: "ETag"))))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response = task.response as? HTTPURLResponse, response.statusCode == 304 {
            finish(.success(Response(file: nil, status: 304, etag: response.value(forHTTPHeaderField: "ETag"))))
        }
    }
}
