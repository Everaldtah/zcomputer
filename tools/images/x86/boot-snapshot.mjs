#!/usr/bin/env node
// Boots z-alpine-desktop-x86.img in v86 under Node, logs in on the serial
// console as z, waits for the XFCE desktop, and saves the emulator state so
// the app can restore straight to the desktop.
//
//   node boot-snapshot.mjs --bios DIR --img IMG --state OUT.state --logs DIR [--timeout-min 60]
//
// Writes OUT.state (uncompressed v86 state), DIR/boot-report.json,
// DIR/boot-serial.log, DIR/guest-info.txt and DIR/desktop-boot.png.
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import {
    MEMORY_MB, SerialConsole, X_ENV, createEmulator, fmtSec, machineOptions, saveScreen, sleep, started, v86Version, vgaInfo,
    watchHardware,
} from "./v86-common.mjs";

const { values: a } = parseArgs({
    options: {
        bios: { type: "string" },
        img: { type: "string" },
        state: { type: "string" },
        logs: { type: "string" },
        "timeout-min": { type: "string", default: "60" },
    },
});
for (const k of ["bios", "img", "state", "logs"]) if (!a[k]) throw new Error(`missing --${k}`);
fs.mkdirSync(a.logs, { recursive: true });

const t0 = Date.now();
const deadline = t0 + Number(a["timeout-min"]) * 60_000;
const report = {
    startedAt: new Date(t0).toISOString(),
    v86: v86Version(),
    node: process.version,
    machine: machineOptions(),
    memoryMB: MEMORY_MB,
    steps: {},
};
const mark = (name) => {
    report.steps[name] = fmtSec(Date.now() - t0);
    console.log(`\n[${report.steps[name]}s] ${name}`);
};
const left = () => Math.max(1000, deadline - Date.now());
const info = [];

const emulator = createEmulator({ biosDir: a.bios, imgPath: a.img });
const hw = watchHardware(emulator);
const con = new SerialConsole(emulator, path.join(a.logs, "boot-serial.log"));
report.hardware = hw;
// Live progress for the CI log: the serial console, line by line.
let lineBuf = "";
emulator.add_listener("serial0-output-byte", (b) => {
    const c = String.fromCharCode(b);
    if (c === "\n") { console.log("| " + lineBuf.replace(/\r/g, "")); lineBuf = ""; } else lineBuf += c;
});

async function guest(title, cmd, opts) {
    const r = await con.sh(cmd, opts);
    info.push(`### ${title}\n$ ${cmd}\n${r.out}\n(exit ${r.code})\n`);
    return r;
}

