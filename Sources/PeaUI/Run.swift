import CGTK
import PeaCore
import Foundation

/// Runs Pea: creates the model on `services`, opens the window and blocks in the GTK main loop until
/// the window is closed (or `PeaUIApp.quit()`). This is the whole public surface a platform shell needs.
@MainActor
public func runPea(services: PlatformServices) {
    runPea(services: services, onReady: { _ in })
}

/// Same, but hands the shell a `PeaUIApp` once the window exists (to attach a tray icon, etc).
@MainActor
public func runPea(services: PlatformServices, onReady: (PeaUIApp) -> Void) {
    guard GTKRuntime.ensureInit() else {
        FileHandle.standardError.write(Data("Pea: could not open a display (is DISPLAY / WAYLAND_DISPLAY set?)\n".utf8))
        return
    }
    Artwork.sampler = { data in await Task.detached { Pix.sample(data) }.value }

    let model = Model(services: services)
    let app = PeaUIApp(model: model, services: services)
    let scene = app.scene
    let debug = Debug.name.flatMap { Debug.state($0, model: model) }

    // --- Model -> scene
    let provider: () -> ViewState = {
        if var d = debug { d.audioFormat = model.audioFormat; return d }
        return ViewState(model)
    }
    model.animate = { motion, body in
        scene.motion = motion
        body()
        scene.motion = .quick
    }
    model.onChange = {
        scene.apply(provider())
        app.notify()
    }
    scene.actions = Actions(
        clickHero: { model.clickHero() },
        performSetup: { model.performSetupStep() },
        skipSetup: { model.skipSetup() },
        chooseKind: { model.choose($0) },
        chooseQuality: { model.choose($0) },
        setFormat: { model.audioFormat = $0 },
        open: { model.open($0) },
        warmHint: { model.warmHint() },
        toggleMode: { app.setTrayMode(!app.trayMode) },
        close: { app.requestClose() }
    )
    scene.trayMode = app.trayMode
    scene.apply(provider())

    app.buildWindow(debugHover: Debug.hover)
    onReady(app)
    if debug == nil { model.start() }

    // Swift's main-actor work rides the dispatch main queue; GLib's loop doesn't service it, so pump it.
    every(ms: 8) { RunLoop.main.run(mode: .default, before: Date()) }

    let loop = g_main_loop_new(nil, 0)!
    app.loop = loop
    g_main_loop_run(loop)
    g_main_loop_unref(loop)
}

extension PeaUIApp {
    func requestClose() {
        if trayMode && trayAvailable { hideWindow() } else { quit() }
    }

