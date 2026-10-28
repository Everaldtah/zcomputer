// Shared pieces of boot-snapshot.mjs and smoke-test.mjs: the v86 machine the
// state is taken on (the iOS app must restore with the same hardware), and a
// small driver for the guest's serial console.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { V86 } from "v86";
import { encodePng } from "./png.mjs";

const require = createRequire(import.meta.url);

export const MEMORY_MB = 512;
export const VGA_MEMORY_MB = 8;

/** v86 constructor options a restore must repeat (see docs/IMAGES-X86.md). */
export function machineOptions() {
    return {
        memory_size: MEMORY_MB * 1024 * 1024,
        vga_memory_size: VGA_MEMORY_MB * 1024 * 1024,
        net_device: { type: "virtio" }, // no relay here; the app attaches its own backend
        filesystem: {}, // empty in-memory 9p share -> /mnt/host (mount tag host9p)
        acpi: false,
    };
}

/** A V86 for the image at imgPath; with statePath it restores that state. */
export function createEmulator({ biosDir, imgPath, statePath }) {
    const build = path.dirname(require.resolve("v86"));
    const size = fs.statSync(imgPath).size;
    const options = {
        ...machineOptions(),
        wasm_path: path.join(build, "v86.wasm"),
        bios: { url: path.join(biosDir, "seabios.bin") },
        vga_bios: { url: path.join(biosDir, "vgabios.bin") },
        // async: v86 reads the image lazily and keeps guest writes in memory, so the
        // image file stays pristine and save_state() stores only the written blocks.
        hda: { url: imgPath, async: true, size },
        autostart: true,
        disable_keyboard: true, // host-side browser adapters only; the PS/2 hardware stays
        disable_mouse: true,
    };
    if (statePath) options.initial_state = { url: statePath };
    return new V86(options);
}

export function v86Version() {
    const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(require.resolve("v86")), "..", "package.json"), "utf8"));
    return pkg.version;
}

/** Records what the emulated VGA reports and whether the guest enabled the VMware absolute pointer. */
export function watchHardware(emulator) {
    const hw = { screen: null, screenEvents: [], vmwareAbsoluteMouse: null };
    emulator.add_listener("screen-set-size", (args) => {
        const [w, h, bpp] = args;
        hw.screen = { width: w, height: h, bpp, graphical: bpp > 0 };
        hw.screenEvents.push({ t: Date.now(), width: w, height: h, bpp });
    });
    emulator.add_listener("vmware-absolute-mouse", (on) => {
        hw.vmwareAbsoluteMouse = !!on;
    });
    return hw;
}

/**
 * What v86's VGA shows right now. Reads src/vga.js fields of the emulator
 * (libv86 keeps these property names); null if this v86 build lacks them.
 */
export function vgaInfo(emulator) {
    const vga = emulator.v86?.cpu?.devices?.vga;
    if (!vga || typeof vga.graphical_mode !== "boolean") return null;
    return {
        graphical: vga.graphical_mode,
        svga: !!vga.svga_enabled,
        width: vga.svga_width,
        height: vga.svga_height,
        bpp: vga.svga_bpp,
        offsetPx: vga.svga_offset,
    };
}

/**
 * v86's 32-bit SVGA framebuffer as { width, height, rgb } -- the pixels an
 * app's v86 screen draws (BGRX in video memory) -- or null in other modes.
 */
export function captureScreen(emulator) {
    const info = vgaInfo(emulator);
    if (!info || !info.graphical || !info.svga || info.bpp !== 32) return null;
    const vga = emulator.v86.cpu.devices.vga;
    const mem = new Uint8Array(vga.cpu.wasm_memory.buffer, vga.svga_memory.byteOffset, vga.vga_memory_size);
    const { width, height } = info;
    const rgb = Buffer.alloc(width * height * 3);
    for (let i = 0, s = info.offsetPx * 4; i < width * height && s + 3 < mem.length; i++, s += 4) {
        rgb[i * 3] = mem[s + 2];
        rgb[i * 3 + 1] = mem[s + 1];
        rgb[i * 3 + 2] = mem[s];
    }
    return { width, height, rgb };
}

