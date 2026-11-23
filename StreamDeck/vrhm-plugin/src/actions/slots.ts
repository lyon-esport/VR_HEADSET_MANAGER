// Dynamic pages opened from the headset config page:
//   app slot   : N-th favourite app of the selected headset (GET /api/favoriteapps), press = launch
//   kiosk slot : N-th kiosk screen (GET /api/kiosks), press = cast the selected headset on it
// The `index` setting (1-based) picks the item; the template profiles number them in order.

import streamDeck, { action } from "@elgato/streamdeck";
import { displayName, fetchDataUri, get, getServerUrl, post } from "../api";
import { KeyCtx, PROFILES, VrhmAction, switchTo } from "../common";
import { C, face } from "../render";
import { store } from "../store";

type SlotSettings = { index?: number };

function slotIndex(k: KeyCtx<SlotSettings>): number {
	const n = Number(k.settings.index);
	if (Number.isFinite(n) && n >= 1) return Math.floor(n);
	// Fallback: position on a 5-column page, key (0,0) being Back.
	return k.row * 5 + k.column;
}

// ---- favourites -----------------------------------------------------------------------------
type Fav = { package: string; displayName: string; localIconPath: string };
const favCache = new Map<number, { at: number; items: Fav[] }>();
const iconCache = new Map<string, string | null>();
const favLoading = new Set<number>();

async function loadFavorites(id: number, name: string): Promise<void> {
	if (favLoading.has(id)) return;
	const c = favCache.get(id);
	if (c && Date.now() - c.at < 30000) return;
	favLoading.add(id);
	try {
		const r = await get<Fav[]>(`/api/favoriteapps?name=${encodeURIComponent(displayName(name))}`);
		if (Array.isArray(r.data)) {
			favCache.set(id, { at: Date.now(), items: r.data });
			await Promise.all(
				r.data.map(async (f) => {
					if (f.localIconPath && !iconCache.has(f.localIconPath)) iconCache.set(f.localIconPath, await fetchDataUri(f.localIconPath));
				}),
			);
			store.emit("change");
		}
	} finally {
		favLoading.delete(id);
	}
}

@action({ UUID: "com.lyonesport.vrhm.app" })
export class AppSlotAction extends VrhmAction<SlotSettings> {
	protected override appeared(): void {
		const h = store.headsetById(store.selectedId);
		if (h) void loadFavorites(h.ID, h.Name);
	}

	protected draw(k: KeyCtx<SlotSettings>): Promise<void> {
		const h = store.headsetById(store.selectedId);
		if (!h) return this.paint(k, face({ bg: C.server }));
		const items = favCache.get(h.ID)?.items;
		if (!items) {
			void loadFavorites(h.ID, h.Name);
			return this.paint(k, face({ bg: C.server, main: "...", mainColor: C.dim }));
		}
		const f = items[slotIndex(k) - 1];
		if (!f) return this.paint(k, face({ bg: C.server }));
		const running = store.status.get(h.ID)?.running_app === f.package;
		const icon = f.localIconPath ? iconCache.get(f.localIconPath) ?? undefined : undefined;
		return this.paint(
			k,
			face({ bg: running ? C.live : "#000000", image: icon, top: icon ? undefined : f.displayName, bottom: f.displayName, border: running ? C.ok : undefined }),
		);
	}

	protected async press(k: KeyCtx<SlotSettings>): Promise<void> {
		const h = store.headsetById(store.selectedId);
		const f = h ? favCache.get(h.ID)?.items[slotIndex(k) - 1] : undefined;
		if (!h || !f) return k.action.showAlert();
		const r = await post("/api/launchapp", { name: displayName(h.Name), package: f.package }, 30000);
		if (!r.ok) return k.action.showAlert();
		await k.action.showOk();
		store.refreshSoon(1500);
		await switchTo(k.action, PROFILES.headset);
	}
}

// ---- kiosks ---------------------------------------------------------------------------------
type Kiosk = { ID: string; Name: string; IPAddress: string; Reachable?: boolean; CdpOpen?: boolean; CurrentUrl?: string };
let kiosks: Kiosk[] | null = null;
let kiosksAt = 0;
let kiosksLoading = false;

async function loadKiosks(force = false): Promise<void> {
	if (kiosksLoading || (!force && kiosks && Date.now() - kiosksAt < 5000)) return;
	kiosksLoading = true;
	try {
		const r = await get<{ ok: boolean; kiosks: Kiosk[] }>("/api/kiosks");
		if (r.data && Array.isArray(r.data.kiosks)) {
			kiosks = r.data.kiosks;
			kiosksAt = Date.now();
			store.emit("change");
		}
	} finally {
		kiosksLoading = false;
	}
}

@action({ UUID: "com.lyonesport.vrhm.kiosk" })
export class KioskSlotAction extends VrhmAction<SlotSettings> {
	protected override appeared(): void {
		void loadKiosks(true);
	}

	protected draw(k: KeyCtx<SlotSettings>): Promise<void> {
		if (!kiosks) {
			void loadKiosks();
			return this.paint(k, face({ bg: C.server, main: "...", mainColor: C.dim }));
		}
		void loadKiosks();
		const kk = kiosks[slotIndex(k) - 1];
		if (!kk) return this.paint(k, face({ bg: C.server }));
		const h = store.headsetById(store.selectedId);
		const up = !!kk.CdpOpen || !!kk.Reachable;
		const showing = !!(h && kk.CurrentUrl && decodeURIComponent(kk.CurrentUrl).includes(`/${displayName(h.Name)}[video].html`));
		return this.paint(
			k,
			face({
				bg: up ? (showing ? C.live : C.online) : C.offline,
				top: kk.Name,
				main: showing ? "SHOWING" : up ? "CAST" : "OFF",
				bottom: h ? h.Name : "",
			}),
		);
	}

	protected async press(k: KeyCtx<SlotSettings>): Promise<void> {
		const h = store.headsetById(store.selectedId);
		const kk = kiosks?.[slotIndex(k) - 1];
		if (!h || !kk) return k.action.showAlert();
		// Same URL as kiosk_screens.html castUrlForHeadset(): the headset's own video page.
		const url = `${getServerUrl()}/${displayName(h.Name)}[video].html?nooverlay=1`;
		let r = await post("/api/kiosks/push", { id: Number(kk.ID), url }, 20000);
		if (!r.ok && r.data?.needsConfirmation && r.data?.suggestedUrl) {
			// localhost is not reachable from the kiosk: use the LAN address the server proposes.
			r = await post("/api/kiosks/push", { id: Number(kk.ID), url: r.data.suggestedUrl, confirmLocalhostReplacement: true }, 20000);
		}
		if (!r.ok) {
			streamDeck.logger.warn(`kiosk push failed: ${r.error}`);
			return k.action.showAlert();
		}
		await k.action.showOk();
		void loadKiosks(true);
	}
}