    func buildWindow(debugHover: Bool) {
        let scene = self.scene, model = self.model

        // Dark, flat, borderless.
        let css = gtk_css_provider_new()!
        gtk_css_provider_load_from_data(css, "window.pea { background: #282928; border-radius: 0; } tooltip { }", -1)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), op(Ptr(css)),
                                                   UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))

        let win = gtk_window_new()!
        let winW = cast(win, GtkWindow.self)
        gtk_window_set_title(winW, "Pea")
        gtk_window_set_decorated(winW, 0)
        gtk_window_set_resizable(winW, 0)
        gtk_window_set_default_size(winW, 232, 266)
        gtk_widget_add_css_class(win, "pea")
        window = Ptr(win)

        let area = gtk_drawing_area_new()!
        self.area = Ptr(area)
        gtk_widget_set_size_request(area, 232, 266)
        gtk_widget_set_has_tooltip(area, 1)
        gtk_window_set_child(winW, area)

        // --- Drawing + frame clock
        let drawBox = Unmanaged.passRetained(Box({ (cr: OpaquePointer) in scene.draw(cr, nowSec()) })).toOpaque()
        gtk_drawing_area_set_draw_func(cast(area, GtkDrawingArea.self), { _, cr, _, _, user in
            guard let cr, let user else { return }
            Unmanaged<Box<(OpaquePointer) -> Void>>.fromOpaque(user).takeUnretainedValue().f(cr)
        }, drawBox, nil)

        var tick: UInt32 = 0
        let tickBox = Unmanaged.passRetained(Box({ () -> Bool in
            gtk_widget_queue_draw(area)
            if scene.animating(nowSec()) { return true }
            tick = 0
            return false
        })).toOpaque()
        scene.requestFrame = {
            gtk_widget_queue_draw(area)
            if tick == 0 {
                tick = gtk_widget_add_tick_callback(area, { _, _, user in
                    Unmanaged<Box<() -> Bool>>.fromOpaque(user!).takeUnretainedValue().f() ? 1 : 0
                }, tickBox, nil)
            }
        }

        // --- Pointer
        let motion = gtk_event_controller_motion_new()!
        connect(motion, "motion", thunk: thunkXY, handler: { x, y in
            scene.pointerMoved(x, y)
            gtk_widget_set_cursor_from_name(area, scene.interactive(scene.currentHit) || scene.currentHit == .file ? "pointer" : nil)
        } as VXY)
        connect(motion, "enter", thunk: thunkXY, handler: { x, y in scene.setWindowHover(true); scene.pointerMoved(x, y) } as VXY)
        connect(motion, "leave", thunk: thunk0, handler: { scene.setWindowHover(false); scene.pointerLeft() } as V0)
        gtk_widget_add_controller(area, motion)

        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(op(click), 1)
        var pressed = Hit.none
        connect(click, "pressed", thunk: thunkPress, handler: { _, x, y, gesture in
            pressed = scene.hit(x, y)
            if pressed == .file { return }                         // the drag source owns this one
            if !scene.interactive(pressed) {                        // empty background: drag the window
                let ctrl = op(gesture)
                if let surf = gtk_native_get_surface(op(win)),
                   let dev = gtk_event_controller_get_current_event_device(ctrl) {
                    gdk_toplevel_begin_move(op(Ptr(surf)), dev, 1, x, y,
                                            gtk_event_controller_get_current_event_time(ctrl))
                }
                pressed = .none
            }
        } as VPress)
        connect(click, "released", thunk: thunkPress, handler: { _, x, y, _ in
            let h = scene.hit(x, y)
            if h == pressed, scene.interactive(h) { scene.click(h) }
            pressed = .none
        } as VPress)
        gtk_widget_add_controller(area, op(click))

        connect(area, "query-tooltip", thunk: thunkTip, handler: { x, y, tip in
            guard let t = scene.tooltip(Double(x), Double(y)) else { return false }
            gtk_tooltip_set_text(op(tip), t)
            return true
        } as VTip)

        // --- Keyboard: Esc resets, Ctrl+V pastes, Ctrl+Q quits
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(op(keys), GTK_PHASE_CAPTURE)
        let ctrlMask = GDK_CONTROL_MASK.rawValue
        let clipboard = services.clipboard as? GTKClipboard
        connect(keys, "key-pressed", thunk: thunkKey, handler: { key, state in
            if key == 0xff1b { model.reset(); return true }                              // Escape
            if state & ctrlMask != 0 {
                switch key {
                case 0x76, 0x56:                                                          // v / V
                    if let clipboard { clipboard.refresh { model.paste() } } else { model.paste() }
                    return true
                case 0x71, 0x51: self.quit(); return true                                 // q / Q
                default: break
                }
            }
            return false
        } as VKey)
        gtk_widget_add_controller(win, op(keys))

        // --- Drag the finished file OUT (move only)
        let drag = gtk_drag_source_new()!
        gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
        var dragging: FileThumb?
        connect(drag, "prepare", thunk: thunkPrepare, handler: { (x: Double, y: Double) -> Ptr? in
            guard let f = scene.dragFile(x, y) else { return nil }
            dragging = f.thumb
            let uri = Array((f.url.absoluteString + "\r\n").utf8)
            let bytes = g_bytes_new(uri, gsize(uri.count))
            defer { g_bytes_unref(bytes) }
            return Ptr(gdk_content_provider_new_for_bytes("text/uri-list", bytes))
        } as VPrepare)
        connect(drag, "drag-begin", thunk: thunkDragBegin, handler: { src in
            if let tex = dragging?.dragTexture() ?? FileThumb(url: URL(fileURLWithPath: "/")).dragTexture() {
                gtk_drag_source_set_icon(op(src), op(tex), 52, 52)
                g_object_unref(tex)
            }
        } as VDragBegin)
        connect(drag, "drag-end", thunk: thunkDragEnd, handler: { moved in
            if moved { after(ms: 400) { model.reset() } }
        } as VDragEnd)
        gtk_widget_add_controller(area, op(drag))

        // --- Drop a link / text onto the window
        let builder = gdk_content_formats_builder_new()!
        for m in ["text/uri-list", "text/x-moz-url", "text/plain;charset=utf-8", "text/plain"] {
            gdk_content_formats_builder_add_mime_type(builder, m)
        }
        let formats = gdk_content_formats_builder_free_to_formats(builder)
        let drop = gtk_drop_target_async_new(formats, GDK_ACTION_COPY)!
        connect(drop, "drag-enter", thunk: thunkDragAction, handler: {} as V0)
        connect(drop, "drag-motion", thunk: thunkDragAction, handler: {} as V0)
        connect(drop, "drop", thunk: thunkDrop, handler: { dropObj in
            readDrop(dropObj) { model.accept($0) }
            return true
        } as VDrop)
        gtk_widget_add_controller(area, op(drop))

        // --- Window lifetime
        connect(win, "close-request", thunk: thunkBool0, handler: { [unowned self] () -> Bool in
            if trayMode && trayAvailable { hideWindow() } else { quit() }
            return true
        } as () -> Bool)

        // --- Keep the cached clipboard fresh when the window is focused and on a slow poll.
        if let clipboard {
            connect(win, "notify::is-active", thunk: thunk0Pspec, handler: { clipboard.refresh() } as V0)
            every(ms: 1500) { clipboard.refresh() }
        }

        gtk_window_present(winW)
        scene.requestFrame()
        if debugHover || Debug.name != nil && Debug.hover { scene.pointerMoved(Scene.cx, Scene.cy) }
    }
}

