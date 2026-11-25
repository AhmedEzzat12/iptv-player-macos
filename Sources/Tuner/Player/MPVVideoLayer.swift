import AppKit
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import IOSurface
#if TUNER_APP_STORE
import Libmpv
#else
import CMPV
#endif
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

    /// Picture in Picture: while its window is open, frames go to `sampleLayer` (the kind of layer the system's PiP
    /// window takes) as 16:9 pixel buffers instead of to the screen layer. Set on the main thread by `MPVVideoView`.
    var sampleLayer: AVSampleBufferDisplayLayer? {
        get { lock.withLock { sampleLayerStorage } }
        set { lock.withLock { sampleLayerStorage = newValue } }
    }
    private weak var sampleLayerStorage: AVSampleBufferDisplayLayer?
    // Render-queue state for PiP frames.
    private var framesForPictureInPicture = false
    private var pixelPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var pictureInPictureFramebuffer: GLuint = 0
    private var pictureInPictureTexture: GLuint = 0
    private static let pictureInPictureSize = (width: 1280, height: 720)

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
        if framesForPictureInPicture {
            _ = drawPictureInPictureFrame(block: true)
            return
        }
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

    // MARK: - Picture in Picture

    /// Before opening the PiP window (main thread): sends frames to the sample layer and draws the current one now.
    /// AVKit sizes the window from the layer's video and traps on a layer that never had a frame, so false means
    /// don't open it.
    func prepareForPictureInPicture() -> Bool {
        queue.sync {
            framesForPictureInPicture = true
            let drawn = drawPictureInPictureFrame(block: false)
            if !drawn { framesForPictureInPicture = false }
            return drawn
        }
    }

    /// The PiP window opened or closed (main thread). Opening draws the current frame at once: the window takes the
    /// shape of the frames it's given.
    func pictureInPictureChanged(active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            framesForPictureInPicture = active
            if active {
                _ = drawPictureInPictureFrame(block: false)
            } else {
                layer?.display()
            }
        }
    }

    /// Renders mpv's frame into a pixel buffer's IOSurface (no copy) and hands it to `sampleLayer`. Render queue.
    private func drawPictureInPictureFrame(block: Bool) -> Bool {
        guard let sampleLayer, let buffer = pixelBuffer(), let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            skipFrame()
            return false
        }
        let (width, height) = Self.pictureInPictureSize
        let drawn = withContextLocked { context -> Bool in
            let rectangle = GLenum(GL_TEXTURE_RECTANGLE)
            if pictureInPictureTexture == 0 { glGenTextures(1, &pictureInPictureTexture) }
            if pictureInPictureFramebuffer == 0 { glGenFramebuffers(1, &pictureInPictureFramebuffer) }
            glBindTexture(rectangle, pictureInPictureTexture)
            guard CGLTexImageIOSurface2D(glContext, rectangle, GLenum(GL_RGBA), GLsizei(width), GLsizei(height),
                                         GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV), surface, 0) == kCGLNoError else {
                glBindTexture(rectangle, 0)
                return false
            }
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), pictureInPictureFramebuffer)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), rectangle, pictureInPictureTexture, 0)
            var target = mpv_opengl_fbo(fbo: Int32(pictureInPictureFramebuffer), w: Int32(width), h: Int32(height), internal_format: 0)
            // Unflipped: mpv's first row lands in the buffer's first row (only the screen's framebuffer needs flipping).
            var flip: Int32 = 0
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
                        _ = mpv_render_context_render(context, &params)
                    }
                }
            }
            // The buffer goes to Core Animation next: the GPU must be done with it.
            glFinish()
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            glBindTexture(rectangle, 0)
            return true
        } ?? false
        if drawn { enqueue(buffer, on: sampleLayer) }
        return drawn
    }

    private func pixelBuffer() -> CVPixelBuffer? {
        if pixelPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.pictureInPictureSize.width,
                kCVPixelBufferHeightKey as String: Self.pictureInPictureSize.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferOpenGLCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelPool)
        }
        guard let pixelPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelPool, &buffer)
        return buffer
    }

    private func enqueue(_ buffer: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer) {
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
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
        if pictureInPictureFramebuffer != 0 { glDeleteFramebuffers(1, &pictureInPictureFramebuffer) }
        if pictureInPictureTexture != 0 { glDeleteTextures(1, &pictureInPictureTexture) }
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
    /// Picture in Picture (Settings → Playback → "Picture in Picture for all videos", read when the engine is made):
    /// the layer the system's PiP window shows. It sits invisibly over the video and only gets frames while PiP is open.
    let sampleLayer: AVSampleBufferDisplayLayer?
    private(set) var pictureInPicture: MPVPictureInPicture?

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        let wantsPictureInPicture = UserDefaults.standard.object(forKey: "mpvPictureInPicture") as? Bool ?? true
        sampleLayer = wantsPictureInPicture && AVPictureInPictureController.isPictureInPictureSupported()
            ? AVSampleBufferDisplayLayer() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        // Layer-hosting: assign the layer before enabling wantsLayer.
        layer = videoLayer
        wantsLayer = true
        if let sampleLayer {
            sampleLayer.videoGravity = .resizeAspect
            // A plain invisible sublayer the size of the video. The PiP window shows this layer as it is, unscaled, so
            // while it's open the layer takes the window's size instead (`MPVPictureInPicture`).
            sampleLayer.opacity = 0
            sampleLayer.frame = bounds
            videoLayer.addSublayer(sampleLayer)
            videoLayer.renderer.sampleLayer = sampleLayer
            pictureInPicture = MPVPictureInPicture(layer: sampleLayer, renderer: videoLayer.renderer)
            pictureInPicture?.restoreLayout = { [weak self] in self?.layOutSampleLayer() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOutSampleLayer()
    }

    /// The sample layer back at the video's size (not while the PiP window sizes it).
    func layOutSampleLayer() {
        guard let sampleLayer, pictureInPicture?.isActive != true, !bounds.isEmpty, sampleLayer.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleLayer.frame = bounds
        CATransaction.commit()
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
