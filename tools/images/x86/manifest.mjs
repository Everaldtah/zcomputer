#!/usr/bin/env node
// Writes manifest.json and README.md for the z-alpine-desktop-x86 artifact.
//
//   node manifest.mjs --out ARTIFACT_DIR --img RAW_IMG --state RAW_STATE --logs LOGS_DIR \
//        --build-info build-info.txt --bios BIOS_DIR --v86-commit SHA --version VERSION
//
// ARTIFACT_DIR must already hold z-alpine-desktop-x86.{img,state}.xz.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { MEMORY_MB, VGA_MEMORY_MB, machineOptions, v86Version } from "./v86-common.mjs";

const { values: a } = parseArgs({
    options: Object.fromEntries(["out", "img", "state", "logs", "build-info", "bios", "v86-commit", "version"].map((k) => [k, { type: "string" }])),
});
for (const k of ["out", "img", "state", "logs", "build-info", "bios", "v86-commit", "version"]) if (!a[k]) throw new Error(`missing --${k}`);

const ID = "z-alpine-desktop-x86";
const REPO = process.env.GITHUB_REPOSITORY || "Everaldtah/zcomputer";
const TAG = "images-v1";
const BASE_URL = `https://github.com/${REPO}/releases/download/${TAG}/`;

async function sha256(file) {
    const h = crypto.createHash("sha256");
    for await (const chunk of fs.createReadStream(file, { highWaterMark: 8 << 20 })) h.update(chunk);
    return h.digest("hex");
}
const size = (f) => fs.statSync(f).size;
const readJson = (f) => (fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {});
const info = Object.fromEntries(
    fs.readFileSync(a["build-info"], "utf8").split("\n").filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
);
const boot = readJson(path.join(a.logs, "boot-report.json"));
const smoke = readJson(path.join(a.logs, "smoke-report.json"));

async function fileEntry(kind, raw) {
    const name = `${ID}.${kind}.xz`;
    const xz = path.join(a.out, name);
    return {
        name,
        url: BASE_URL + name,
        compression: "xz",
        sizeBytes: size(xz),
        sha256: await sha256(xz),
        decompressedBytes: size(raw),
        decompressedSha256: await sha256(raw),
    };
}

const img = await fileEntry("img", a.img);
const state = await fileEntry("state", a.state);
const diskBytes = size(a.img);
const opts = machineOptions();
const bios = {
    name: "seabios.bin",
    sha256: await sha256(path.join(a.bios, "seabios.bin")),
    url: `https://raw.githubusercontent.com/copy/v86/${a["v86-commit"]}/bios/seabios.bin`,
};
const vgaBios = {
    name: "vgabios.bin",
    sha256: await sha256(path.join(a.bios, "vgabios.bin")),
    url: `https://raw.githubusercontent.com/copy/v86/${a["v86-commit"]}/bios/vgabios.bin`,
};

const notes = [
    `Alpine Linux ${info.alpine} (i686), kernel ${info.kernel}, ${info.packages} packages; XFCE ${"4.20"} on Xorg (fbdev on bochs-drm), LightDM autologin as z.`,
    "The state only restores with the pristine image (img.decompressedSha256) as v86's hda, loaded asynchronously (async: true or a File), so guest writes stay in memory; never write guest changes back into the image if you want to restore this state again.",
    `Restore with the same v86 build (${v86Version()}, ${a["v86-commit"].slice(0, 7)}), the same BIOS files and the machine options in v86.options; v86 needs a 9p filesystem option (e.g. filesystem: {} or handle9p) because the state was taken with one.`,
    "Pass preserve_mac_from_state_image: true (or run z-net-reset in the guest after restoring) so the guest's virtio-net MAC matches; DHCP (udhcpc) keeps retrying in the background until a network backend answers.",
    "The guest clock is the build time after a restore; set it from the host, e.g. `sudo date -s @<unix-seconds>` on the serial console or through zguest exec.",
    "ttyS0 is a logged-in bash for user z (115200 8N1): send a newline and commands; sudo needs no password.",
    "zguest listens on 127.0.0.1:5555 inside the guest (no vsock in v86); /usr/local/bin/zg sends one request (zg ping, zg sysinfo, zg --png FILE screenshot).",
    "OpenGL is not available: Mesa's gallium drivers and LLVM were removed to save ~350 MB (sudo apk fix mesa llvm20-libs restores them).",
];

