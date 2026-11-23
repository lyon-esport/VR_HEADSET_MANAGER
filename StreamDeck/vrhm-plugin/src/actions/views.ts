// Screen profile page, opened by the "size" command of the headset page. Acts on the selected
// headset; the page stays open so the operator can set the eye AND the view.
//   kind "eye"  : eye L / R / M (M = both eyes merged, only when the model is calibrated)
//   kind "view" : N-th view of the headset model (GET /api/scrcpyviews)
// Both rewrite the headset's scrcpy profile "view-EYE-AUDIO-FPS-BW" through /api/updateprofile.

import streamDeck, { action } from "@elgato/streamdeck";
import { displayName, get, post } from "../api";
import { KeyCtx, VrhmAction } from "../common";
import { C, ICONS, face } from "../render";
import { type Headset, store } from "../store";
import { parseProfile } from "./command";

type ViewSettings = { kind?: "eye" | "view"; eye?: string; index?: number };

// Views + eye-merge support + crop geometry per model, cached 30 s.
type Crop = { w: number; h: number; x: number; y: number; angle: number };
type ViewGeo = { L?: Crop; R?: Crop };
type ModelInfo = { at: number; views: string[]; merge: boolean; geo: Record<string, ViewGeo>; fw: number; fh: number };

function parseCrop(c: any): Crop | undefined {
	const m = /^(\d+):(\d+):(\d+):(\d+)$/.exec(String(c?.crop ?? "").trim());
	if (!m) return undefined;
	return { w: +m[1], h: +m[2], x: +m[3], y: +m[4], angle: Number(c?.angle) || 0 };
}

/** scrcpy.parameters entry of a model from the server config (exact key, else model_codes). */
function modelTemplate(cfg: any, model: string): any {
	const params = cfg?.scrcpy?.parameters;
	if (!params || typeof params !== "object") return undefined;
	if (params[model]) return params[model];
	const low = model.toLowerCase();
	for (const k of Object.keys(params)) {
		const t = params[k];
		if (k.toLowerCase() === low) return t;
		const codes = Array.isArray(t?.model_codes) ? t.model_codes : [];
		if (codes.some((c: any) => String(c).toLowerCase() === low)) return t;
	}
	return undefined;
}

function geometry(cfg: any, model: string): { geo: Record<string, ViewGeo>; fw: number; fh: number } {
	const t = modelTemplate(cfg, model);
	const geo: Record<string, ViewGeo> = {};
	let fw = Number(t?.eye_merge?.frame_width) || 0;
	let fh = Number(t?.eye_merge?.frame_height) || 0;
	let maxX = 0;
	let maxY = 0;
	for (const [name, v] of Object.entries<any>(t?.views ?? {})) {
		const L = parseCrop(v?.left_eye);
		const R = parseCrop(v?.right_eye);
		geo[name] = { L, R };
		for (const c of [L, R]) if (c) { maxX = Math.max(maxX, c.x + c.w); maxY = Math.max(maxY, c.y + c.h); }
	}
	// No calibration: guess the frame from the crops (two square-ish eyes side by side).
	if (!fw || !fh) {
		fw = maxX > 0 ? maxX * 1.05 : 2;
		fh = maxY > 0 ? maxY * 1.05 : 1;
	}
	return { geo, fw, fh };
}
const modelCache = new Map<string, ModelInfo>();
const modelLoading = new Set<string>();

async function loadModel(model: string): Promise<void> {
	if (modelLoading.has(model)) return;
	const c = modelCache.get(model);
	if (c && Date.now() - c.at < 30000) return;
	modelLoading.add(model);
	try {
		const q = encodeURIComponent(model);
		const [v, m, c] = await Promise.all([
			get<string[] | string>(`/api/scrcpyviews?model=${q}`),
			get<{ enabled?: boolean }>(`/api/eye-merge?model=${q}&light=1`),
			get<any>("/api/config"),
		]);
		// A one-element JSON array comes back from PowerShell as a bare string.
		const views = Array.isArray(v.data) ? v.data : typeof v.data === "string" ? [v.data] : [];
		if (v.ok || views.length) {
			modelCache.set(model, { at: Date.now(), views, merge: !!m.data?.enabled, ...geometry(c.data, model) });
			store.emit("change");
		}
	} finally {
		modelLoading.delete(model);
	}
}

/**
 * Picture of a view: one screen form with the aspect of the picture the view sends (crop of the
 * eye in use, width:height), e.g. a square, a portrait or a wide rectangle. Fullscreen (no crop)
 * is the whole headset frame: a wide rectangle holding the two eyes.
 */
function viewShape(info: ModelInfo, view: string, eye: string): string | undefined {
	const g = info.geo[view];
	if (!g) return undefined;
	const r = (v: number) => Math.round(v * 10) / 10;
	const c = (eye === "L" ? g.L : g.R) ?? g.R ?? g.L;
	const full = !c || c.w <= 0 || c.h <= 0;
	// Illustration, not to scale: a fixed form per known view name; an unknown view uses its
	// crop aspect (squared so small differences still show).
	const n = view.toLowerCase();
	const named: Record<string, number> = { square: 1, portrait: 0.6, wide: 2.1, max: 1.45 };
	const key = Object.keys(named).find((k) => n.includes(k));
	const a = full ? Math.max(1.7, info.fw / info.fh) : key ? named[key] : Math.pow(c.w / c.h, 2);
	const aw = a;
	const ah = 1;
	const s = Math.min(112 / aw, 56 / ah);
	const w = aw * s;
	const h = ah * s;
	const x = 72 - w / 2;
	const y = 68 - h / 2;
	if (!full) return `<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" rx="4" fill="#fff" opacity="0.9"/>`;
	const gap = 4;
	const ew = (w - 3 * gap) / 2;
	return (
		`<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" rx="5" fill="none" stroke="#fff" stroke-width="2.5" opacity="0.9"/>` +
		`<rect x="${r(x + gap)}" y="${r(y + gap)}" width="${r(ew)}" height="${r(h - 2 * gap)}" rx="3" fill="#fff" opacity="0.9"/>` +
		`<rect x="${r(x + 2 * gap + ew)}" y="${r(y + gap)}" width="${r(ew)}" height="${r(h - 2 * gap)}" rx="3" fill="#fff" opacity="0.9"/>`
	);
}

