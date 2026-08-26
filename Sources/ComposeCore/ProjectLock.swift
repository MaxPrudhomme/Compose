import Darwin
import Foundation

public final class ProjectLock {
  public struct Holder: Codable, Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let workingDirectory: String
    public let startedAt: Date

    public init(pid: Int32, command: String, workingDirectory: String, startedAt: Date = Date()) {
      self.pid = pid
      self.command = command
      self.workingDirectory = workingDirectory
      self.startedAt = startedAt
    }
  }

  private let descriptor: Int32
  private let stateLock = NSLock()
  private var isHeld = true

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    unlock()
  }

  public static func acquire(
    projectName: String,
    command: String,
    workingDirectory: String,
    lockDirectory: URL? = nil
  ) throws -> ProjectLock {
    let directory =
      lockDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "container-compose-locks", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let url = directory.appendingPathComponent("\(projectName).lock")
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw ComposeError("could not open project lock at \(url.path): \(posixError())")
    }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let holder = (try? String(contentsOf: url, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      Darwin.close(descriptor)
      throw ComposeError(
        "project '\(projectName)' is already being modified"
          + (holder?.isEmpty == false ? " by \(holder!)" : ""))
    }

    let lock = ProjectLock(descriptor: descriptor)
    do {
      let holder = Holder(
        pid: getpid(), command: command, workingDirectory: workingDirectory)
      let data = try JSONEncoder.compose(prettyPrinted: false).encode(holder)
      guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw ComposeError("could not initialize project lock at \(url.path): \(posixError())")
      }
      let written = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress, bytes.count)
      }
      guard written == data.count else {
        throw ComposeError("could not write project lock metadata at \(url.path): \(posixError())")
      }
      return lock
    } catch {
      lock.unlock()
      throw error
    }
  }

  public func unlock() {
    stateLock.withLock {
      guard isHeld else { return }
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      isHeld = false
    }
  }

  private static func posixError() -> String {
    String(cString: strerror(errno))
  }
}
