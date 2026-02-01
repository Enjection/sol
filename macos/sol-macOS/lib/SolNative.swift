import Foundation
import HotKey
import LaunchAtLogin

private let keychain = Keychain(service: "Sol")

private func solLog(_ msg: String) {
  let line = "[\(Date())] \(msg)\n"
  let path = "/tmp/sol-debug.log"
  if let handle = FileHandle(forWritingAtPath: path) {
    handle.seekToEndOfFile()
    handle.write(line.data(using: .utf8)!)
    handle.closeFile()
  } else {
    FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
  }
}

@objc(SolNative)
class SolNative: RCTEventEmitter {
  let appDelegate = NSApp.delegate as? AppDelegate

  override init() {
    super.init()
    SolEmitter.sharedInstance.registerEmitter(emitter: self)
    ApplicationSearcher.shared.onApplicationsChanged = {
      self.sendEvent(
        withName: "applicationsChanged",
        body: [])
    }
  }

  @objc override func constantsToExport() -> [AnyHashable: Any]! {
    return [
      "accentColor": NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        .hexString,
      "OSVersion": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    ]
  }

  @objc override func startObserving() {
    SolEmitter.sharedInstance.hasListeners = true
  }

  @objc override func stopObserving() {
    SolEmitter.sharedInstance.hasListeners = false
  }

  @objc override static func requiresMainQueueSetup() -> Bool {
    return true
  }

  func sendKeyDown(characters: String) {
    sendEvent(
      withName: "keyDown",
      body: [
        "key": characters
      ])
  }

  @objc override func supportedEvents() -> [String]? {
    return [
      "keyDown",
      "keyUp",
      "onShow",
      "onHide",
      "onTextCopied",
      "onFileCopied",
      "onFileSearch",
      "onStatusBarItemClick",
      "hotkey",
      "applicationsChanged",
    ]
  }

  @objc func getApps(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: RCTPromiseRejectBlock
  ) {
    let apps = ApplicationSearcher.shared.getAllApplications()
    resolve(apps)
  }

