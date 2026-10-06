import Libmpv
import OpenGLES
import QuartzCore
import UIKit

// iOS counterpart of Sources/Tuner/Player/MPVVideoLayer.swift. Same types and initialisers
// (`MPVRenderer(handle:)`, `MPVVideoLayer(renderer:)`, `MPVVideoView(videoLayer:)`), so `MPVEngine` is shared
// unchanged. libmpv's OpenGL render API draws into an OpenGL ES 3 framebuffer backed by a `CAEAGLLayer`
// (MPVKit's GPL build, linked statically).

// MARK: - CMPV stand-ins

// On macOS libmpv is dlopen'ed through the CMPV shim. On iOS it's linked in, so it's always loaded.
func cmpv_is_loaded() -> Int32 { 1 }
func cmpv_load(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int32) -> Int32 { 1 }

/// GL entry points for libmpv. The app links OpenGLES, so the process-wide symbol table has them.
private func glProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
}

// MARK: - Renderer

/// Owns the EAGL context, the layer's framebuffer and the libmpv render context for one mpv core.
///
/// Threading: every GL and `mpv_render_*` call runs on `queue` (serial), with the context made current
/// first. iOS kills apps that use the GPU in the background, so while the app is inactive no frame is
/// drawn, and mpv's video track is switched off so audio keeps playing without decoding video.
final class MPVRenderer: @unchecked Sendable {
    /// `MPV_RENDER_API_TYPE_OPENGL` ("opengl") as a C string that lives for the whole process.
    private static let apiType = UnsafeMutableRawPointer(strdup("opengl")!)

    let glContext: EAGLContext
    /// Serial queue that consumes render updates and draws.
    let queue = DispatchQueue(label: "app.tuner.mpv.render", qos: .userInteractive)
    /// The layer to draw into. Weak: the layer owns the renderer.
    weak var layer: MPVVideoLayer?

    private let handle: OpaquePointer
    private var renderContext: OpaquePointer?
    // Render-queue state.
    private var framebuffer: GLuint = 0
    private var colorbuffer: GLuint = 0
    private var drawableWidth: GLint = 0
    private var drawableHeight: GLint = 0
    private var needsStorage = true
    private var isSuspended = false
    private var observers: [NSObjectProtocol] = []

