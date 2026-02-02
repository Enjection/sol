import Foundation
import CoreGraphics

// Moves windows across Spaces by communicating with yabai's scripting addition
// injected into the Dock process. Also uses private SkyLight APIs via dlsym
// to query the current space ID.
final class SpacesMover {
  private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
  private typealias CGSGetActiveSpaceFunc = @convention(c) (Int32) -> UInt64

  private static let skylight: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
  }()

  private static let slsMainConnectionID: SLSMainConnectionIDFunc? = {
    guard let handle = skylight, let sym = dlsym(handle, "SLSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: SLSMainConnectionIDFunc.self)
  }()

  private static let cgsGetActiveSpace: CGSGetActiveSpaceFunc? = {
    guard let handle = skylight, let sym = dlsym(handle, "CGSGetActiveSpace") else { return nil }
    return unsafeBitCast(sym, to: CGSGetActiveSpaceFunc.self)
  }()

  private typealias SLSCopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> CFArray?

  private static let slsCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunc? = {
    guard let handle = skylight, let sym = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
    return unsafeBitCast(sym, to: SLSCopyManagedDisplaySpacesFunc.self)
  }()

  private static func saSocketPath() -> String {
    let user = NSUserName()
    return "/tmp/yabai-sa_\(user).socket"
  }

  /// Send a WINDOW_TO_SPACE command to the yabai SA via Unix socket.
  /// Wire format: [int16_t length][uint8_t opcode=0x13][uint64_t spaceID][uint32_t windowID]
  private static func sendMoveCommand(windowID: UInt32, spaceID: UInt64) -> Bool {
    let path = saSocketPath()

    let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sockfd >= 0 else { return false }
    defer {
      shutdown(sockfd, SHUT_RDWR)
      close(sockfd)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
        path.withCString { cstr in
          strlcpy(buf, cstr, 104)
        }
      }
      _ = bound
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else { return false }

    // Build the message
    let opcode: UInt8 = 0x13 // SA_OPCODE_WINDOW_TO_SPACE
    let payloadLength: Int16 = 1 + 8 + 4 // opcode + sid + wid
    var buf = Data(capacity: 2 + Int(payloadLength))

    var len = payloadLength
    buf.append(Data(bytes: &len, count: 2))

    var op = opcode
    buf.append(Data(bytes: &op, count: 1))

    var sid = spaceID
    buf.append(Data(bytes: &sid, count: 8))

    var wid = windowID
    buf.append(Data(bytes: &wid, count: 4))

    let sent = buf.withUnsafeBytes { ptr in
      send(sockfd, ptr.baseAddress!, buf.count, 0)
    }
    guard sent == buf.count else { return false }

    // Read ACK (1 byte)
    var ack: UInt8 = 0
    _ = recv(sockfd, &ack, 1, 0)

    return true
  }

  private static func log(_ msg: String) {
    let line = "[\(Date())] SpacesMover: \(msg)\n"
    let path = "/tmp/sol-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(line.data(using: .utf8)!)
      handle.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
  }

  /// Get ordered list of space IDs for the current display using SLSCopyManagedDisplaySpaces.
  static func getOrderedSpaceIDs() -> [UInt64] {
    guard let getConn = slsMainConnectionID,
          let copySpaces = slsCopyManagedDisplaySpaces else {
      log("could not load SkyLight space enumeration APIs")
      return []
    }

    let connID = getConn()
    guard let displaysInfo = copySpaces(connID) as? [[String: Any]] else {
      log("SLSCopyManagedDisplaySpaces returned nil or unexpected type")
      return []
    }

    var spaceIDs: [UInt64] = []
    for displayInfo in displaysInfo {
      guard let spaces = displayInfo["Spaces"] as? [[String: Any]] else { continue }
      for space in spaces {
        // "ManagedSpaceID" is the space ID; type 0 = user space
        if let sid = space["ManagedSpaceID"] as? UInt64,
           let type = space["type"] as? Int,
           type == 0 {
          spaceIDs.append(sid)
        }
      }
    }
    return spaceIDs
  }

  /// Send a SPACE_FOCUS command to the yabai SA via Unix socket.
  /// Wire format: [int16_t length][uint8_t opcode=0x02][uint64_t spaceID]
  private static func sendFocusSpaceCommand(spaceID: UInt64) -> Bool {
    let path = saSocketPath()

    let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sockfd >= 0 else { return false }
    defer {
      shutdown(sockfd, SHUT_RDWR)
      close(sockfd)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
        path.withCString { cstr in
          strlcpy(buf, cstr, 104)
        }
      }
      _ = bound
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else { return false }

    let opcode: UInt8 = 0x02 // SA_OPCODE_SPACE_FOCUS
    let payloadLength: Int16 = 1 + 8 // opcode + spaceID
    var buf = Data(capacity: 2 + Int(payloadLength))

    var len = payloadLength
    buf.append(Data(bytes: &len, count: 2))

    var op = opcode
    buf.append(Data(bytes: &op, count: 1))

    var sid = spaceID
    buf.append(Data(bytes: &sid, count: 8))

    let sent = buf.withUnsafeBytes { ptr in
      send(sockfd, ptr.baseAddress!, buf.count, 0)
    }
    guard sent == buf.count else { return false }

    var ack: UInt8 = 0
    _ = recv(sockfd, &ack, 1, 0)

    return true
  }

  /// Focus workspace by 1-based index (ws1 = index 1, ws2 = index 2, etc.)
  static func focusSpace(index: Int) {
    let spaceIDs = getOrderedSpaceIDs()
    guard index >= 1, index <= spaceIDs.count else {
      log("focusSpace: index \(index) out of range (have \(spaceIDs.count) spaces)")
      return
    }

    let targetSpaceID = spaceIDs[index - 1]
    if sendFocusSpaceCommand(spaceID: targetSpaceID) {
      log("focused space \(index) (spaceID=\(targetSpaceID))")
    } else {
      log("failed to focus space \(index) (is yabai SA loaded?)")
    }
  }

  static func moveWindowToCurrentSpace(windowID: CGWindowID) {
    guard let getConn = slsMainConnectionID,
          let getSpace = cgsGetActiveSpace else {
      SpacesMover.log(" could not load SkyLight APIs")
      return
    }

    let connectionID = getConn()
    let currentSpaceID = getSpace(connectionID)

    if currentSpaceID == 0 {
      SpacesMover.log(" could not get current space ID")
      return
    }

    if sendMoveCommand(windowID: windowID, spaceID: currentSpaceID) {
      SpacesMover.log("sent move command for window \(windowID) to space \(currentSpaceID)")
    } else {
      SpacesMover.log(" failed to send move command (is yabai SA loaded?)")
    }
  }
}