const DEFAULT_PROFILE = { view: "square", eye: "R", audio: "N", fps: "45", bw: "20" };
// Same default as Get-EyeMergeFpsAdvice: the merge costs CPU per frame.
const MERGED_FPS = 30;

@action({ UUID: "com.lyonesport.vrhm.view" })
export class ViewSlotAction extends VrhmAction<ViewSettings> {
	private headset(): Headset | undefined {
		return store.headsetById(store.selectedId);
	}

	private kind(k: KeyCtx<ViewSettings>): "eye" | "view" {
		return k.settings.kind === "eye" ? "eye" : "view";
	}

	private eye(k: KeyCtx<ViewSettings>): string {
		const e = String(k.settings.eye ?? "R").toUpperCase();
		return ["L", "R", "M"].includes(e) ? e : "R";
	}

	/**
	 * View slot number. On the 5-wide Screen page it follows the key position (row 1 = eyes,
	 * rows 2-3 = views 1..10), so an older installed copy of the page still shows the right
	 * layout; 0 = no view (blank key). Elsewhere the "index" setting is used.
	 */
	private index(k: KeyCtx<ViewSettings>): number {
		if (k.row >= 0 && k.column >= 0 && k.column < 5 && k.row < 3) return k.row === 0 ? 0 : (k.row - 1) * 5 + k.column + 1;
		const n = Number(k.settings.index);
		return Number.isFinite(n) && n >= 1 ? Math.floor(n) : 1;
	}

	protected override appeared(): void {
		const h = this.headset();
		if (h) void loadModel(h.Model ?? "");
	}

	protected draw(k: KeyCtx<ViewSettings>): Promise<void> {
		const h = this.headset();
		if (!h) return this.paint(k, face({ bg: C.server }));
		const info = modelCache.get(h.Model ?? "");
		if (!info) {
			void loadModel(h.Model ?? "");
			return this.paint(k, face({ bg: C.server, main: "...", mainColor: C.dim }));
		}
		const p = parseProfile(h.ScrcpyProfile);
		const busy = store.busy.has(k.action.id);
		if (this.kind(k) === "eye") {
			const e = this.eye(k);
			const label = e === "L" ? "LEFT" : e === "R" ? "RIGHT" : "MERGED";
			if (e === "M" && !info.merge) {
				return this.paint(k, face({ bg: C.server, icon: ICONS.eye, main: label, bottom: "not calibrated", mainColor: C.dim, textColor: C.dim }));
			}
			const on = p?.eye === e;
			return this.paint(
				k,
				face({ bg: on ? C.live : C.idle, top: "EYE", icon: ICONS.eye, main: label, border: on ? C.ok : undefined, bottom: busy ? "..." : undefined }),
			);
		}
		const view = info.views[this.index(k) - 1];
		if (!view) return this.paint(k, face({ bg: C.server }));
		const on = p?.view === view;
		return this.paint(
			k,
			face({ bg: on ? C.live : C.idle, top: "VIEW", ...((sh) => (sh ? { shape: sh } : { icon: ICONS.maximize }))(viewShape(info, view, p?.eye ?? "R")), main: view.toUpperCase(), border: on ? C.ok : undefined, bottom: busy ? "..." : undefined }),
		);
	}

	protected async press(k: KeyCtx<ViewSettings>): Promise<void> {
		const h = this.headset();
		const info = h ? modelCache.get(h.Model ?? "") : undefined;
		if (!h || !info || store.busy.has(k.action.id)) return k.action.showAlert();
		const p = parseProfile(h.ScrcpyProfile) ?? { ...DEFAULT_PROFILE };
		if (this.kind(k) === "eye") {
			const e = this.eye(k);
			if (e === "M" && !info.merge) return k.action.showAlert();
			p.eye = e;
			if (e === "M" && Number(p.fps) > MERGED_FPS) p.fps = String(MERGED_FPS);
		} else {
			const view = info.views[this.index(k) - 1];
			if (!view) return k.action.showAlert();
			p.view = view;
		}
		const profile = `${p.view}-${p.eye}-${p.audio}-${p.fps}-${p.bw}`;
		if (profile === h.ScrcpyProfile) return k.action.showOk();
		store.busy.add(k.action.id);
		void this.safeDraw(k);
		let ok = false;
		try {
			const r = await post("/api/updateprofile", { name: displayName(h.Name), profile }, 20000);
			ok = r.ok;
			if (ok) h.ScrcpyProfile = profile;
			else streamDeck.logger.warn(`updateprofile failed: ${r.error}`);
		} finally {
			store.busy.delete(k.action.id);
		}
		store.emit("change");
		store.refreshSoon();
		if (ok) await k.action.showOk();
		else await k.action.showAlert();
	}
}
