import AppKit
import CMPV
import OpenGL.GL3
import QuartzCore

/// Owns the OpenGL context and the libmpv render context for one mpv core.
///
/// Threading: every `mpv_render_*` call happens with the GL context current and under `lock`,
/// always taking the CGL context lock first (same order as Core Animation's draw path), so the
/// render queue, Core Animation (main-thread resizes) and teardown never use the context at once.
final class MPVRenderer: @unchecked Sendable {
    /// `MPV_RENDER_API_TYPE_OPENGL` ("opengl") as a C string that lives for the whole process.
    private static let apiType = UnsafeMutableRawPointer(strdup("opengl")!)

    let pixelFormat: CGLPixelFormatObj
    let glContext: CGLContextObj
    /// Serial queue that consumes render updates and drives `layer.display()`.
    let queue = DispatchQueue(label: "app.tuner.mpv.render", qos: .userInteractive)
    /// The model layer to display when mpv has a new frame. Weak: the layer owns the renderer.
    weak var layer: MPVVideoLayer?

    private let lock = NSLock()
    private var renderContext: OpaquePointer?
    private var drawCount: UInt64 = 0

    /// Creates the GL context and the mpv render context. Must be called before the mpv core
    /// starts playback (vo=libmpv needs a render context to initialise video).
    init?(handle: OpaquePointer) {
        guard let pixelFormat = MPVRenderer.makePixelFormat() else { return nil }
        var context: CGLContextObj?
        guard CGLCreateContext(pixelFormat, nil, &context) == kCGLNoError, let context else {
            CGLReleasePixelFormat(pixelFormat)
            return nil
        }
        // Lets the GL driver work on its own thread (as IINA does).
        CGLEnable(context, kCGLCEMPEngine)
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        self.pixelFormat = pixelFormat
        self.glContext = context

        let previous = CGLGetCurrentContext()
        CGLLockContext(context)
        CGLSetCurrentContext(context)
        var created: OpaquePointer?
        var initParams = mpv_opengl_init_params(get_proc_address: cmpv_gl_get_proc_address, get_proc_address_ctx: nil)
        let result = withUnsafeMutablePointer(to: &initParams) { initPtr -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: MPVRenderer.apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_create(&created, handle, &params)
        }
        CGLSetCurrentContext(previous)
        CGLUnlockContext(context)
        guard result >= 0, let created else {
            NSLog("Tuner: mpv_render_context_create failed: %s", mpv_error_string(result))
            return nil
        }
        renderContext = created
        mpv_render_context_set_update_callback(created, { ctx in
            // Called on an mpv thread: no mpv calls here, just hop to the render queue.
            guard let ctx else { return }
            Unmanaged<MPVRenderer>.fromOpaque(ctx).takeUnretainedValue().scheduleUpdate()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        // `destroy()` normally ran already; this only covers a renderer dropped without teardown.
        if renderContext != nil { destroy() }
        CGLReleaseContext(glContext)
        CGLReleasePixelFormat(pixelFormat)
    }

    private static func makePixelFormat() -> CGLPixelFormatObj? {
        let core = CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue))
        let attributeSets: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, core, kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers],
            [kCGLPFAOpenGLProfile, core, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers],
            [kCGLPFAOpenGLProfile, core],
        ]
        for attributes in attributeSets {
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            let terminated = attributes + [CGLPixelFormatAttribute(0)]
            if CGLChoosePixelFormat(terminated, &pixelFormat, &count) == kCGLNoError, let pixelFormat {
                return pixelFormat
            }
        }
        return nil
    }

    // MARK: - Render loop

    /// mpv signalled that something changed (usually a new frame).
    private func scheduleUpdate() {
        queue.async { [weak self] in self?.processUpdate() }
    }

    private func processUpdate() {
        let flags = withContextLocked { context -> UInt64 in
            mpv_render_context_update(context)
        } ?? 0
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let before = currentDrawCount
        if let layer { layer.display() }
        // Off-screen or zero-sized layers are never drawn by Core Animation. Tell mpv the frame
        // was consumed anyway so its video timing doesn't stall waiting for us.
        if currentDrawCount == before { skipFrame() }
    }

    private var currentDrawCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return drawCount
    }

    private func skipFrame() {
        _ = withContextLocked { context -> Int32 in
            var skip: Int32 = 1
            var block: Int32 = 0
            return withUnsafeMutablePointer(to: &skip) { skipPtr in
                withUnsafeMutablePointer(to: &block) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: UnsafeMutableRawPointer(skipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }
    }

    /// Runs `body` with the CGL context locked + current and the render lock held.
    /// Returns nil once the render context has been destroyed.
    private func withContextLocked<T>(_ body: (OpaquePointer) -> T) -> T? {
        CGLLockContext(glContext)
        lock.lock()
        defer {
            lock.unlock()
            CGLUnlockContext(glContext)
        }
        guard let renderContext else { return nil }
        let previous = CGLGetCurrentContext()
        CGLSetCurrentContext(glContext)
        defer { CGLSetCurrentContext(previous) }
        return body(renderContext)
    }

    /// Renders the current video frame into `fbo` (called from the layer's draw with the GL
    /// context current). Returns false if there is nothing to render into or no render context.
    func render(fbo: GLint, width: GLint, height: GLint, blockForTargetTime: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        drawCount &+= 1
        guard let renderContext, width > 0, height > 0 else { return false }
        var target = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(width), h: Int32(height), internal_format: 0)
        var flip: Int32 = 1
        var block: Int32 = blockForTargetTime ? 1 : 0
        withUnsafeMutablePointer(to: &target) { targetPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &block) { blockPtr in
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
        return true
    }

    /// Unregisters the update callback and frees the render context with its GL context current.
    /// Must run before `mpv_terminate_destroy`. Idempotent. Call on `queue` (it may block briefly
    /// while mpv tears down its video chain).
    func destroy() {
        CGLLockContext(glContext)
        lock.lock()
        defer {
            lock.unlock()
            CGLUnlockContext(glContext)
        }
        guard let renderContext else { return }
        let previous = CGLGetCurrentContext()
        CGLSetCurrentContext(glContext)
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        CGLSetCurrentContext(previous)
    }
}

/// Video surface for libmpv's OpenGL render API (the approach IINA uses).
///
/// Synchronous `CAOpenGLLayer` driven from the renderer's serial queue: mpv's update callback hops
/// to that queue, which calls `display()`; `display()` flushes the implicit transaction so the frame
/// reaches the screen without waiting for the main run loop.
final class MPVVideoLayer: CAOpenGLLayer {
    let renderer: MPVRenderer

    init(renderer: MPVRenderer) {
        self.renderer = renderer
        super.init()
        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor
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

    // Core Animation releases what these return, so hand out +1 references to the shared objects.
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(renderer.pixelFormat)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(renderer.glContext)
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        // Main-thread draws (resizes) must not wait for the frame's display time.
        let rendered = renderer.render(fbo: fbo, width: viewport[2], height: viewport[3],
                                       blockForTargetTime: !Thread.isMainThread)
        if !rendered {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
    }

    override func display() {
        super.display()
        CATransaction.flush()
    }
}

/// Layer-hosting view for `MPVVideoLayer`; keeps the layer's scale in sync with the window.
final class MPVVideoView: NSView {
    let videoLayer: MPVVideoLayer

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        // Layer-hosting: assign the layer before enabling wantsLayer.
        layer = videoLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
    }

    private func syncScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard videoLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contentsScale = scale
        CATransaction.commit()
        videoLayer.setNeedsDisplay()
    }
}
