import Foundation
import Capacitor
import WebKit

extension UIColor {

    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let components = (
            R: CGFloat((int >> 16) & 0xff) / 255,
            G: CGFloat((int >> 08) & 0xff) / 255,
            B: CGFloat((int >> 00) & 0xff) / 255
        )
        self.init(red: components.R, green: components.G, blue: components.B, alpha: 1)
    }

}

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(InAppBrowserPlugin)
public class InAppBrowserPlugin: CAPPlugin {
    var navigationWebViewController: UINavigationController?
    private var privacyScreen: UIImageView?
    private var isSetupDone = false
    var currentPluginCall: CAPPluginCall?
    var isPresentAfterPageLoad = false
    var webViewController: WKWebViewController?

    private func setup() {
        self.isSetupDone = true

        #if swift(>=4.2)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        #else
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: .UIApplicationDidBecomeActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive(_:)), name: .UIApplicationWillResignActive, object: nil)
        #endif
    }

    func presentView(isAnimated: Bool = true) {
        self.bridge?.viewController?.present(self.navigationWebViewController!, animated: isAnimated, completion: {
            self.currentPluginCall?.resolve()
        })
    }

    @objc func clearAllCookies(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([WKWebsiteDataTypeCookies])

            dataStore.removeData(ofTypes: dataTypes,
                                 modifiedSince: Date(timeIntervalSince1970: 0)) {
                call.resolve()
            }
        }
    }

    @objc func clearCache(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])

            dataStore.removeData(ofTypes: dataTypes,
                                 modifiedSince: Date(timeIntervalSince1970: 0)) {
                call.resolve()
            }
        }
    }

    @objc func clearCookies(_ call: CAPPluginCall) {
        guard let url = call.getString("url"),
              let host = URL(string: url)?.host else {
            call.reject("Invalid URL")
            return
        }

        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                for cookie in cookies {

                    if cookie.domain == host || cookie.domain.hasSuffix(".\(host)") || host.hasSuffix(cookie.domain) {
                        let semaphore = DispatchSemaphore(value: 1)
                        WKWebsiteDataStore.default().httpCookieStore.delete(cookie) {
                            semaphore.signal()
                        }
                        semaphore.wait()
                    }
                }

                call.resolve()
            }
        }
    }

    @objc func getCookies(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? ""
        let includeHttpOnly = call.getBool("includeHttpOnly") ?? true

        guard let url = URL(string: urlString), let host = url.host else {
            call.reject("Invalid URL")
            return
        }

        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var cookieDict = [String: String]()
                for cookie in cookies {

                    if (includeHttpOnly || !cookie.isHTTPOnly) && (cookie.domain == host || cookie.domain.hasSuffix(".\(host)") || host.hasSuffix(cookie.domain)) {
                        cookieDict[cookie.name] = cookie.value
                    }
                }
                call.resolve(cookieDict)
            }
        }

    }

    @objc func openWebView(_ call: CAPPluginCall) {
        if !self.isSetupDone {
            self.setup()
        }
        self.currentPluginCall = call

        guard let urlString = call.getString("url") else {
            call.reject("Must provide a URL to open")
            return
        }

        if urlString.isEmpty {
            call.reject("URL must not be empty")
            return
        }

        var buttonNearDoneIcon: UIImage?
        if let buttonNearDoneSettings = call.getObject("buttonNearDone") {
            guard let iosSettingsRaw = buttonNearDoneSettings["ios"] else {
                call.reject("IOS settings not found")
                return
            }
            if !(iosSettingsRaw is JSObject) {
                call.reject("IOS settings are not an object")
                return
            }
            let iosSettings = iosSettingsRaw as! JSObject

            guard let iconType = iosSettings["iconType"] as? String else {
                call.reject("buttonNearDone.iconType is empty")
                return
            }
            if iconType != "sf-symbol" && iconType != "asset" {
                call.reject("IconType is neither 'sf-symbol' nor 'asset'")
                return
            }
            guard let icon = iosSettings["icon"] as? String else {
                call.reject("buttonNearDone.icon is empty")
                return
            }

            if iconType == "sf-symbol" {
                buttonNearDoneIcon = UIImage(systemName: icon)
            } else {
                // UIImage(resource: ImageResource(name: "public/monkey.svg", bundle: Bundle.main))
                buttonNearDoneIcon = UIImage(named: icon, in: Bundle.main, with: nil)
            }
        }

        let headers = call.getObject("headers", [:]).mapValues { String(describing: $0 as Any) }
        let closeModal = call.getBool("closeModal", false)
        let closeModalTitle = call.getString("closeModalTitle", "Close")
        let closeModalDescription = call.getString("closeModalDescription", "Are you sure you want to close this window?")
        let closeModalOk = call.getString("closeModalOk", "OK")
        let closeModalCancel = call.getString("closeModalCancel", "Cancel")
        let isInspectable = call.getBool("isInspectable", false)
        let preventDeeplink = call.getBool("preventDeeplink", false)
        let isAnimated = call.getBool("isAnimated", true)

        var disclaimerContent = call.getObject("shareDisclaimer")
        let toolbarType = call.getString("toolbarType", "")
        let backgroundColor = call.getString("backgroundColor", "black") == "white" ? UIColor.white : UIColor.black
        if toolbarType != "activity" {
            disclaimerContent = nil
        }
        let ignoreUntrustedSSLError = call.getBool("ignoreUntrustedSSLError", false)

        self.isPresentAfterPageLoad = call.getBool("isPresentAfterPageLoad", false)
        let showReloadButton = call.getBool("showReloadButton", false)

        let credentials = self.readCredentials(call)

        DispatchQueue.main.async {
            let url = URL(string: urlString)

            if self.isPresentAfterPageLoad {
                self.webViewController = WKWebViewController.init(url: url!, headers: headers, isInspectable: isInspectable, credentials: credentials, preventDeeplink: preventDeeplink)
            } else {
                self.webViewController = WKWebViewController.init()
                self.webViewController?.setHeaders(headers: headers)
                self.webViewController?.setCredentials(credentials: credentials)
                self.webViewController?.setPreventDeeplink(preventDeeplink: preventDeeplink)
            }

            self.webViewController?.source = .remote(url!)
            self.webViewController?.leftNavigationBarItemTypes = self.getToolbarItems(toolbarType: toolbarType) + [.reload]
            self.webViewController?.leftNavigationBarItemTypes = self.getToolbarItems(toolbarType: toolbarType)
            self.webViewController?.toolbarItemTypes = []
            self.webViewController?.doneBarButtonItemPosition = .right

            self.webViewController?.buttonNearDoneIcon = buttonNearDoneIcon

            if call.getBool("showArrow", false) {
                self.webViewController?.stopBarButtonItemImage = UIImage(named: "Forward@3x", in: Bundle(for: InAppBrowserPlugin.self), compatibleWith: nil)
            }

            self.webViewController?.capBrowserPlugin = self
            self.webViewController?.title = call.getString("title", "New Window")
            self.webViewController?.shareSubject = call.getString("shareSubject")
            self.webViewController?.shareDisclaimer = disclaimerContent
            self.webViewController?.preShowScript = call.getString("preShowScript")
            self.webViewController?.websiteTitleInNavigationBar = call.getBool("visibleTitle", true)
            if closeModal {
                self.webViewController?.closeModal = true
                self.webViewController?.closeModalTitle = closeModalTitle
                self.webViewController?.closeModalDescription = closeModalDescription
                self.webViewController?.closeModalOk = closeModalOk
                self.webViewController?.closeModalCancel = closeModalCancel
            }
            self.webViewController?.ignoreUntrustedSSLError = ignoreUntrustedSSLError
            self.navigationWebViewController = UINavigationController.init(rootViewController: self.webViewController!)
            self.navigationWebViewController?.navigationBar.isTranslucent = false
            self.navigationWebViewController?.toolbar.isTranslucent = false
            self.navigationWebViewController?.navigationBar.backgroundColor = backgroundColor
            self.navigationWebViewController?.toolbar.backgroundColor = backgroundColor
            self.navigationWebViewController?.toolbar.tintColor = backgroundColor == UIColor.black ? UIColor.white : UIColor.black
            self.navigationWebViewController?.modalPresentationStyle = .fullScreen
            if toolbarType == "blank" {
                self.navigationWebViewController?.navigationBar.isHidden = true
            }
            if showReloadButton {
                let toolbarItems = self.getToolbarItems(toolbarType: toolbarType)
                self.webViewController?.leftNavigationBarItemTypes = toolbarItems + [.reload]
            }
            if !self.isPresentAfterPageLoad {
                self.presentView(isAnimated: isAnimated)
            }
            call.resolve()
        }
    }

    func getToolbarItems(toolbarType: String) -> [BarButtonItemType] {
        var result: [BarButtonItemType] = []
        if toolbarType == "activity" {
            result.append(.activity)
        } else if toolbarType == "navigation" {
            result.append(.back)
            result.append(.forward)
        }
        return result
    }

    @objc func reload(_ call: CAPPluginCall) {
        self.webViewController?.reload()
        call.resolve()
    }

    @objc func setUrl(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url") else {
            call.reject("Cannot get new url to set")
            return
        }

        guard let url = URL(string: urlString) else {
            call.reject("Invalid URL")
            return
        }

        self.webViewController?.load(remote: url)
        call.resolve()
    }

    @objc func executeScript(_ call: CAPPluginCall) {
        guard let script = call.getString("code") else {
            call.reject("Cannot get script to execute")
            return
        }
        self.webViewController?.executeScript(script: script)
        call.resolve()
    }

    @objc func postMessage(_ call: CAPPluginCall) {
        let eventData = call.getObject("detail", [:])
        // Check if eventData is empty
        if eventData.isEmpty {
            call.reject("Event data must not be empty")
            return
        }
        print("Event data: \(eventData)")

        self.webViewController?.postMessageToJS(message: eventData)
        call.resolve()
    }

    func isHexColorCode(_ input: String) -> Bool {
        let hexColorRegex = "^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$"

        do {
            let regex = try NSRegularExpression(pattern: hexColorRegex)
            let range = NSRange(location: 0, length: input.utf16.count)
            if let _ = regex.firstMatch(in: input, options: [], range: range) {
                return true
            }
        } catch {
            print("Error creating regular expression: \(error)")
        }

        return false
    }

    @objc func open(_ call: CAPPluginCall) {
        if !self.isSetupDone {
            self.setup()
        }

        let isInspectable = call.getBool("isInspectable", false)
        let preventDeeplink = call.getBool("preventDeeplink", false)

        self.currentPluginCall = call

        guard let urlString = call.getString("url") else {
            call.reject("Must provide a URL to open")
            return
        }

        if urlString.isEmpty {
            call.reject("URL must not be empty")
            return
        }

        let headers = call.getObject("headers", [:]).mapValues { String(describing: $0 as Any) }

        self.isPresentAfterPageLoad = call.getBool("isPresentAfterPageLoad", false)

        let credentials = self.readCredentials(call)

        DispatchQueue.main.async {
            let url = URL(string: urlString)

            if self.isPresentAfterPageLoad {
                self.webViewController = WKWebViewController.init(url: url!, headers: headers, isInspectable: isInspectable, credentials: credentials, preventDeeplink: preventDeeplink)
            } else {
                self.webViewController = WKWebViewController.init()
                self.webViewController?.setHeaders(headers: headers)
                self.webViewController?.setCredentials(credentials: credentials)
                self.webViewController?.setPreventDeeplink(preventDeeplink: preventDeeplink)
            }

            self.webViewController?.source = .remote(url!)
            self.webViewController?.leftNavigationBarItemTypes = [.reload]
            self.webViewController?.toolbarItemTypes = [.back, .forward, .activity]
            self.webViewController?.capBrowserPlugin = self
            self.webViewController?.hasDynamicTitle = true
            self.navigationWebViewController = UINavigationController.init(rootViewController: self.webViewController!)
            self.navigationWebViewController?.navigationBar.isTranslucent = false
            self.navigationWebViewController?.toolbar.isTranslucent = false
            self.navigationWebViewController?.navigationBar.backgroundColor = .white
            let inputString: String = call.getString("toolbarColor", "#ffffff")
            var color: UIColor = UIColor(hexString: "#ffffff")
            if self.isHexColorCode(inputString) {
                color = UIColor(hexString: inputString)
            } else {
                print("\(inputString) is not a valid hex color code.")
            }
            self.navigationWebViewController?.toolbar.backgroundColor = color
            self.navigationWebViewController?.modalPresentationStyle = .fullScreen
            if !self.isPresentAfterPageLoad {
                self.presentView()
            }
            call.resolve()
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.navigationWebViewController?.dismiss(animated: true, completion: nil)
            self.notifyListeners("closeEvent", data: ["url": self.webViewController?.url?.absoluteString ?? ""])
            call.resolve()
        }
    }

    private func showPrivacyScreen() {
        if privacyScreen == nil {
            self.privacyScreen = UIImageView()
            if let launchImage = UIImage(named: "LaunchImage") {
                privacyScreen!.image = launchImage
                privacyScreen!.frame = UIScreen.main.bounds
                privacyScreen!.contentMode = .scaleAspectFill
                privacyScreen!.isUserInteractionEnabled = false
            } else if let launchImage = UIImage(named: "Splash") {
                privacyScreen!.image = launchImage
                privacyScreen!.frame = UIScreen.main.bounds
                privacyScreen!.contentMode = .scaleAspectFill
                privacyScreen!.isUserInteractionEnabled = false
            }
        }
        self.navigationWebViewController?.view.addSubview(self.privacyScreen!)
    }

    private func hidePrivacyScreen() {
        self.privacyScreen?.removeFromSuperview()
    }

    @objc func appDidBecomeActive(_ notification: NSNotification) {
        self.hidePrivacyScreen()
    }

    @objc func appWillResignActive(_ notification: NSNotification) {
        self.showPrivacyScreen()
    }

    private func readCredentials(_ call: CAPPluginCall) -> WKWebViewCredentials? {
        var credentials: WKWebViewCredentials?
        let credentialsDict = call.getObject("credentials", [:]).mapValues { String(describing: $0 as Any) }
        if !credentialsDict.isEmpty, let username = credentialsDict["username"], let password = credentialsDict["password"] {
            credentials = WKWebViewCredentials(username: username, password: password)
        }
        return credentials
    }
}