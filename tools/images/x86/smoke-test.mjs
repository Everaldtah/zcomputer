#!/usr/bin/env node
// Restores a saved z-alpine-desktop-x86 state in v86 under Node (exactly as the
// app would: same machine options, the pristine image as an async disk) and
// checks that it comes back as a working desktop.
//
//   node smoke-test.mjs --bios DIR --img IMG --state STATE --logs DIR
//
// Checks: serial shell answers `echo ok`; v86's VGA is in a 1024x768x32
// graphics mode and its framebuffer shows the same desktop as the guest's own
// screenshot; the guest's framebuffer and X display are 1024x768; the XFCE
// processes run; zguest answers ping/sysinfo/screenshot/input; host input as
// an app sends it (v86 absolute pointer + PS/2 keyboard) reaches X. Writes
// DIR/smoke-report.json, DIR/smoke-serial.log, DIR/desktop-restored.png (the
// guest's scrot) and DIR/v86-screen-restored.png (v86's framebuffer).
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { decodePng } from "./png.mjs";
import {
    SerialConsole, X_ENV, createEmulator, fmtSec, pointerAt, sameFraction, saveScreen, sleep, started, v86Version, vgaInfo,
    watchHardware,
} from "./v86-common.mjs";

const { values: a } = parseArgs({
    options: { bios: { type: "string" }, img: { type: "string" }, state: { type: "string" }, logs: { type: "string" } },
});
for (const k of ["bios", "img", "state", "logs"]) if (!a[k]) throw new Error(`missing --${k}`);
fs.mkdirSync(a.logs, { recursive: true });