const manifest = {
    version: a.version,
    builtAt: new Date().toISOString(),
    baseUrl: BASE_URL,
    images: [
        {
            id: ID,
            name: "Z Alpine Desktop (x86)",
            arch: "x86",
            format: "raw",
            diskBytes,
            partition: { table: "mbr", root: "/dev/sda1", fs: "ext4", startSector: 2048 },
            files: { img, state },
            memoryMB: MEMORY_MB,
            vgaMemoryMB: VGA_MEMORY_MB,
            screen: { w: 1024, h: 768 },
            user: "z",
            password: "z",
            desktop: "xfce-x11",
            agentPort: 5555,
            agentAddress: "127.0.0.1:5555",
            serial: { port: "ttyS0", baud: 115200, loggedIn: true },
            hostShare: { type: "9p", mountTag: "host9p", mountPoint: "/mnt/host" },
            os: { distro: "alpine", version: info.alpine, kernel: info.kernel, packages: Number(info.packages) },
            browser: "netsurf",
            emulator: {
                name: "v86",
                npm: `v86@${v86Version().split("+")[0]}`,
                commit: a["v86-commit"],
                bios,
                vgaBios,
                options: {
                    memory_size: opts.memory_size,
                    vga_memory_size: opts.vga_memory_size,
                    net_device: opts.net_device,
                    filesystem: opts.filesystem,
                    acpi: opts.acpi,
                    hda: { async: true, size: diskBytes },
                    preserve_mac_from_state_image: true,
                },
            },
            bootToDesktopSec: boot.bootToDesktopSec,
            bootToSettledSec: boot.bootToSettledSec,
            restoreToShellSec: smoke.restoreToShellSec,
            measuredOn: "GitHub Actions ubuntu-latest, Node " + (boot.node || process.version) + ", v86 JIT",
            notes,
        },
    ],
};
fs.writeFileSync(path.join(a.out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

const mb = (n) => (n / 1e6).toFixed(1) + " MB";
const checks = (smoke.checks || []).map((c) => `| ${c.pass ? "pass" : "FAIL"} | ${c.name} |`).join("\n");
const readme = `# Z Alpine Desktop (x86) — ${a.version}

A small 32-bit Alpine Linux disk image with an agent-ready XFCE desktop for the
[v86](https://github.com/copy/v86) WebAssembly x86 emulator, plus a v86 saved
state taken at the finished desktop so an app restores straight to it.

| file | size | decompressed | sha256 (compressed) |
|---|---|---|---|
| \`${img.name}\` | ${mb(img.sizeBytes)} | ${mb(img.decompressedBytes)} raw disk | \`${img.sha256}\` |
| \`${state.name}\` | ${mb(state.sizeBytes)} | ${mb(state.decompressedBytes)} v86 state | \`${state.sha256}\` |
| \`manifest.json\` | | | machine-readable version of this page |

Decompressed sha256: image \`${img.decompressedSha256}\`, state \`${state.decompressedSha256}\`.
Both files are standard \`.xz\` (LZMA2, \`xz -T0 -9\`).

* **System:** Alpine Linux ${info.alpine} (x86), ${info.kernel}, ${info.packages} packages, ${info.fs_used_mib} MiB used of a ${(diskBytes / 2 ** 20).toFixed(0)} MiB disk (MBR, ext4 on /dev/sda1, extlinux).
* **Desktop:** XFCE on Xorg (X11, display \`:0\`), 1024×768×32, LightDM autologin as \`z\`; no screensaver, locker or DPMS. NetSurf browser, xfce4-terminal, Thunar.
* **Login:** user \`z\`, password \`z\`, passwordless sudo. The serial console (ttyS0, 115200) is a logged-in shell in the saved state.
* **Agent:** \`zguest\` (Z Computer guest agent) on \`127.0.0.1:5555\`, newline-delimited JSON (guest-agent/PROTOCOL.md); \`scrot\` screenshots, \`xdotool\` input, \`xclip\`. \`zg ping\` talks to it from a guest shell.
* **Host share:** v86's 9p filesystem (mount tag \`host9p\`) at \`/mnt/host\`.
* **Boot to desktop** (v86 under Node on a GitHub runner): ${boot.bootToDesktopSec ?? "?"} s to the visible desktop, ${boot.bootToSettledSec ?? "?"} s until idle. **Restore to a working shell:** ${smoke.restoreToShellSec ?? "?"} s.

## Restoring the state in v86

\`\`\`js
const emulator = new V86({
  wasm_path: "v86.wasm",                       // v86 ${v86Version()} (commit ${a["v86-commit"].slice(0, 7)})
  bios: { url: "seabios.bin" },                // sha256 ${bios.sha256}
  vga_bios: { url: "vgabios.bin" },            // sha256 ${vgaBios.sha256}
  memory_size: ${opts.memory_size},              // ${MEMORY_MB} MiB
  vga_memory_size: ${opts.vga_memory_size},           // ${VGA_MEMORY_MB} MiB
  hda: { url: "z-alpine-desktop-x86.img", async: true, size: ${diskBytes} },
  net_device: { type: "virtio", relay_url: "fetch" },   // or any backend
  preserve_mac_from_state_image: true,
  filesystem: {},                               // required: the state has a 9p device
  initial_state: { url: "z-alpine-desktop-x86.state" },
  autostart: true,
});
\`\`\`

${notes.map((n) => `* ${n}`).join("\n")}

## Smoke test of this build (restored from the .xz files)

| result | check |
|---|---|
${checks}

Built by \`.github/workflows/images.yml\` in ${REPO}; published with \`tools/images/publish.sh\`.
Release URLs: \`${BASE_URL}<file>\`.
`;
fs.writeFileSync(path.join(a.out, "README.md"), readme);
console.log(JSON.stringify({ img, state, diskBytes }, null, 2));