    /// Creates the GL context and the mpv render context. Must be called before the mpv core starts
    /// playback (vo=libmpv needs a render context to initialise video).
    init?(handle: OpaquePointer) {
        guard let context = EAGLContext(api: .openGLES3) else { return nil }
        self.glContext = context
        self.handle = handle
        let result: Int32 = queue.sync {
            EAGLContext.setCurrent(context)
            defer { EAGLContext.setCurrent(nil) }
            var created: OpaquePointer?
            var initParams = mpv_opengl_init_params(get_proc_address: glProcAddress, get_proc_address_ctx: nil)
            let result = withUnsafeMutablePointer(to: &initParams) { initPtr -> Int32 in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: MPVRenderer.apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&created, handle, &params)
            }
            renderContext = created
            return result
        }
        guard result >= 0, let renderContext else {
            NSLog("Tuner: mpv_render_context_create failed: %s", mpv_error_string(result))
            return nil
        }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            // Called on an mpv thread: no mpv calls here, just hop to the render queue.
            guard let ctx else { return }
            Unmanaged<MPVRenderer>.fromOpaque(ctx).takeUnretainedValue().scheduleUpdate()
        }, Unmanaged.passUnretained(self).toOpaque())
        observeAppState()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: App state

    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setSuspended(true)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setSuspended(false)
        })
    }

    private func setSuspended(_ suspended: Bool) {
        // Synchronous: the GPU must be idle before the app finishes entering the background.
        queue.sync {
            guard isSuspended != suspended, renderContext != nil else { return }
            isSuspended = suspended
            if suspended {
                EAGLContext.setCurrent(glContext)
                glFinish()
                EAGLContext.setCurrent(nil)
            }
        }
        // No video decoding in the background (audio continues); bring it back on return.
        mpv_set_property_string(handle, "vid", suspended ? "no" : "auto")
    }

    // MARK: Layer

    /// The layer's size or scale changed: re-create the drawable storage before the next frame.
    func layerDidResize() {
        queue.async { [weak self] in
            guard let self else { return }
            needsStorage = true
            drawCurrentFrame()
        }
    }

    // MARK: Render loop

    /// mpv signalled that something changed (usually a new frame).
    private func scheduleUpdate() {
        queue.async { [weak self] in self?.processUpdate() }
    }

    private func processUpdate() {
        guard let renderContext else { return }
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(nil) }
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        if !draw(renderContext, block: true) { skipFrame(renderContext) }
    }

    /// Redraws after a resize (no new frame from mpv; just re-render the current one).
    private func drawCurrentFrame() {
        guard let renderContext else { return }
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(nil) }
        _ = draw(renderContext, block: false)
    }

    /// Renders into the layer's framebuffer and presents it. False when there's nothing to draw into
    /// (no layer, zero size, background).
    private func draw(_ renderContext: OpaquePointer, block: Bool) -> Bool {
        guard !isSuspended, let layer, prepareStorage(for: layer) else { return false }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        var target = mpv_opengl_fbo(fbo: Int32(framebuffer), w: drawableWidth, h: drawableHeight, internal_format: 0)
        var flip: Int32 = 1
        var blockTime: Int32 = block ? 1 : 0
        withUnsafeMutablePointer(to: &target) { targetPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &blockTime) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(targetPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(renderContext, &params)
                }
            }
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
        glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
        return true
    }

    /// (Re)allocates the colour renderbuffer from the layer when its size changed. False if unusable.
    private func prepareStorage(for layer: MPVVideoLayer) -> Bool {
        if framebuffer == 0 {
            glGenFramebuffers(1, &framebuffer)
            glGenRenderbuffers(1, &colorbuffer)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorbuffer)
            needsStorage = true
        }
        if needsStorage {
            needsStorage = false
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
            guard glContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer) else {
                drawableWidth = 0
                drawableHeight = 0
                return false
            }
            glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &drawableWidth)
            glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &drawableHeight)
        }
        return drawableWidth > 0 && drawableHeight > 0
    }

    /// Tells mpv the frame was consumed without drawing, so its video timing doesn't stall.
    private func skipFrame(_ renderContext: OpaquePointer) {
        var skip: Int32 = 1
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &skip) { skipPtr in
            withUnsafeMutablePointer(to: &block) { blockPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: UnsafeMutableRawPointer(skipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(renderContext, &params)
            }
        }
    }

    /// Unregisters the update callback and frees the render context and GL objects. Must run before
    /// `mpv_terminate_destroy`. Idempotent. Call on `queue`.
    func destroy() {
        guard let renderContext else { return }
        EAGLContext.setCurrent(glContext)
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
        if colorbuffer != 0 { glDeleteRenderbuffers(1, &colorbuffer) }
        framebuffer = 0
        colorbuffer = 0
        EAGLContext.setCurrent(nil)
    }
}

// MARK: - Layer and view

/// The OpenGL ES drawable mpv renders into.
final class MPVVideoLayer: CAEAGLLayer {
    let renderer: MPVRenderer

    init(renderer: MPVRenderer) {
        self.renderer = renderer
        super.init()
        isOpaque = true
        backgroundColor = UIColor.black.cgColor
        drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
        ]
        renderer.layer = self
    }

    /// Core Animation makes copies (presentation layers) through this initialiser.
    override init(layer: Any) {
        if let other = layer as? MPVVideoLayer {
            renderer = other.renderer
        } else {
            fatalError("MPVVideoLayer copied from \(type(of: layer))")
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Hosts `MPVVideoLayer` and keeps its frame and pixel scale in sync with the view.
final class MPVVideoView: UIView {
    let videoLayer: MPVVideoLayer

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        layer.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard videoLayer.frame != bounds || videoLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        CATransaction.commit()
        videoLayer.renderer.layerDidResize()
    }
}
