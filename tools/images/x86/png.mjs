// Minimal PNG encode/decode (8-bit RGB/RGBA, non-interlaced) with node:zlib,
// enough to save v86's framebuffer and compare it with the guest's screenshot.
import zlib from "node:zlib";

const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const CRC_TABLE = new Int32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c;
});
function crc32(buf) {
    let c = -1;
    for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
}

function chunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
}

/** RGB bytes (width*height*3) -> PNG file bytes. */
export function encodePng(width, height, rgb) {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type RGB
    const raw = Buffer.alloc((width * 3 + 1) * height);
    for (let y = 0; y < height; y++) {
        raw[y * (width * 3 + 1)] = 0; // filter: none
        rgb.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
    }
    return Buffer.concat([SIG, chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw, { level: 6 })), chunk("IEND", Buffer.alloc(0))]);
}

/** PNG file bytes -> { width, height, rgb } (8-bit RGB or RGBA input, no interlace). */
export function decodePng(buf) {
    if (!buf.subarray(0, 8).equals(SIG)) throw new Error("not a PNG");
    let off = 8, width = 0, height = 0, ctype = 0;
    const idat = [];
    while (off < buf.length) {
        const len = buf.readUInt32BE(off);
        const type = buf.toString("latin1", off + 4, off + 8);
        const data = buf.subarray(off + 8, off + 8 + len);
        if (type === "IHDR") {
            width = data.readUInt32BE(0);
            height = data.readUInt32BE(4);
            ctype = data[9];
            if (data[8] !== 8 || (ctype !== 2 && ctype !== 6) || data[12] !== 0) {
                throw new Error(`unsupported PNG: depth ${data[8]} colour type ${ctype} interlace ${data[12]}`);
            }
        } else if (type === "IDAT") idat.push(data);
        else if (type === "IEND") break;
        off += 12 + len;
    }
    const bpp = ctype === 6 ? 4 : 3;
    const stride = width * bpp;
    const raw = zlib.inflateSync(Buffer.concat(idat));
    const px = Buffer.alloc(stride * height);
    for (let y = 0; y < height; y++) {
        const f = raw[y * (stride + 1)];
        const src = y * (stride + 1) + 1;
        const cur = y * stride, prev = cur - stride;
        for (let x = 0; x < stride; x++) {
            const a = x >= bpp ? px[cur + x - bpp] : 0;
            const b = y > 0 ? px[prev + x] : 0;
            const c = x >= bpp && y > 0 ? px[prev + x - bpp] : 0;
            let p = raw[src + x];
            if (f === 1) p += a;
            else if (f === 2) p += b;
            else if (f === 3) p += (a + b) >> 1;
            else if (f === 4) {
                const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
                p += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
            }
            px[cur + x] = p & 0xff;
        }
    }
    if (bpp === 3) return { width, height, rgb: px };
    const rgb = Buffer.alloc(width * height * 3);
    for (let i = 0, j = 0; i < px.length; i += 4, j += 3) {
        rgb[j] = px[i];
        rgb[j + 1] = px[i + 1];
        rgb[j + 2] = px[i + 2];
    }
    return { width, height, rgb };
}
