// Key images drawn as SVG data URIs (144x144, scaled by Stream Deck). No per-state PNG files.

import type { HeadsetStatus } from "./store";

export const C = {
	offline: "#2d2d30",
	noAdb: "#a8650b",
	online: "#21804a",
	live: "#1f5fa8",
	starting: "#5a3fa8",
	rec: "#d32626",
	unplugged: "#ff8c00",
	lowText: "#ff3b30",
	server: "#111111",
	idle: "#3a3f47",
	warn: "#b7791f",
	danger: "#8f1d1d",
	ok: "#21804a",
	text: "#ffffff",
	dim: "#9aa0a6",
};

function esc(s: string): string {
	return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Shrinks the font so `text` fits ~130 px. */
function fit(text: string, max: number): number {
	const len = Math.max(1, text.length);
	return Math.max(14, Math.min(max, Math.floor(240 / len)));
}

export type KeyFace = {
	bg: string;
	top?: string; // small line at top (headset name)
	main?: string; // big centre text
	bottom?: string; // small line at bottom
	border?: string; // coloured frame (recording)
	dot?: string; // small dot top-right (REC)
	icon?: string; // inline SVG path content drawn in the centre (24x24 viewBox)
	shape?: string; // raw SVG content in 144x144 key coordinates, drawn like an icon
	image?: string; // data URI drawn behind the text (app icon)
	imageInset?: boolean; // smaller image between the top and bottom lines
	mainColor?: string;
	textColor?: string; // colour of the top and bottom lines (default white)
	bottomColor?: string; // colour of the bottom line only (overrides textColor)
	bottomBold?: boolean;
};

export function face(f: KeyFace): string {
	const parts: string[] = [];
	parts.push(`<rect width="144" height="144" rx="14" fill="${f.bg}"/>`);
	if (f.image) {
		// inset: between the top and bottom text lines (status key showing the running game).
		const box = f.imageInset ? `x="38" y="40" width="68" height="68"` : `x="22" y="14" width="100" height="100"`;
		parts.push(`<image href="${f.image}" ${box} preserveAspectRatio="xMidYMid meet"/>`);
	}
	if (f.border) parts.push(`<rect x="5" y="5" width="134" height="134" rx="12" fill="none" stroke="${f.border}" stroke-width="10"/>`);
	if (f.icon) parts.push(`<g transform="translate(42,34) scale(2.5)" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${f.icon}</g>`);
	if (f.shape) parts.push(f.shape);
	if (f.dot) parts.push(`<circle cx="120" cy="24" r="11" fill="${f.dot}" stroke="#fff" stroke-width="2"/>`);
	const font = "font-family=\"Segoe UI, Arial, sans-serif\" text-anchor=\"middle\"";
	if (f.top) parts.push(`<text x="72" y="32" ${font} font-size="${fit(f.top, 24)}" font-weight="600" fill="${f.textColor ?? C.text}">${esc(f.top)}</text>`);
	if (f.main) {
		// icon + bottom line: main text sits between them so the two do not overlap.
		const pic = !!(f.icon || f.shape);
		const y = pic ? (f.bottom ? 110 : 118) : 86;
		const size = pic ? fit(f.main, f.bottom ? 18 : 22) : fit(f.main, 40);
		parts.push(`<text x="72" y="${y}" ${font} font-size="${size}" font-weight="700" fill="${f.mainColor ?? C.text}">${esc(f.main)}</text>`);
	}
	if (f.bottom) parts.push(`<text x="72" y="134" ${font} font-size="${fit(f.bottom, (f.icon || f.shape) && f.main ? 16 : 22)}" ${f.bottomBold ? "font-weight=\"800\" " : ""}fill="${f.bottomColor ?? f.textColor ?? C.text}" opacity="${f.bottomColor ? 1 : 0.9}">${esc(f.bottom)}</text>`);
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">${parts.join("")}</svg>`;
	return "data:image/svg+xml;charset=utf8," + encodeURIComponent(svg);
}

/** Feather-style icons (24x24), stroke only. */
export const ICONS = {
	camera: `<path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>`,
	play: `<polygon points="5 3 19 12 5 21 5 3"/>`,
	stop: `<rect x="5" y="5" width="14" height="14"/>`,
	pause: `<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>`,
	rec: `<circle cx="12" cy="12" r="8"/>`,
	back: `<polyline points="15 18 9 12 15 6"/>`,
	home: `<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`,
	refresh: `<polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>`,
	volUp: `<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"/>`,
	volDown: `<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/>`,
	sun: `<circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/>`,
	sunDim: `<circle cx="12" cy="12" r="5"/>`,
	grid: `<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>`,
	x: `<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>`,
	eye: `<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>`,
	maximize: `<path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/>`,
	monitor: `<rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>`,
	power: `<path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/>`,
	reboot: `<polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>`,
	ui: `<rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="9" y1="21" x2="9" y2="9"/>`,
	gear: `<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>`,
	shield: `<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>`,
	hand: `<path d="M18 11V6a2 2 0 0 0-4 0v5M14 10V4a2 2 0 0 0-4 0v6M10 10.5V6a2 2 0 0 0-4 0v8a8 8 0 0 0 16 0v-3a2 2 0 0 0-4 0"/>`,
	tap: `<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/>`,
	coffee: `<path d="M18 8h1a4 4 0 0 1 0 8h-1M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8zM6 1v3M10 1v3M14 1v3"/>`,
	sharp: `<polygon points="12 2 22 12 12 22 2 12 12 2"/>`,
	hz: `<polyline points="2 12 6 12 9 3 15 21 18 12 22 12"/>`,
	lock: `<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>`,
	timer: `<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M9 2h6"/>`,
};

/** Status colour + label of a headset. */
export function headsetLook(st: HeadsetStatus | undefined): { bg: string; label: string } {
	if (!st) return { bg: C.offline, label: "?" };
	if (st.scrcpy_starting) return { bg: C.starting, label: "START" };
	if (st.scrcpy) return { bg: C.live, label: "LIVE" };
	if (st.adb) return { bg: C.online, label: "READY" };
	if (st.ping) return { bg: C.noAdb, label: "NO ADB" };
	return { bg: C.offline, label: "OFF" };
}

export function batteryText(st: HeadsetStatus | undefined): string {
	if (!st) return "";
	const b = String(st.battery ?? "").replace(/\s+/g, "");
	if (!b || b === "-") return "";
	return (st.charging ? "+" : "") + b;
}