const t0 = Date.now();
const report = { startedAt: new Date(t0).toISOString(), v86: v86Version(), checks: [], steps: {} };
const mark = (name) => {
    report.steps[name] = fmtSec(Date.now() - t0);
    console.log(`[${report.steps[name]}s] ${name}`);
};
function check(name, pass, detail) {
    report.checks.push({ name, pass: !!pass, detail });
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail !== undefined ? `: ${typeof detail === "string" ? detail : JSON.stringify(detail)}` : ""}`);
    return !!pass;
}
const lastLine = (s) => s.trim().split("\n").pop().trim();

const emulator = createEmulator({ biosDir: a.bios, imgPath: a.img, statePath: a.state });
const hw = watchHardware(emulator);
const con = new SerialConsole(emulator, path.join(a.logs, "smoke-serial.log"));

async function main() {
    await started(emulator);
    mark("state restored, emulator running");

    // 1. The serial shell left logged in by boot-snapshot.mjs.
    con.send("\n");
    await con.sh("stty -echo; PS1=", { timeoutMs: 120_000 });
    const ok = await con.sh("echo ok", { timeoutMs: 60_000 });
    check("serial shell runs `echo ok`", ok.code === 0 && lastLine(ok.out) === "ok", lastLine(ok.out));
    mark("serial shell answered");
    report.restoreToShellSec = report.steps["serial shell answered"];

    // 2. v86's own view of the display: restore_state re-announces the VGA mode.
    for (let i = 0; i < 50 && !hw.screen; i++) await sleep(100);
    const s = hw.screen || {};
    check("v86 VGA is in graphics mode 1024x768x32", s.graphical && s.width === 1024 && s.height === 768 && s.bpp === 32, s);
    const vga = vgaInfo(emulator);
    report.vga = vga;
    check("v86 VGA is on the SVGA (Bochs VBE) framebuffer", vga && vga.graphical && vga.svga && vga.width === 1024 && vga.height === 768 && vga.bpp === 32, vga);
    // What the app shows right after restoring: v86's framebuffer, compared with scrot below.
    const screen = saveScreen(emulator, path.join(a.logs, "v86-screen-restored.png"));

    // 3. The guest's view: framebuffer, X screen, desktop processes.
    const fb = await con.sh("cat /sys/class/graphics/fb0/virtual_size");
    check("guest framebuffer /dev/fb0 is 1024x768", lastLine(fb.out) === "1024,768", lastLine(fb.out));
    const geo = await con.sh(`${X_ENV} xdotool getdisplaygeometry`);
    check("X display :0 is 1024x768", lastLine(geo.out) === "1024 768", lastLine(geo.out));
    const procs = ["Xorg", "xfce4-session", "xfwm4", "xfce4-panel", "xfdesktop"];
    const ps = await con.sh(`for p in ${procs.join(" ")}; do pgrep -x $p >/dev/null && printf '%s ' $p; done; echo`);
    check("XFCE desktop processes are running", procs.every((p) => ps.out.split(/\s+/).includes(p)), ps.out.trim());
    const win = await con.sh(`${X_ENV} xdotool search --onlyvisible --class xfce4-panel | head -1`);
    check("the XFCE panel window is mapped", win.code === 0 && /^\d+$/.test(lastLine(win.out)), lastLine(win.out));

    // 4. The agent.
    const ping = await con.sh("zg ping");
    let pj = {};
    try { pj = JSON.parse(lastLine(ping.out)); } catch {}
    check("zguest ping on 127.0.0.1:5555", ping.code === 0 && pj.ok && pj.protocol === 1, { version: pj.version, ops: pj.ops });
    const si = await con.sh("zg sysinfo");
    let sj = {};
    try { sj = JSON.parse(lastLine(si.out)); } catch {}
    check("zguest sysinfo sees the X11 session", si.code === 0 && sj.display && sj.display.type === "x11",
        sj.display ? { type: sj.display.type, user: sj.display.user, source: sj.display.source, arch: sj.arch, os: sj.os } : lastLine(si.out));
    const shot = await con.sh("zg --png /mnt/host/desktop-restored.png screenshot", { timeoutMs: 180_000 });
    let shj = {};
    try { shj = JSON.parse(lastLine(shot.out)); } catch {}
    let pngOk = false;
    let scrot = null;
    if (shot.code === 0) {
        const png = Buffer.from(await emulator.read_file("/desktop-restored.png"));
        fs.writeFileSync(path.join(a.logs, "desktop-restored.png"), png);
        pngOk = png.subarray(1, 4).toString() === "PNG";
        await con.sh("rm -f /mnt/host/desktop-restored.png");
        try { scrot = decodePng(png); } catch (e) { console.log(`cannot decode the scrot PNG: ${e.message}`); }
    }
    check("zguest screenshot (scrot) is a 1024x768 PNG, read back over 9p", shot.code === 0 && shj.width === 1024 && shj.height === 768 && pngOk,
        { tool: shj.tool, width: shj.width, height: shj.height, error: shj.error });
    // The X pointer (a software cursor on fbdev) and the panel clock may differ; the rest must match.
    const same = sameFraction(screen, scrot);
    check("v86's framebuffer shows the desktop the guest sees (>= 97% of pixels match scrot)", same >= 0.97,
        `${(same * 100).toFixed(2)}% of pixels match`);
    const inp = await con.sh(`zg '{"op":"input","actions":[{"type":"mouse_move","x":321,"y":234}]}'`);
    const loc = await con.sh(`${X_ENV} xdotool getmouselocation`);
    check("zguest input moves the pointer (xdotool)", inp.code === 0 && /x:321 y:234/.test(loc.out), lastLine(loc.out));

    // 5. Host input as an app sends it: v86's VMware absolute pointer and PS/2 keyboard.
    const where = async () => {
        const r = await con.sh(`${X_ENV} xdotool getmouselocation`);
        const m = /x:(\d+) y:(\d+)/.exec(r.out);
        return m ? { x: Number(m[1]), y: Number(m[2]) } : { raw: lastLine(r.out) };
    };
    const near = (p, x, y) => Math.abs(p.x - x) <= 2 && Math.abs(p.y - y) <= 2;
    emulator.bus.send("mouse-absolute", [700, 500, 1024, 768]); // alone: no PS/2 interrupt yet
    await sleep(1500);
    const absOnly = await where();
    pointerAt(emulator, 700, 500); // + a PS/2 click event (no buttons) as the doorbell
    await sleep(1500);
    const absRung = await where();
    pointerAt(emulator, 100, 650);
    await sleep(1500);
    const absRung2 = await where();
    report.pointer = { absoluteAlone: absOnly, withClickEvent: absRung, second: absRung2, vmwareAbsoluteMouse: hw.vmwareAbsoluteMouse };
    check("v86 absolute pointer (VMware backdoor + PS/2 click event) moves the X pointer",
        hw.vmwareAbsoluteMouse === true && near(absRung, 700, 500) && near(absRung2, 100, 650), report.pointer);

    await con.sh(`rm -f /tmp/zc-kbd; (${X_ENV} xfce4-terminal --disable-server --title=zc-kbd -x sh -c 'read l; echo "$l" > /tmp/zc-kbd' >/dev/null 2>&1 &)`);
    let term = "";
    for (let i = 0; i < 60 && !term; i++) {
        const r = await con.sh(`${X_ENV} xdotool search --onlyvisible --name '^zc-kbd$' | head -1`);
        if (/^\d+$/.test(lastLine(r.out))) term = lastLine(r.out);
        else await sleep(1000);
    }
    let typed = "";
    if (term) {
        await con.sh(`${X_ENV} timeout 15 xdotool windowactivate --sync ${term}`);
        await sleep(500);
        // Scan code set 1 (what v86's PS/2 controller delivers): o, k, Enter; press then release.
        await emulator.keyboard_send_scancodes([0x18, 0x98, 0x25, 0xa5, 0x1c, 0x9c], 30);
        for (let i = 0; i < 20 && !typed; i++) {
            await sleep(1000);
            const r = await con.sh("cat /tmp/zc-kbd 2>/dev/null");
            typed = lastLine(r.out);
        }
        await con.sh(`${X_ENV} xdotool windowclose ${term} 2>/dev/null; pkill -x xfce4-terminal; rm -f /tmp/zc-kbd`);
    }
    check("v86 PS/2 keyboard types into an X window (xfce4-terminal)", typed === "ok", { window: term || null, typed });

    // Leave the console as it was.
    await con.sh("stty echo; export PS1='\\u@\\h:\\w\\$ '");
    mark("checks done");
}

let failed = null;
try {
    await main();
} catch (e) {
    failed = e;
    console.error(`\nERROR: ${e.stack || e}`);
}
report.ok = !failed && report.checks.length > 0 && report.checks.every((c) => c.pass);
report.error = failed ? String(failed.message || failed) : undefined;
report.hardware = hw;
report.vmwareAbsoluteMouse = hw.vmwareAbsoluteMouse;
fs.writeFileSync(path.join(a.logs, "smoke-report.json"), JSON.stringify(report, null, 2));
console.log(`\nsmoke test ${report.ok ? "PASSED" : "FAILED"} (${report.checks.filter((c) => c.pass).length}/${report.checks.length} checks)`);
con.close();
emulator.stop();
setTimeout(() => process.exit(report.ok ? 0 : 1), 500);