/// Reads a dropped payload (a URL list or plain text) and passes its text on.
private func readDrop(_ drop: Ptr, _ done: @escaping (String) -> Void) {
    let mimes: [String] = ["text/uri-list", "text/x-moz-url", "text/plain;charset=utf-8", "text/plain"]
    var cstrs = mimes.map { strdup($0) } + [nil]
    defer { for p in cstrs { free(p) } }
    let box = Unmanaged.passRetained(Box((drop, done))).toOpaque()
    cstrs.withUnsafeMutableBufferPointer { buf in
        let arr = UnsafeMutableRawPointer(buf.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        gdk_drop_read_async(op(drop), arr, G_PRIORITY_DEFAULT, nil, { src, res, user in
            let ctx = Unmanaged<Box<(Ptr, (String) -> Void)>>.fromOpaque(user!)
            let (drop, done) = ctx.takeUnretainedValue().f
            ctx.release()
            var mime: UnsafePointer<CChar>?
            guard let stream = gdk_drop_read_finish(op(drop), res, &mime, nil) else {
                gdk_drop_finish(op(drop), GdkDragAction(rawValue: 0)); return
            }
            let m = mime.map { String(cString: $0) } ?? ""
            let inner = Unmanaged.passRetained(Box((drop, stream, m, done))).toOpaque()
            g_input_stream_read_bytes_async(stream, 65536, G_PRIORITY_DEFAULT, nil, { s, r, u in
                let c = Unmanaged<Box<(Ptr, UnsafeMutablePointer<GInputStream>, String, (String) -> Void)>>.fromOpaque(u!)
                let (drop, stream, m, done) = c.takeUnretainedValue().f
                c.release()
                defer { g_object_unref(Ptr(stream)) }
                guard let gb = g_input_stream_read_bytes_finish(stream, r, nil) else {
                    gdk_drop_finish(op(drop), GdkDragAction(rawValue: 0)); return
                }
                var n = 0
                let p = g_bytes_get_data(gb, &n)
                var text = p.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: n), as: UTF8.self) } ?? ""
                g_bytes_unref(gb)
                gdk_drop_finish(op(drop), GDK_ACTION_COPY)
                if m == "text/uri-list" {
                    text = text.split(whereSeparator: \.isNewline).map(String.init).first { !$0.hasPrefix("#") } ?? ""
                } else if m == "text/x-moz-url" {
                    // UTF-16: "url\ntitle"; fall back to a plain decode when it was sent as UTF-8.
                    let bytes = p.map { Data(bytes: $0, count: n) } ?? Data()
                    let s16 = String(data: bytes, encoding: .utf16) ?? text
                    text = s16.split(whereSeparator: \.isNewline).map(String.init).first ?? ""
                }
                if !text.isEmpty { done(text) }
            }, inner)
        }, box)
    }
}
