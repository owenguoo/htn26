import ExpoModulesCore
import SwiftUI

/// Hosts the SwiftUI operator interface inside a React Native view.
///
/// One native view, the whole screen: camera preview, guidance, seat picker,
/// mini-map. React only decides *whether* it is on screen. It finds the running
/// session by itself through `SwarmRuntime`, so it can be mounted before or
/// after `join` without JS having to sequence anything.
///
// DEVICE-VERIFY: a human must confirm on hardware that the hosted view fills the
// screen under the status bar and home indicator (safe areas are SwiftUI's, not
// React's), that the idle timer stays off while it is up, and that backgrounding
// and returning leaves the preview running and the session in `recalibrating`.
final class OperatorExpoView: ExpoView {
  let onRequestLeave = EventDispatcher()

  var showDebug = true { didSet { render() } }
  var showMiniMap = true { didSet { render() } }

  private let model = OperatorViewModel()
  private var host: UIHostingController<OperatorView>?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black
    render()
  }

  private func makeRoot() -> OperatorView {
    OperatorView(model: model, showDebug: showDebug, showMiniMap: showMiniMap,
                 onRequestLeave: { [weak self] in self?.onRequestLeave([:]) })
  }

  private func render() {
    if let host {
      host.rootView = makeRoot()
      return
    }
    let controller = UIHostingController(rootView: makeRoot())
    controller.view.backgroundColor = .clear
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.frame = bounds
    addSubview(controller.view)
    host = controller
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    host?.view.frame = bounds
  }

  /// A hosting controller that is nobody's child gets no safe-area insets, and
  /// SwiftUI then draws under the status bar and the home indicator. Parenting
  /// it to whichever controller owns this view is what makes them arrive.
  private func adoptHost() {
    guard let host, host.parent == nil, let parent = nearestViewController() else { return }
    parent.addChild(host)
    host.didMove(toParent: parent)
  }

  private func releaseHost() {
    guard let host, host.parent != nil else { return }
    host.willMove(toParent: nil)
    host.removeFromParent()
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { releaseHost() } else { adoptHost() }
    // SwiftUI's onAppear/onDisappear also do this; a hosted view that is
    // detached without disappearing would otherwise keep consuming frames.
    if window == nil { model.detach() } else { model.attach() }
  }
}
