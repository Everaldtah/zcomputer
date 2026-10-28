#!/usr/bin/env node
// Restores a saved z-alpine-desktop-x86 state in v86 under Node (exactly as the
// app would: same machine options, the pristine image as an async disk) and
// checks that it comes back as a working desktop.
//
//   node smoke-test.mjs --bios DIR --img IMG --state STATE --logs DIR
//
// Checks: serial shell answers `echo ok`; v86's VGA is in a 1024x768x32
// graphics mode; the guest's framebuffer and X display are 1024x768; the XFCE
// processes run; zguest answers ping/sysinfo/screenshot/input. Writes
// DIR/smoke-report.json, DIR/smoke-serial.log and DIR/desktop-restored.png.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { SerialConsole, X_ENV, createEmulator, fmtSec, sleep, started, v86Version, watchHardware } from "./v86-common.mjs";

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
    if (shot.code === 0) {
        const png = Buffer.from(await emulator.read_file("/desktop-restored.png"));
        fs.writeFileSync(path.join(a.logs, "desktop-restored.png"), png);
        pngOk = png.subarray(1, 4).toString() === "PNG";
        await con.sh("rm -f /mnt/host/desktop-restored.png");
    }
    check("zguest screenshot (scrot) is a 1024x768 PNG, read back over 9p", shot.code === 0 && shj.width === 1024 && shj.height === 768 && pngOk,
        { tool: shj.tool, width: shj.width, height: shj.height, error: shj.error });
    const inp = await con.sh(`zg '{"op":"input","actions":[{"type":"mouse_move","x":321,"y":234}]}'`);
    const loc = await con.sh(`${X_ENV} xdotool getmouselocation`);
    check("zguest input moves the pointer (xdotool)", inp.code === 0 && /x:321 y:234/.test(loc.out), lastLine(loc.out));

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
