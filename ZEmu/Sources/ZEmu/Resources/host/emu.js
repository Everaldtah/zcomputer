// ZEmu host page: runs one v86 emulator and bridges it to Swift (EmuHost).
//
// JS -> Swift: window.webkit.messageHandlers.zemu.postMessage({ type, ... })
//   page, ready, loaded, started, stopped, serial {data: base64}, screen {width, height, bpp},
//   absolute-mouse {enabled}, progress {file, loaded, total}, boot-assist {ok, detail}, log {level, message},
//   error {message}
// Swift -> JS: callAsyncJavaScript("return await window.zemu.call(name, argsJSON)") -> JSON string
//   {"ok": true, "value": ...} or {"ok": false, "error": "..."}
"use strict";

(function () {
    const post = (msg) => {
        try {
            window.webkit.messageHandlers.zemu.postMessage(msg);
        } catch (e) {
            // Not inside ZEmu's WKWebView (opened in a browser for debugging).
        }
    };

    // ---- diagnostics ------------------------------------------------------------------------------------------
    const describe = (args) => args.map((a) => {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === "string") return a;
        try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(" ").slice(0, 2000);
    const originalWarn = console.warn.bind(console);
    const originalError = console.error.bind(console);
    console.warn = (...args) => { originalWarn(...args); post({ type: "log", level: "warn", message: describe(args) }); };
    console.error = (...args) => { originalError(...args); post({ type: "log", level: "error", message: describe(args) }); };
    window.addEventListener("error", (e) => {
        post({ type: "error", message: `${e.message} (${e.filename}:${e.lineno})` });
    });
    window.addEventListener("unhandledrejection", (e) => {
        const r = e.reason;
        post({ type: "error", message: "unhandled rejection: " + (r && (r.stack || r.message) || String(r)) });
    });

    // ---- helpers ----------------------------------------------------------------------------------------------
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    function bytesToBase64(bytes) {
        let binary = "";
        const step = 0x8000;
        for (let i = 0; i < bytes.length; i += step) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(bytes.length, i + step)));
        }
        return btoa(binary);
    }

    function base64ToBytes(text) {
        const binary = atob(text);
        const out = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
        return out;
    }

    function escapeRegExp(text) {
        return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function loadArrayBuffer(url) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url, true);
            xhr.responseType = "arraybuffer";
            xhr.onload = () => {
                if (xhr.status === 200 || xhr.status === 206) resolve(xhr.response);
                else reject(new Error(`GET ${url}: HTTP ${xhr.status}`));
            };
            xhr.onerror = () => reject(new Error(`GET ${url} failed`));
            xhr.send(null);
        });
    }

    // ---- the emulator -----------------------------------------------------------------------------------------
    const zemu = {
        emulator: null,
        config: null,
        serialChunks: [],
        serialLength: 0,
        serialTimer: 0,
        serialTail: "",
        screen: { width: 1024, height: 768, bpp: 0, cols: 80, rows: 25, graphical: false },
        absoluteMouse: false,
        buttons: [false, false, false],
        pendingState: null,
        pendingFile: null,
        uploads: {},
        lastProgress: 0,
        started: false,
        busy: Promise.resolve(),

        // Swift entry point: name of a method below, arguments as a JSON array.
        async call(name, argsJSON) {
            try {
                const fn = this["cmd_" + name];
                if (typeof fn !== "function") throw new Error("unknown command " + name);
                const args = argsJSON ? JSON.parse(argsJSON) : [];
                const value = await fn.apply(this, args);
                return JSON.stringify({ ok: true, value: value === undefined ? null : value });
            } catch (e) {
                return JSON.stringify({ ok: false, error: (e && (e.message || String(e))) || "error" });
            }
        },

        requireEmulator() {
            if (!this.emulator) throw new Error("the emulator is not running");
            return this.emulator;
        },

        // ---- lifecycle ----

        async cmd_ping() {
            return {
                v86: typeof window.V86 === "function",
                worker: typeof Worker === "function",
                workerError: window.__zemuWorkerError || null,
                wasm: typeof WebAssembly === "object",
                userAgent: navigator.userAgent,
            };
        },

        async cmd_start(cfg) {
            if (this.emulator) await this.cmd_destroy();
            this.config = cfg;
            this.started = false;
            this.serialTail = "";
            this.absoluteMouse = false;
            this.buttons = [false, false, false];
            const container = document.getElementById("screen_container");
            const options = {
                wasm_path: cfg.wasmPath,
                bios: { url: cfg.biosURL },
                vga_bios: { url: cfg.vgaBiosURL },
                memory_size: cfg.memorySize,
                vga_memory_size: cfg.vgaMemorySize,
                screen_container: container,
                screen: { use_graphical_text: true },
                boot_order: cfg.bootOrder,
                acpi: !!cfg.acpi,
                fastboot: !!cfg.fastboot,
                autostart: true,
                disable_mouse: true,
                disable_speaker: true,
                disable_keyboard: !cfg.hostKeyboard,
                preserve_mac_from_state_image: !!cfg.preserveMAC,
                net_device: { type: cfg.nic || "virtio" },
            };
            if (cfg.relayURL) {
                options.net_device.relay_url = cfg.relayURL;
                if (cfg.corsProxy) options.net_device.cors_proxy = cfg.corsProxy;
            }
            if (cfg.cdrom) options.cdrom = { url: cfg.cdrom.url, async: true, size: cfg.cdrom.size };
            if (cfg.hda) options.hda = { url: cfg.hda.url, async: true, size: cfg.hda.size };
            if (cfg.filesystem) options.filesystem = {};
            if (cfg.initialState) options.initial_state = { url: cfg.initialState };

            const e = new window.V86(options);
            this.emulator = e;
            e.add_listener("emulator-ready", () => post({ type: "ready" }));
            e.add_listener("emulator-loaded", () => post({ type: "loaded" }));
            e.add_listener("emulator-started", () => {
                const first = !this.started;
                this.started = true;
                post({ type: "started" });
                if (first && cfg.bootAssist && !cfg.initialState) {
                    this.runBootAssist(cfg.bootAssist).catch((err) => post({ type: "boot-assist", ok: false, detail: String(err) }));
                }
            });
            e.add_listener("emulator-stopped", () => post({ type: "stopped" }));
            if (cfg.serial) e.add_listener("serial0-output-byte", (b) => this.serialByte(b));
            e.add_listener("screen-set-size", (args) => this.screenSetSize(args));
            e.add_listener("vmware-absolute-mouse", (on) => {
                this.absoluteMouse = !!on;
                post({ type: "absolute-mouse", enabled: !!on });
            });
            e.add_listener("download-progress", (p) => {
                const now = Date.now();
                if (now - this.lastProgress < 250 && p.loaded !== p.total) return;
                this.lastProgress = now;
                post({ type: "progress", file: String(p.file_name || ""), loaded: p.loaded || 0, total: p.total || 0 });
            });
            e.add_listener("download-error", (p) => post({ type: "error", message: "download failed: " + p.file_name }));
            return true;
        },

        async cmd_destroy() {
            const e = this.emulator;
            this.emulator = null;
            this.started = false;
            this.flushSerial();
            if (e) {
                try { await e.destroy(); } catch (err) { console.warn("destroy: " + err); }
            }
            const container = document.getElementById("screen_container");
            container.innerHTML = "<div></div><canvas></canvas>";
            return true;
        },

        async cmd_pause() { await this.requireEmulator().stop(); return true; },
        async cmd_resume() { await this.requireEmulator().run(); return true; },
        async cmd_reset() { this.requireEmulator().restart(); return true; },
        async cmd_isRunning() { return !!(this.emulator && this.emulator.is_running()); },

        async runBootAssist(a) {
            const e = this.requireEmulator();
            const timeout = Math.max(1000, a.timeoutMs || 90000);
            if (a.screenText) {
                const ok = await e.wait_until_vga_screen_contains(new RegExp(escapeRegExp(a.screenText)), { timeout_msec: timeout });
                if (!ok) { post({ type: "boot-assist", ok: false, detail: `"${a.screenText}" not on screen` }); return; }
            } else if (a.serialText) {
                const end = Date.now() + timeout;
                while (!this.serialTail.includes(a.serialText)) {
                    if (Date.now() > end || this.emulator !== e) {
                        post({ type: "boot-assist", ok: false, detail: `"${a.serialText}" not on serial` });
                        return;
                    }
                    await sleep(50);
                }
            }
            if (a.delayMs) await sleep(a.delayMs);
            if (a.strokes && a.strokes.length) await this.sendStrokes(a.strokes, a.strokeDelayMs || 40);
            if (a.serialSend) e.serial0_send(a.serialSend);
            post({ type: "boot-assist", ok: true, detail: "sent" });
        },

        // ---- serial ----

        serialByte(b) {
            this.serialChunks.push(b);
            this.serialLength++;
            this.serialTail += String.fromCharCode(b);
            if (this.serialTail.length > 8192) this.serialTail = this.serialTail.slice(-4096);
            if (this.serialLength >= 16384) {
                this.flushSerial();
            } else if (!this.serialTimer) {
                this.serialTimer = setTimeout(() => this.flushSerial(), 15);
            }
        },

        flushSerial() {
            if (this.serialTimer) { clearTimeout(this.serialTimer); this.serialTimer = 0; }
            if (!this.serialLength) return;
            const bytes = Uint8Array.from(this.serialChunks);
            this.serialChunks = [];
            this.serialLength = 0;
            post({ type: "serial", data: bytesToBase64(bytes) });
        },

        async cmd_serialSend(b64) {
            this.requireEmulator().serial_send_bytes(0, base64ToBytes(b64));
            return true;
        },

        // ---- screen ----

        screenSetSize(args) {
            const [w, h, bpp] = args;
            if (bpp) {
                this.screen = { width: w, height: h, bpp, cols: this.screen.cols, rows: this.screen.rows, graphical: true };
            } else {
                this.screen = { width: w * 9, height: h * 16, bpp: 0, cols: w, rows: h, graphical: false };
            }
            post({ type: "screen", width: w, height: h, bpp: bpp || 0 });
            setTimeout(() => this.fit(), 0);
        },

        fit() {
            const e = this.emulator;
            const container = document.getElementById("screen_container");
            if (!e || !container) return;
            e.screen_set_scale(1, 1);
            const rect = container.getBoundingClientRect();
            if (!rect.width || !rect.height) return;
            const s = Math.min(window.innerWidth / rect.width, window.innerHeight / rect.height);
            if (s > 0 && isFinite(s)) e.screen_set_scale(s, s);
            const fitted = container.getBoundingClientRect();
            container.style.left = Math.max(0, (window.innerWidth - fitted.width) / 2) + "px";
            container.style.top = Math.max(0, (window.innerHeight - fitted.height) / 2) + "px";
        },

        // Brings v86's canvas up to date (the render loop runs on requestAnimationFrame, which WebKit throttles
        // while the view is hidden) and returns a PNG data URL of the framebuffer.
        async cmd_screenshot() {
            const e = this.requireEmulator();
            const sa = e.screen_adapter;
            if (sa) {
                try {
                    if (this.screen.graphical && typeof sa.update_graphical === "function") sa.update_graphical();
                    else if (typeof sa.update_graphical_text === "function") sa.update_graphical_text();
                } catch (err) { console.warn("screen refresh: " + err); }
            }
            const img = e.screen_make_screenshot();
            return {
                dataURL: img && img.src ? img.src : null,
                graphical: this.screen.graphical,
                width: this.screen.width, height: this.screen.height,
                cols: this.screen.cols, rows: this.screen.rows,
            };
        },

        async cmd_textScreen() {
            const e = this.requireEmulator();
            const sa = e.screen_adapter;
            const lines = sa && typeof sa.get_text_screen === "function" ? sa.get_text_screen() : [];
            return { lines, graphical: this.screen.graphical, cols: this.screen.cols, rows: this.screen.rows };
        },

        // ---- keyboard ----

        async sendStrokes(groups, delayMs) {
            const e = this.requireEmulator();
            for (let i = 0; i < groups.length; i++) {
                await e.keyboard_send_scancodes(groups[i]);
                if (delayMs > 0 && i < groups.length - 1) await sleep(delayMs);
            }
        },

        async cmd_keys(groups, delayMs) {
            await this.sendStrokes(groups, delayMs || 0);
            return true;
        },

        // ---- mouse ----

        async cmd_mouseDeltas(deltas, delayMs) {
            const e = this.requireEmulator();
            for (let i = 0; i < deltas.length; i++) {
                const [dx, dy] = deltas[i];
                e.bus.send("mouse-delta", [dx, -dy]); // PS/2: positive y is up
                if (delayMs > 0 && i < deltas.length - 1) await sleep(delayMs);
            }
            return true;
        },

        // VMware absolute pointer: the position goes into the backdoor queue; a PS/2 packet (mouse-click with the
        // unchanged buttons) raises IRQ12 so the guest driver reads it.
        async cmd_mouseAbsolute(x, y, w, h) {
            const e = this.requireEmulator();
            e.bus.send("mouse-absolute", [x, y, w, h]);
            e.bus.send("mouse-click", this.buttons.slice());
            return this.absoluteMouse;
        },

        async cmd_mouseButtons(left, middle, right) {
            const e = this.requireEmulator();
            this.buttons = [!!left, !!middle, !!right];
            e.bus.send("mouse-click", this.buttons.slice());
            return true;
        },

        // dy > 0 scrolls down (one wheel notch per tick).
        async cmd_wheel(ticks, delayMs) {
            const e = this.requireEmulator();
            const n = Math.min(100, Math.abs(ticks | 0));
            const sign = ticks > 0 ? -1 : 1;
            for (let i = 0; i < n; i++) {
                e.bus.send("mouse-wheel", [sign, 0]);
                if (delayMs > 0 && i < n - 1) await sleep(delayMs);
            }
            return true;
        },

        async cmd_absoluteMouse() { return this.absoluteMouse; },

        // ---- saved states ----

        async cmd_saveState() {
            const e = this.requireEmulator();
            const buffer = await e.save_state();
            this.pendingState = new Uint8Array(buffer);
            return this.pendingState.length;
        },

        async cmd_stateChunk(offset, length) {
            if (!this.pendingState) throw new Error("no saved state pending");
            return bytesToBase64(this.pendingState.subarray(offset, Math.min(this.pendingState.length, offset + length)));
        },

        async cmd_releaseState() { this.pendingState = null; return true; },

        async cmd_restoreState(url) {
            const e = this.requireEmulator();
            const buffer = await loadArrayBuffer(url);
            const wasRunning = e.is_running();
            await e.stop();
            await e.restore_state(buffer);
            if (wasRunning) await e.run();
            return true;
        },

        // ---- CD-ROM ----

        async cmd_insertCD(url, size) {
            await this.requireEmulator().set_cdrom({ url, async: true, size });
            return true;
        },

        async cmd_ejectCD() { this.requireEmulator().eject_cdrom(); return true; },

        // ---- 9p filesystem (mount tag host9p) ----

        fs() {
            const fs = this.requireEmulator().fs9p;
            if (!fs) throw new Error("no 9p filesystem");
            return fs;
        },

        ensureDir(path) {
            const fs = this.fs();
            const parts = path.split("/").filter((p) => p.length);
            let parent = 0;
            let sofar = "";
            for (const part of parts) {
                sofar += "/" + part;
                const found = fs.SearchPath(sofar);
                parent = found.id === -1 ? fs.CreateDirectory(part, parent) : found.id;
            }
            return parent;
        },

        async cmd_fsPut(path, b64, first) {
            if (first || !this.uploads[path]) this.uploads[path] = [];
            this.uploads[path].push(base64ToBytes(b64));
            return true;
        },

        async cmd_fsCommit(path) {
            const e = this.requireEmulator();
            const chunks = this.uploads[path] || [];
            delete this.uploads[path];
            let total = 0;
            for (const c of chunks) total += c.length;
            const data = new Uint8Array(total);
            let at = 0;
            for (const c of chunks) { data.set(c, at); at += c.length; }
            const slash = path.lastIndexOf("/");
            if (slash > 0) this.ensureDir(path.slice(0, slash));
            const existing = this.fs().SearchPath(path);
            if (existing.id !== -1) this.fs().DeleteNode(path);
            await e.create_file(path, data);
            return total;
        },

        async cmd_fsExists(path) { return this.fs().SearchPath(path).id !== -1; },

        async cmd_fsMkdir(path) { this.ensureDir(path); return true; },

        async cmd_fsRead(path) {
            const data = await this.requireEmulator().read_file(path);
            this.pendingFile = data;
            return data.length;
        },

        async cmd_fileChunk(offset, length) {
            if (!this.pendingFile) throw new Error("no file pending");
            return bytesToBase64(this.pendingFile.subarray(offset, Math.min(this.pendingFile.length, offset + length)));
        },

        async cmd_releaseFile() { this.pendingFile = null; return true; },

        async cmd_fsDelete(path) {
            const fs = this.fs();
            if (fs.SearchPath(path).id === -1) return false;
            fs.DeleteNode(path);
            return true;
        },
    };

    window.addEventListener("resize", () => zemu.fit());
    window.zemu = zemu;
    post({ type: "page", v86: typeof window.V86 === "function" });
})();