async function main() {
    await started(emulator);
    mark("emulator started");

    await con.waitFor(/login: ?$/m, { timeoutMs: left(), what: "the ttyS0 login prompt" });
    mark("login prompt");
    let from = con.text.length;
    con.send("z\n");
    await con.waitFor(/Password: ?$/m, { from, timeoutMs: 120_000, what: "the password prompt" });
    from = con.text.length;
    con.send("z\n");
    await con.waitFor(/\$ ?$/m, { from, timeoutMs: 300_000, what: "the shell prompt" });
    await con.sh("stty -echo; export PS1=; unset HISTFILE", { timeoutMs: 300_000 });
    await con.ok("sudo dmesg -n 1");
    mark("logged in on ttyS0");

    // The desktop: Xorg (LightDM), the XFCE session and its three main clients.
    const procs = ["Xorg", "lightdm", "xfce4-session", "xfwm4", "xfce4-panel", "xfdesktop"];
    let seen = "";
    for (;;) {
        const r = await con.sh(`for p in ${procs.join(" ")}; do pgrep -x $p >/dev/null && printf '%s ' $p; done; echo`, { timeoutMs: left() });
        const running = r.out.trim();
        if (running !== seen) {
            console.log(`\n[${fmtSec(Date.now() - t0)}s] running: ${running || "(none yet)"}`);
            seen = running;
        }
        if (running.includes("xfce4-session") && !report.steps["xfce4-session running"]) mark("xfce4-session running");
        if (procs.every((p) => running.split(/\s+/).includes(p))) break;
        if (Date.now() > deadline) throw new Error(`desktop did not start; running: ${running}`);
        await sleep(5000);
    }
    mark("desktop processes up");

    for (;;) {
        const r = await con.sh(
            `${X_ENV} xdotool search --onlyvisible --class xfce4-panel >/dev/null 2>&1 && ${X_ENV} xdotool search --onlyvisible --class xfdesktop >/dev/null 2>&1`,
            { timeoutMs: left() });
        if (r.code === 0) break;
        if (Date.now() > deadline) throw new Error("panel/desktop windows never became visible");
        await sleep(3000);
    }
    mark("desktop windows visible");
    report.bootToDesktopSec = report.steps["desktop windows visible"];

    // Let first-start work finish (icon caches, panel plugins): wait for an idle CPU.
    const cpu = async () => (await con.ok("head -1 /proc/stat")).trim().split(/\s+/).slice(1).map(Number);
    let idleStreak = 0;
    for (let i = 0; i < 30 && idleStreak < 2; i++) {
        const s1 = await cpu();
        await sleep(5000);
        const s2 = await cpu();
        const d = s2.map((v, j) => v - s1[j]);
        const total = d.reduce((x, y) => x + y, 0) || 1;
        const idle = (d[3] + (d[4] || 0)) / total;
        idleStreak = idle > 0.85 ? idleStreak + 1 : 0;
        console.log(`  guest cpu idle ${(idle * 100).toFixed(0)}%`);
    }
    mark("desktop settled");
    report.bootToSettledSec = report.steps["desktop settled"];

    await guest("image", "cat /etc/zcomputer-image; uname -a; cat /proc/cmdline");
    await guest("memory + disk", "free -m; df -h / /tmp /mnt/host 2>/dev/null");
    await guest("services", "rc-status -a 2>/dev/null | grep -v '^ *$'");
    await guest("framebuffer", "cat /proc/fb; cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/bits_per_pixel");
    await guest("X display", `${X_ENV} xdotool getdisplaygeometry; ${X_ENV} xset q | grep -iE 'timeout|DPMS is|Standby'`);
    await guest("Xorg errors/warnings", "grep -E '\\((EE|WW)\\)' /var/log/Xorg.0.log | head -40");
    await guest("Xorg input", "grep -iE 'input driver|vmmouse|Adding input' /var/log/Xorg.0.log | head -30");
    await guest("input devices", "grep -E '^N: Name' /proc/bus/input/devices");
    await guest("kernel: devices", "sudo dmesg | grep -iE 'vmmouse|vmware|bochs|fb0|9p|virtio|ata|psmouse|hypervisor' | head -60");
    await guest("session (elogind)", "loginctl list-sessions --no-legend 2>&1 | head; echo DISPLAY env of xfce4-session:; sudo cat /proc/$(pgrep -x xfce4-session)/environ | tr '\\0' '\\n' | grep -E '^(DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|XDG_SESSION_TYPE)='");
    await guest("host share", "mount | grep -E ' /mnt/host |9p'; ls -la /mnt/host");
    await guest("network", "ip -4 addr; cat /etc/resolv.conf 2>/dev/null; pgrep -a udhcpc");
    await guest("top memory users", "ps -eo rss,user,comm --sort=rss | tail -20");
    const ping = await guest("zguest ping", "zg ping");
    if (ping.code !== 0) throw new Error(`zguest ping failed:\n${ping.out}`);
    await guest("zguest sysinfo", "zg sysinfo");
    const shot = await guest("zguest screenshot", "zg --png /mnt/host/desktop-boot.png screenshot");
    if (shot.code === 0) {
        const png = await emulator.read_file("/desktop-boot.png");
        fs.writeFileSync(path.join(a.logs, "desktop-boot.png"), Buffer.from(png));
        await con.sh("rm -f /mnt/host/desktop-boot.png");
    }
    fs.writeFileSync(path.join(a.logs, "guest-info.txt"), info.join("\n"));

    // Snapshot: drop the page cache (init_on_free=1 zeroes freed pages, which
    // compresses away) and leave a normal interactive shell on ttyS0.
    await con.ok("sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null");
    await sleep(2000);
    await con.sh("stty echo; export PS1='\\u@\\h:\\w\\$ '");
    await sleep(1500);
    // v86's own display at the moment of the snapshot (the VGA "screen-set-size"
    // events alone can miss a return to the SVGA mode of the same size).
    report.vgaAtSave = vgaInfo(emulator);
    saveScreen(emulator, path.join(a.logs, "v86-screen-boot.png"));
    if (!report.vgaAtSave?.graphical || !report.vgaAtSave?.svga) {
        throw new Error(`v86 VGA is not on the SVGA framebuffer at save time: ${JSON.stringify(report.vgaAtSave)}`);
    }
    const ts = Date.now();
    const state = await emulator.save_state();
    fs.writeFileSync(a.state, Buffer.from(state));
    report.saveStateSec = fmtSec(Date.now() - ts);
    report.stateBytes = state.byteLength;
    mark("state saved");
}

let failed = null;
try {
    await main();
} catch (e) {
    failed = e;
    console.error(`\nFAILED: ${e.stack || e}`);
    if (info.length) fs.writeFileSync(path.join(a.logs, "guest-info.txt"), info.join("\n"));
}
report.instructions = emulator.get_instruction_counter();
report.ok = !failed;
report.error = failed ? String(failed.message || failed) : undefined;
report.finishedAt = new Date().toISOString();
fs.writeFileSync(path.join(a.logs, "boot-report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ ok: report.ok, steps: report.steps, screen: hw.screen, vmwareAbsoluteMouse: hw.vmwareAbsoluteMouse, stateBytes: report.stateBytes }, null, 2));
con.close();
emulator.stop();
setTimeout(() => process.exit(failed ? 1 : 0), 500);
