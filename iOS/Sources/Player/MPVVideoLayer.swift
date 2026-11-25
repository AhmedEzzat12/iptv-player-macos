import AVFoundation
import CoreMedia
import CoreVideo
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
    /// `MPV_RENDER_API_TYPE_SW`: mpv's CPU renderer, used for Picture in Picture in the background.
    private static let softwareAPIType = UnsafeMutableRawPointer(strdup("sw")!)
    /// The CPU renderer's pixel layout: B, G, R, A bytes (a `kCVPixelFormatType_32BGRA` buffer), alpha opaque.
    private static let softwareFormat = UnsafeMutableRawPointer(strdup("bgra")!)

    /// Picture in Picture mode (Settings → Playback → "Picture in Picture for all videos", read when the engine is
    /// made). mpv draws into pixel buffers that `sampleLayer` shows, the kind of layer the system's PiP window can
    /// take, instead of into the `CAEAGLLayer`. In the background with PiP open, iOS allows no GPU work, so mpv switches
    /// to its CPU renderer until the app comes back.
    let usesSampleBuffers: Bool
    /// Pixel-buffer mode: where frames go. Set on the main thread by `MPVVideoView`.
    weak var sampleLayer: AVSampleBufferDisplayLayer?
    /// Main thread: the PiP window is showing or opening.
    var isInPictureInPicture = false

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
    // Pixel-buffer mode (render queue).
    private var isSoftware = false
    private var targetSize = CGSize.zero
    /// While in PiP: frames are drawn 16:9 (the video letterboxed inside), so the window is always landscape, however
    /// the app is held.
    private var framesForPictureInPicture = false
    private var pixelPool: CVPixelBufferPool?
    private var pixelPoolSize = CGSize.zero
    private var formatDescription: CMVideoFormatDescription?
    private var textureCache: CVOpenGLESTextureCache?
    private var textureFramebuffer: GLuint = 0
    /// The buffers can't be GL textures here (the simulator): render into a renderbuffer and read the pixels back.
    private var readsBack = false
    private var readbackRenderbuffer: GLuint = 0
    private var readbackSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []

    /// Creates the GL context and the mpv render context. Must be called before the mpv core starts
    /// playback (vo=libmpv needs a render context to initialise video).
    init?(handle: OpaquePointer) {
        guard let context = EAGLContext(api: .openGLES3) else { return nil }
        self.glContext = context
        self.handle = handle
        usesSampleBuffers = UserDefaults.standard.object(forKey: "mpvPictureInPicture") as? Bool ?? true
        let result: Int32 = queue.sync { createContext(software: false) }
        guard result >= 0, renderContext != nil else {
            NSLog("Tuner: mpv_render_context_create failed: %s", mpv_error_string(result))
            return nil
        }
        observeAppState()
    }

    /// Creates the mpv render context, OpenGL ES or CPU, and hooks up its update callback. On `queue`.
    private func createContext(software: Bool) -> Int32 {
        var created: OpaquePointer?
        let result: Int32
        if software {
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: MPVRenderer.softwareAPIType),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            result = mpv_render_context_create(&created, handle, &params)
        } else {
            EAGLContext.setCurrent(glContext)
            defer { EAGLContext.setCurrent(nil) }
            var initParams = mpv_opengl_init_params(get_proc_address: glProcAddress, get_proc_address_ctx: nil)
            result = withUnsafeMutablePointer(to: &initParams) { initPtr -> Int32 in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: MPVRenderer.apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&created, handle, &params)
            }
        }
        guard result >= 0, let created else { return result }
        renderContext = created
        isSoftware = software
        mpv_render_context_set_update_callback(created, { ctx in
            // Called on an mpv thread: no mpv calls here, just hop to the render queue.
            guard let ctx else { return }
            Unmanaged<MPVRenderer>.fromOpaque(ctx).takeUnretainedValue().scheduleUpdate()
        }, Unmanaged.passUnretained(self).toOpaque())
        return result
    }

    /// Frees the render context and the GL objects tied to it. On `queue`.
    private func freeContext() {
        guard let renderContext else { return }
        if !isSoftware { EAGLContext.setCurrent(glContext); glFinish() }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        if !isSoftware {
            if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
            if colorbuffer != 0 { glDeleteRenderbuffers(1, &colorbuffer) }
            if textureFramebuffer != 0 { glDeleteFramebuffers(1, &textureFramebuffer) }
            if readbackRenderbuffer != 0 { glDeleteRenderbuffers(1, &readbackRenderbuffer) }
            EAGLContext.setCurrent(nil)
        }
        framebuffer = 0
        colorbuffer = 0
        textureFramebuffer = 0
        readbackRenderbuffer = 0
        readbackSize = .zero
        textureCache = nil
        needsStorage = true
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: App state

    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            // In PiP the video keeps going, drawn on the CPU; otherwise only the audio plays on.
            if self.usesSampleBuffers, self.isInPictureInPicture { self.useSoftware(true) } else { self.setSuspended(true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            if self.usesSampleBuffers { self.useSoftware(false) }
            self.setSuspended(false)
        })
    }

    /// Switches between the GL and CPU renderers (pixel-buffer mode). Main thread. Video goes off first: freeing the
    /// render context while mpv's video output still used it deadlocked (mpv waited for a frame from the render queue,
    /// which was busy freeing). Then the renderer is swapped and the video track selected again.
    func useSoftware(_ software: Bool) {
        guard usesSampleBuffers else { return }
        let needed: Bool = queue.sync { renderContext != nil && isSoftware != software }
        guard needed else { return }
        let saved = mpv_get_property_string(handle, "vid").map { value -> String in
            defer { mpv_free(value) }
            return String(cString: value)
        }
        mpv_set_property_string(handle, "vid", "no")
        queue.sync {
            freeContext()
            if createContext(software: software) < 0 {
                NSLog("Tuner: mpv render context switch failed; back to %@", software ? "OpenGL" : "software")
                _ = createContext(software: !software)
            }
            isSuspended = false
        }
        mpv_set_property_string(handle, "vid", saved.flatMap { $0 == "no" ? nil : $0 } ?? "auto")
    }

    /// The PiP window opened or closed (main thread). Opening while already in the background switches to the CPU
    /// renderer; closing there leaves only the audio playing, as without PiP.
    func pictureInPictureChanged(active: Bool) {
        isInPictureInPicture = active
        let background = UIApplication.shared.applicationState == .background
        // Opening while already in the background: off the GPU before drawing anything.
        if active, background { useSoftware(true) }
        // The window takes the shape of the frames it's given: redraw the current one 16:9 at once, so it opens
        // landscape (in portrait it opened tall, the shape of the screen, until the next frame).
        queue.sync {
            framesForPictureInPicture = active
            drawCurrentFrame()
        }
        if !active, background { setSuspended(true) }
    }

    /// Pixel-buffer mode: the view's size in pixels (main thread).
    func setTargetSize(_ size: CGSize) {
        queue.async { [weak self] in
            guard let self, self.targetSize != size else { return }
            self.targetSize = size
            self.drawCurrentFrame()
        }
    }

    private func setSuspended(_ suspended: Bool) {
        // Synchronous: the GPU must be idle before the app finishes entering the background.
        queue.sync {
            guard isSuspended != suspended, renderContext != nil else { return }
            isSuspended = suspended
            if suspended, !isSoftware {
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
        // One pending update at most: when drawing falls behind mpv's frames, queued updates piled up and anything
        // else sent to the render queue (a resize, the GL/CPU switch for Picture in Picture) waited behind them.
        updateLock.lock()
        let alreadyPending = updatePending
        updatePending = true
        updateLock.unlock()
        guard !alreadyPending else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.updateLock.lock()
            self.updatePending = false
            self.updateLock.unlock()
            self.processUpdate()
        }
    }
    private let updateLock = NSLock()
    private var updatePending = false

    private func processUpdate() {
        guard let renderContext else { return }
        if !isSoftware { EAGLContext.setCurrent(glContext) }
        defer { if !isSoftware { EAGLContext.setCurrent(nil) } }
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        if !draw(renderContext, block: true) { skipFrame(renderContext) }
    }

    /// Redraws after a resize (no new frame from mpv; just re-render the current one).
    private func drawCurrentFrame() {
        guard let renderContext else { return }
        if !isSoftware { EAGLContext.setCurrent(glContext) }
        defer { if !isSoftware { EAGLContext.setCurrent(nil) } }
        _ = draw(renderContext, block: false)
    }

    /// Renders into the layer's framebuffer and presents it. False when there's nothing to draw into
    /// (no layer, zero size, background).
    private func draw(_ renderContext: OpaquePointer, block: Bool) -> Bool {
        if usesSampleBuffers { return drawIntoPixelBuffer(renderContext, block: block) }
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
        freeContext()
    }

    // MARK: Pixel-buffer mode

    /// Renders the frame into a pixel buffer and hands it to `sampleLayer`. On `queue`.
    private func drawIntoPixelBuffer(_ renderContext: OpaquePointer, block: Bool) -> Bool {
        guard !isSuspended, let layer = sampleLayer else { return false }
        let size = renderSize()
        let width = Int(size.width), height = Int(size.height)
        guard width > 1, height > 1, let buffer = pixelBuffer(width: width, height: height) else { return false }
        let drawn = isSoftware
            ? renderSoftware(renderContext, into: buffer, width: width, height: height, block: block)
            : renderGL(renderContext, into: buffer, width: width, height: height, block: block)
        guard drawn else { return false }
        enqueue(buffer, on: layer)
        return true
    }

    /// The view's pixels; in PiP the video's own shape (no bars), capped (smaller on the CPU renderer).
    private func renderSize() -> CGSize {
        if framesForPictureInPicture {
            return isSoftware ? CGSize(width: 960, height: 540) : CGSize(width: 1280, height: 720)
        }
        // Even sizes: video planes with odd sizes came out black.
        return CGSize(width: (targetSize.width / 2).rounded(.down) * 2, height: (targetSize.height / 2).rounded(.down) * 2)
    }

    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pixelPool == nil || pixelPoolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferOpenGLESCompatibilityKey as String: true,
                kCVPixelBufferOpenGLESTextureCacheCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            pixelPool = pool
            pixelPoolSize = size
            formatDescription = nil
        }
        guard let pixelPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelPool, &buffer)
        return buffer
    }

    /// OpenGL ES straight into the buffer's IOSurface (no copy).
    private func renderGL(_ renderContext: OpaquePointer, into buffer: CVPixelBuffer, width: Int, height: Int, block: Bool) -> Bool {
        if readsBack { return renderGLReadingBack(renderContext, into: buffer, width: width, height: height, block: block) }
        if textureCache == nil { CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glContext, nil, &textureCache) }
        guard let textureCache else { return false }
        var texture: CVOpenGLESTexture?
        let status = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA,
            GLsizei(width), GLsizei(height), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texture)
        guard status == kCVReturnSuccess, let texture else {
            NSLog("Tuner: mpv PiP buffers aren't GL textures here (%d); reading pixels back", status)
            readsBack = true
            return renderGLReadingBack(renderContext, into: buffer, width: width, height: height, block: block)
        }
        let target = CVOpenGLESTextureGetTarget(texture), name = CVOpenGLESTextureGetName(texture)
        glBindTexture(target, name)
        glTexParameteri(target, GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(target, GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(target, GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(target, GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        if textureFramebuffer == 0 { glGenFramebuffers(1, &textureFramebuffer) }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureFramebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), target, name, 0)
        var fbo = mpv_opengl_fbo(fbo: Int32(textureFramebuffer), w: Int32(width), h: Int32(height), internal_format: 0)
        // Unflipped: mpv's first row lands in the buffer's first row (the screen's GL layer is the one that needs flipping).
        var flip: Int32 = 0
        var blockTime: Int32 = block ? 1 : 0
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &blockTime) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(renderContext, &params)
                }
            }
        }
        // The buffer goes to Core Animation next: the GPU must be done with it.
        glFinish()
        glBindTexture(target, 0)
        CVOpenGLESTextureCacheFlush(textureCache, 0)
        return true
    }

    /// Fallback: an offscreen renderbuffer, then `glReadPixels` into the buffer (a copy per frame).
    private func renderGLReadingBack(_ renderContext: OpaquePointer, into buffer: CVPixelBuffer, width: Int, height: Int, block: Bool) -> Bool {
        let size = CGSize(width: width, height: height)
        if textureFramebuffer == 0 { glGenFramebuffers(1, &textureFramebuffer) }
        if readbackRenderbuffer == 0 { glGenRenderbuffers(1, &readbackRenderbuffer) }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureFramebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), readbackRenderbuffer)
        if readbackSize != size {
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8), GLsizei(width), GLsizei(height))
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), readbackRenderbuffer)
            readbackSize = size
        }
        var fbo = mpv_opengl_fbo(fbo: Int32(textureFramebuffer), w: Int32(width), h: Int32(height), internal_format: 0)
        // Unflipped: glReadPixels returns mpv's rows in the order they belong in the buffer.
        var flip: Int32 = 0
        var blockTime: Int32 = block ? 1 : 0
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &blockTime) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(renderContext, &params)
                }
            }
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        // mpv leaves the default framebuffer bound: read from ours.
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureFramebuffer)
        glPixelStorei(GLenum(GL_PACK_ROW_LENGTH), GLint(CVPixelBufferGetBytesPerRow(buffer) / 4))
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), base)
        glPixelStorei(GLenum(GL_PACK_ROW_LENGTH), 0)
        return true
    }

    /// mpv's CPU renderer into the buffer's memory (background PiP).
    private func renderSoftware(_ renderContext: OpaquePointer, into buffer: CVPixelBuffer, width: Int, height: Int, block: Bool) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var size: [Int32] = [Int32(width), Int32(height)]
        var stride = size_t(CVPixelBufferGetBytesPerRow(buffer))
        var blockTime: Int32 = block ? 1 : 0
        let result: Int32 = size.withUnsafeMutableBufferPointer { sizePtr in
            withUnsafeMutablePointer(to: &stride) { stridePtr in
                withUnsafeMutablePointer(to: &blockTime) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: MPVRenderer.softwareFormat),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(renderContext, &params)
                }
            }
        }
        return result >= 0
    }

    /// Wraps the buffer as a frame to show at once (mpv already timed it).
    private func enqueue(_ buffer: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer) {
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description)
            formatDescription = description
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
    /// Picture in Picture mode: the layer frames go to instead of `videoLayer`.
    let sampleLayer: AVSampleBufferDisplayLayer?
    /// Picture in Picture mode: the system PiP window for this view's video.
    private(set) var pictureInPicture: MPVPictureInPicture?

    init(videoLayer: MPVVideoLayer) {
        self.videoLayer = videoLayer
        sampleLayer = videoLayer.renderer.usesSampleBuffers ? AVSampleBufferDisplayLayer() : nil
        super.init(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        if let sampleLayer {
            // The frames are drawn at the view's size, bars included, so show them as they are.
            sampleLayer.videoGravity = .resize
            sampleLayer.backgroundColor = UIColor.black.cgColor
            layer.addSublayer(sampleLayer)
            videoLayer.renderer.sampleLayer = sampleLayer
            pictureInPicture = MPVPictureInPicture(layer: sampleLayer, renderer: videoLayer.renderer)
        } else {
            layer.addSublayer(videoLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if let sampleLayer {
            guard sampleLayer.frame != bounds || sampleLayer.contentsScale != scale else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sampleLayer.frame = bounds
            sampleLayer.contentsScale = scale
            CATransaction.commit()
            videoLayer.renderer.setTargetSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
            return
        }
        guard videoLayer.frame != bounds || videoLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        CATransaction.commit()
        videoLayer.renderer.layerDidResize()
    }
}