/** captureScreen() written as a PNG; returns the capture (or null). */
export function saveScreen(emulator, file) {
    const shot = captureScreen(emulator);
    if (shot) fs.writeFileSync(file, encodePng(shot.width, shot.height, shot.rgb));
    return shot;
}

/** Share of the pixels of two same-sized RGB captures that match within `tol` per channel. */
export function sameFraction(a, b, tol = 8) {
    if (!a || !b || a.width !== b.width || a.height !== b.height) return 0;
    let same = 0;
    for (let i = 0; i < a.rgb.length; i += 3) {
        if (Math.abs(a.rgb[i] - b.rgb[i]) <= tol && Math.abs(a.rgb[i + 1] - b.rgb[i + 1]) <= tol
            && Math.abs(a.rgb[i + 2] - b.rgb[i + 2]) <= tol) same++;
    }
    return same / (a.width * a.height);
}

/**
 * Host pointer input the way an app sends it: an absolute position for v86's
 * VMware backdoor, then a PS/2 click event with the button state. The guest's
 * vmmouse driver reads the backdoor queue only when a PS/2 mouse interrupt
 * arrives; the click event is that interrupt (a zero mouse-delta sends none).
 */
export function pointerAt(emulator, x, y, { width = 1024, height = 768, buttons = [false, false, false] } = {}) {
    emulator.bus.send("mouse-absolute", [x, y, width, height]);
    emulator.bus.send("mouse-click", buttons);
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function started(emulator) {
    return new Promise((resolve) => emulator.add_listener("emulator-started", resolve));
}

/** Drives the guest's ttyS0: wait for text, run shell commands with exit codes. */
export class SerialConsole {
    constructor(emulator, logFile) {
        this.emulator = emulator;
        this.text = "";
        this.seq = 0;
        this.log = logFile ? fs.createWriteStream(logFile) : null;
        emulator.add_listener("serial0-output-byte", (byte) => {
            const c = String.fromCharCode(byte);
            this.text += c;
            if (this.log) this.log.write(c);
        });
    }

    send(s) {
        this.emulator.serial0_send(s);
    }

    /** Resolves with the regex match found in the output after offset `from`. */
    async waitFor(re, { timeoutMs = 60_000, from = 0, what = String(re) } = {}) {
        const deadline = Date.now() + timeoutMs;
        for (;;) {
            const m = re.exec(this.text.slice(from));
            if (m) {
                m.end = from + m.index + m[0].length;
                return m;
            }
            if (Date.now() > deadline) {
                const tail = this.text.slice(-600).replace(/\r/g, "");
                throw new Error(`timed out after ${timeoutMs / 1000}s waiting for ${what}; console tail:\n${tail}`);
            }
            await sleep(100);
        }
    }

    /** Runs a shell command (echo should be off) and returns { code, out }. */
    async sh(cmd, { timeoutMs = 120_000 } = {}) {
        const id = ++this.seq;
        const from = this.text.length;
        this.send(`${cmd}; echo "@@Z${id}:$?@@"\n`);
        const m = await this.waitFor(new RegExp(`@@Z${id}:(\\d+)@@`), { timeoutMs, from, what: `command ${id}: ${cmd}` });
        let out = this.text.slice(from, m.end - m[0].length).replace(/\r/g, "");
        // With echo still on the command line comes back first; drop it.
        const echoed = out.indexOf(`@@Z${id}:$?@@`);
        if (echoed >= 0) out = out.slice(out.indexOf("\n", echoed) + 1);
        return { code: Number(m[1]), out: out.replace(/\n+$/, "") };
    }

    /** sh() that throws on a non-zero exit code. */
    async ok(cmd, opts) {
        const r = await this.sh(cmd, opts);
        if (r.code !== 0) throw new Error(`guest command failed (${r.code}): ${cmd}\n${r.out}`);
        return r.out;
    }

    close() {
        if (this.log) this.log.end();
    }
}

/** Shell snippet: environment for X clients of z's session on :0. */
export const X_ENV = "DISPLAY=:0 XAUTHORITY=/home/z/.Xauthority";

export function fmtSec(ms) {
    return Math.round(ms / 100) / 10;
}