  @objc func openFile(_ path: String) {
    solLog("openFile called with path: \(path)")
    // If the path is a .app and it's already running, move its frontmost window
    // to the current workspace instead of switching Spaces
    let cleanPath = path.hasSuffix("/") ? String(path.dropLast()) : path
    solLog("cleanPath: \(cleanPath), hasSuffix .app: \(cleanPath.hasSuffix(".app"))")
    let appUrl: URL? = URL(fileURLWithPath: cleanPath)
    solLog("appUrl: \(String(describing: appUrl))")
    let bundle = appUrl.flatMap { Bundle(url: $0) }
    solLog("bundle: \(String(describing: bundle)), bundleId: \(String(describing: bundle?.bundleIdentifier))")
    let bundleId = bundle?.bundleIdentifier
    let runningApp = bundleId != nil ? NSRunningApplication.runningApplications(withBundleIdentifier: bundleId!).first : nil
    solLog("runningApp: \(String(describing: runningApp)), terminated: \(String(describing: runningApp?.isTerminated))")
    if cleanPath.hasSuffix(".app"),
       let appUrl = appUrl,
       let bundle = bundle,
       let bundleId = bundleId,
       let runningApp = runningApp,
       runningApp.isTerminated == false
    {
      let pid = runningApp.processIdentifier
      solLog("App is running: \(bundleId) pid=\(pid)")
      let axApp = AXUIElementCreateApplication(pid)

      // Get the focused window, or fall back to the first window
      var windowRef: AnyObject?
      var axWindow: AXUIElement?

      if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
        axWindow = (windowRef as! AXUIElement)
      } else {
        var windowList: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
           let windows = windowList as? [AXUIElement],
           let firstWindow = windows.first {
          axWindow = firstWindow
        }
      }

      var windowID: CGWindowID = 0

      if let axWindow = axWindow {
        _AXUIElementGetWindow(axWindow, &windowID)
      }

      // If AX couldn't find windows (app on another space), use CGWindowList
      if windowID == 0 {
        if let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
          var bestWid: Int = 0
          var bestArea: Int = 0
          for info in windowInfoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let wid = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Int,
                  let h = bounds["Height"] as? Int else { continue }
            let area = w * h
            if area > bestArea {
              bestArea = area
              bestWid = wid
            }
          }
          if bestWid != 0 {
            windowID = CGWindowID(bestWid)
          }
        }
      }

      solLog("windowID=\(windowID) (0 means not found)")
      if windowID != 0 {
        SpacesMover.moveWindowToCurrentSpace(windowID: windowID)
      }

      runningApp.activate()
      if let axWindow = axWindow {
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
      }
      return
    }

    // Not running or not an app — use default behavior
    NSWorkspace.shared.openFile(path)
  }

  @objc func openWithFinder(_ path: String) {
    guard let URL = URL(string: path) else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.promptsUserIfNeeded = true

    let finder = NSWorkspace.shared
      .urlForApplication(withBundleIdentifier: "com.apple.finder")
    NSWorkspace.shared.open(
      [URL],
      withApplicationAt: finder!,
      configuration: configuration
    )
  }

  @objc func toggleDarkMode() {
    DarkMode.isEnabled = !DarkMode.isEnabled
  }

  @objc func executeAppleScript(
    _ source: String, resolve: RCTPromiseResolveBlock,
    reject: RCTPromiseRejectBlock
  ) {

    let error = AppleScriptHelper.runAppleScript(source)
    if error == nil {
      resolve(nil)
    } else {
      reject(
        "AppleScriptError",
        error!["NSAppleScriptErrorMessage"] as? String,
        nil
      )
    }
  }

  @objc func executeBashScript(
    _ source: String,
    resolver: RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    let output = ShellHelper.shWithFloatingPanel(source)
    resolver(output)
  }

  @objc func getMediaInfo(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    MediaHelper.getCurrentMedia(callback: { information in
      let pathUrl = NSWorkspace.shared
        .urlForApplication(
          withBundleIdentifier: information["bundleIdentifier"]! as! String
        )?
        .path
      let imageData =
        information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

      if imageData == nil {
        resolve([
          "title": information["kMRMediaRemoteNowPlayingInfoTitle"],
          "artist": information["kMRMediaRemoteNowPlayingInfoArtist"],
          "bundleIdentifier": information["bundleIdentifier"],
          "url": pathUrl,
        ])
      } else {
        let bitmap = NSBitmapImageRep(data: imageData!)
        let data = bitmap?.representation(using: .jpeg, properties: [:])
        let base64 =
          data != nil
          ? "data:image/jpeg;base64,"
            + data!
            .base64EncodedString() : nil
        resolve([
          "title": information["kMRMediaRemoteNowPlayingInfoTitle"],
          "artist": information["kMRMediaRemoteNowPlayingInfoArtist"],
          "artwork": base64,
          "bundleIdentifier": information["bundleIdentifier"],
          "url": pathUrl,
        ])
      }

    })
  }

  @objc func setGlobalShortcut(_ key: String) {
    HotKeyManager.shared.mainHotKey.isPaused = true
    if key == "command" {
      HotKeyManager.shared.mainHotKey = HotKey(
        key: .space,
        modifiers: [.command],
        keyDownHandler: PanelManager.shared.toggle
      )
    } else if key == "option" {
      HotKeyManager.shared.mainHotKey = HotKey(
        key: .space,
        modifiers: [.option],
        keyDownHandler: PanelManager.shared.toggle
      )
    } else if key == "control" {
      HotKeyManager.shared.mainHotKey = HotKey(
        key: .space,
        modifiers: [.control],
        keyDownHandler: PanelManager.shared.toggle
      )
    }
  }

  @objc func getAccessibilityStatus(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    resolve(AXIsProcessTrusted())
  }

  @objc func requestAccessibilityAccess(
    _ resolve: @escaping RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    let options: NSDictionary = [
      kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
    ]
    let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
    resolve(accessibilityEnabled)
  }

  @objc func setLaunchAtLogin(_ enabled: Bool) {
    #if DEBUG
      return
    #else
      if LaunchAtLogin.isEnabled != enabled {
        LaunchAtLogin.isEnabled = enabled
      }
    #endif
  }

  @objc func resizeFrontmostTopHalf() {
    WindowManager.sharedInstance.moveHalf(.top)
  }

  @objc func resizeFrontmostBottomHalf() {
    WindowManager.sharedInstance.moveHalf(.bottom)
  }

  @objc func resizeFrontmostRightHalf() {
    WindowManager.sharedInstance.moveHalf(.right)
  }

  @objc func resizeFrontmostLeftHalf() {
    WindowManager.sharedInstance.moveHalf(.left)
  }

  @objc func resizeFrontmostFullscreen() {
    WindowManager.sharedInstance.fullscreen()
  }

  @objc func resizeTopLeft() {
    WindowManager.sharedInstance.moveQuarter(.topLeft)
  }

  @objc func resizeTopRight() {
    WindowManager.sharedInstance.moveQuarter(.topRight)
  }

  @objc func resizeBottomLeft() {
    WindowManager.sharedInstance.moveQuarter(.bottomLeft)
  }

  @objc func resizeBottomRight() {
    WindowManager.sharedInstance.moveQuarter(.bottomRight)
  }

  @objc func resizeLeftThird() {
    WindowManager.sharedInstance.moveThird(.left)
  }

  @objc func resizeCenterThird() {
    WindowManager.sharedInstance.moveThird(.center)
  }

  @objc func resizeRightThird() {
    WindowManager.sharedInstance.moveThird(.right)
  }

  @objc func resizeLeftTwoThirds() {
    WindowManager.sharedInstance.moveTwoThirds(.left)
  }

  @objc func resizeRightTwoThirds() {
    WindowManager.sharedInstance.moveTwoThirds(.right)
  }

  @objc func moveFrontmostNextScreen() {
    WindowManager.sharedInstance.moveToNextScreen()
  }

  @objc func moveFrontmostPrevScreen() {
    WindowManager.sharedInstance.moveToPrevScreen()
  }

  @objc func moveFrontmostCenter() {
    WindowManager.sharedInstance.center()
  }

  @objc func moveFrontmostToNextSpace() {
    WindowManager.sharedInstance.moveFrontmostToNextSpace()
  }

  @objc func moveFrontmostToPreviousSpace() {
    WindowManager.sharedInstance.moveFrontmostToPreviousSpace()
  }

  @objc func pasteToFrontmostApp(_ content: String) {
    ClipboardHelper.pasteToFrontmostApp(content)
  }

  @objc func insertToFrontmostApp(_ content: String) {
    ClipboardHelper.insertToFrontmostApp(content)
  }

  @objc func turnOnHorizontalArrowsListeners() {
    HotKeyManager.shared.catchHorizontalArrowsPress = true
  }

  @objc func turnOffHorizontalArrowsListeners() {
    HotKeyManager.shared.catchHorizontalArrowsPress = false
  }

  @objc func turnOnVerticalArrowsListeners() {
    HotKeyManager.shared.catchVerticalArrowsPress = true
  }

  @objc func turnOffVerticalArrowsListeners() {
    HotKeyManager.shared.catchVerticalArrowsPress = false
  }

  @objc func turnOnEnterListener() {
    HotKeyManager.shared.catchEnterPress = true
  }

  @objc func turnOffEnterListener() {
    HotKeyManager.shared.catchEnterPress = false
  }

  @objc func checkForUpdates() {
    appDelegate?.checkForUpdates()
  }

  @objc func setWindowRelativeSize(_ relative: NSNumber) {
    DispatchQueue.main.async {
      PanelManager.shared.setRelativeSize(relative as! Double)
    }
  }

  @objc func openFinderAt(_ path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
  }

  @objc func setShowWindowOn(_ on: String) {
    switch on {
    case "screenWithFrontmost":
      PanelManager.shared.setPreferredScreen(.frontmost)
      break
    default:
      PanelManager.shared.setPreferredScreen(.withMouse)
      break
    }
  }

  @objc func toggleDND() {
    DoNotDisturb.toggle()
  }

  @objc func securelyStore(
    _ key: NSString,
    payload: NSString,
    resolver: RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    keychain[key as String] = payload as String
    resolver(true)
  }

  @objc func securelyRetrieve(
    _ key: NSString,
    resolver resolve: RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    let value = keychain[key as String]
    return resolve(value)
  }

  @objc func showToast(_ text: String, variant: String, timeout: NSNumber) {
    DispatchQueue.main.async {
      ToastManager.shared.showToast(
        text, variant: variant, timeout: timeout, image: nil)
    }
  }

  @objc func useBackgroundOverlay(_ v: Bool) {
    //    appDelegate?.useBackgroundOverlay = v
  }

  @objc func hideNotch() {
    NotchHelper.shared.hideNotch()
  }

  @objc func showWifiQR(_ SSID: String, password: String) {
    let image = WifiQR(name: SSID, password: password)
    DispatchQueue.main.async {
      let wifiInfo = "SSID: \(SSID)\nPassword: \(password)"
      ToastManager.shared.showToast(
        wifiInfo, variant: "none", timeout: 30, image: image)
    }
  }

  @objc func hasFullDiskAccess(
    _ resolve: RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    resolve(BookmarkHelper.hasFullDiskAccess())
  }

  @objc func getSafariBookmarks(
    _ resolve: RCTPromiseResolveBlock,
    rejecter _: RCTPromiseRejectBlock
  ) {
    let bookmarks = BookmarkHelper.getSafariBookmars()
    resolve(bookmarks)
  }

  @objc func quit() {
    DispatchQueue.main.async {
      NSApplication.shared.terminate(self)
    }
  }

  @objc func setStatusBarItemTitle(_ title: String) {
    StatusBarItemManager.shared.setStatusBarTitle(title)
  }

  @objc func setMediaKeyForwardingEnabled(_ v: Bool) {
    DispatchQueue.main.async {
      self.appDelegate?.setMediaKeyForwardingEnabled(v)
    }
  }

  @objc func openFilePicker(
    _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      if panel.runModal() == .OK {
        let fileName = panel.url?.absoluteString
        resolve(fileName)
      } else {
        reject(nil, nil, nil)
      }
    }
  }

  @objc func updateHotkeys(_ hotkeys: NSDictionary) {
    guard let hotkeys = hotkeys as? [String: String] else { return }
    HotKeyManager.shared.updateHotkeys(hotkeyMap: hotkeys)
  }

  @objc func setHyperKeyEnabled(_ enabled: Bool) {
    if enabled {
      DispatchQueue.main.async {
        HotKeyManager.shared.setupCapsLockMonitoring()
      }
    } else {
      DispatchQueue.main.async {

        HotKeyManager.shared.resetCapsLockMonitoring()
      }
    }
  }

}
