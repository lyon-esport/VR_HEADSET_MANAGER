// Settings page, opened by the gear key of the headset page. Acts on the selected headset.
// Every key is one setting of the web "Configure" modal (GET /api/headset-settings, applied
// through POST /api/headset-settings/apply, keep awake through /api/headset-keep-awake).
// Most of them are session-only on the headset; the server remembers them for the re-apply
// after a reboot (ADR-0040). A value the headset cannot report (e.g. on a Pico) shows "n/a".

import streamDeck, { action } from "@elgato/streamdeck";
import { displayName, post } from "../api";
import { KeyCtx, VrhmAction } from "../common";
import { C, ICONS, face } from "../render";
import { type Headset, store } from "../store";

type SettingKey =
	| "guardian"
	| "guardianSetup"
	| "doubleTap"
	| "wideMotion"
	| "keepAwake"
	| "sharpening"
	| "refreshRate"
	| "updates"
	| "reapply"
	| "reload";

type Settings = { key?: SettingKey };

type Def = {
	label: string;
	icon: string;
	/** Current value from the GET answer; null/undefined = unknown. */
	value?: (raw: any) => boolean | string | number | null | undefined;
	/** Text shown for a value. */
	text?: (v: any) => string;
	/** ON look (green) for a value. */
	on?: (v: any) => boolean;
	/** Next value on press. */
	next?: (v: any, raw: any) => any;
	/** Sends the new value; returns ok. */
	apply?: (h: Headset, v: any) => Promise<boolean>;
	/** Raw field to update locally after a successful apply. */
	field?: string;
};

const onOff = (v: any) => (v ? "ON" : "OFF");
const applySetting = (name: string) => async (h: Headset, v: any) =>
	(await post("/api/headset-settings/apply", { name: displayName(h.Name), settings: { [name]: v } }, 30000)).ok;
const asList = (v: any): any[] => (Array.isArray(v) ? v : v === null || v === undefined || v === "" ? [] : [v]);

const SHARP = ["none", "fcas", "mqsr"];
const SHARP_TEXT: Record<string, string> = { none: "OFF", fcas: "CAS", mqsr: "MQSR", custom: "CUSTOM" };

const DEFS: Record<SettingKey, Def> = {
	// Guardian ON = boundary active (not paused).
	guardian: {
		label: "GUARDIAN",
		icon: ICONS.shield,
		value: (r) => (r?.guardianPaused === null || r?.guardianPaused === undefined ? null : !r.guardianPaused),
		text: onOff,
		on: (v) => !!v,
		next: (v) => !v,
		apply: (h, v) => applySetting("guardianPause")(h, !v),
		field: "guardianPaused:not",
	},
	guardianSetup: {
		label: "GUARDIAN",
		icon: ICONS.shield,
		text: () => "SETUP",
		apply: applySetting("guardianMode"),
	},
	// Double tap ON = side double tap toggles passthrough (not disabled).
	doubleTap: {
		label: "DOUBLE TAP",
		icon: ICONS.tap,
		value: (r) => (r?.doubleTapDisabled === null || r?.doubleTapDisabled === undefined ? null : !r.doubleTapDisabled),
		text: onOff,
		on: (v) => !!v,
		next: (v) => !v,
		apply: (h, v) => applySetting("doubleTapDisabled")(h, !v),
		field: "doubleTapDisabled:not",
	},
	wideMotion: {
		label: "WIDE HANDS",
		icon: ICONS.hand,
		value: (r) => r?.wideMotion,
		text: onOff,
		on: (v) => !!v,
		next: (v) => !v,
		apply: applySetting("wideMotion"),
		field: "wideMotion",
	},
	keepAwake: {
		label: "KEEP AWAKE",
		icon: ICONS.coffee,
		value: (r) => r?.keepAwake,
		text: onOff,
		on: (v) => !!v,
		next: (v) => !v,
		apply: async (h, v) => (await post("/api/headset-keep-awake", { id: h.ID, enabled: !!v }, 30000)).ok,
		field: "keepAwake",
	},
	sharpening: {
		label: "SHARPENING",
		icon: ICONS.sharp,
		value: (r) => r?.sharpening,
		text: (v) => SHARP_TEXT[String(v)] ?? String(v).toUpperCase(),
		on: (v) => v === "fcas" || v === "mqsr",
		next: (v) => SHARP[(SHARP.indexOf(String(v)) + 1) % SHARP.length],
		apply: applySetting("sharpening"),
		field: "sharpening",
	},
	refreshRate: {
		label: "REFRESH",
		icon: ICONS.hz,
		value: (r) => r?.refreshRate,
		text: (v) => `${v} Hz`,
		on: () => false,
		next: (v, raw) => {
			const list = asList(raw?.refreshRates).map(Number).filter((n) => Number.isFinite(n));
			if (!list.length) return undefined;
			const i = list.indexOf(Number(v));
			return list[(i + 1) % list.length];
		},
		apply: applySetting("refreshRate"),
		field: "refreshRate",
	},
	// Updates ON = OTA updates allowed (not blocked).
	updates: {
		label: "OTA UPDATES",
		icon: ICONS.lock,
		value: (r) => (r?.blockUpdates === null || r?.blockUpdates === undefined ? null : !r.blockUpdates),
		text: onOff,
		on: (v) => !!v,
		next: (v) => !v,
		apply: (h, v) => applySetting("blockUpdates")(h, !v),
		field: "blockUpdates:not",
	},
	reapply: {
		label: "AFTER REBOOT",
		icon: ICONS.reboot,
		value: (r) => r?.sessionReapply,
		text: (v) => (v ? "RE-APPLY" : "FORGET"),
		on: (v) => !!v,
		next: (v) => !v,
		apply: applySetting("sessionReapply"),
		field: "sessionReapply",
	},
	reload: {
		label: "SETTINGS",
		icon: ICONS.refresh,
		text: () => "RELOAD",
	},
};

@action({ UUID: "com.lyonesport.vrhm.setting" })
export class SettingAction extends VrhmAction<Settings> {
	private lastForced = 0;

	private headset(): Headset | undefined {
		return store.headsetById(store.selectedId);
	}

	private key(k: KeyCtx<Settings>): SettingKey {
		const v = k.settings.key;
		return v && v in DEFS ? v : "reload";
	}

	protected override appeared(): void {
		// Entering the page: read the headset's settings once (ADB, a few seconds).
		const h = this.headset();
		if (h && Date.now() - this.lastForced > 5000) {
			this.lastForced = Date.now();
			void store.loadLevels(h, true);
		}
	}

	protected draw(k: KeyCtx<Settings>): Promise<void> {
		const h = this.headset();
		if (!h) return this.paint(k, face({ bg: C.server }));
		const d = DEFS[this.key(k)];
		const busy = store.busy.has(k.action.id);
		if (!d.value) {
			return this.paint(k, face({ bg: C.idle, top: d.label, icon: d.icon, main: d.text ? d.text(undefined) : "", bottom: busy ? "..." : undefined }));
		}
		const raw = store.levels.get(h.ID)?.raw;
		if (!raw) return this.paint(k, face({ bg: C.idle, top: d.label, icon: d.icon, main: "...", mainColor: C.dim }));
		const v = d.value(raw);
		if (v === null || v === undefined || v === "") {
			return this.paint(k, face({ bg: C.server, top: d.label, icon: d.icon, main: "n/a", mainColor: C.dim, textColor: C.dim }));
		}
		const on = d.on ? d.on(v) : false;
		return this.paint(k, face({ bg: on ? C.online : C.idle, top: d.label, icon: d.icon, main: d.text ? d.text(v) : String(v), bottom: busy ? "..." : undefined }));
	}

	protected async press(k: KeyCtx<Settings>): Promise<void> {
		const h = this.headset();
		if (!h || store.busy.has(k.action.id)) return k.action.showAlert();
		const key = this.key(k);
		const d = DEFS[key];
		if (key === "reload") {
			store.busy.add(k.action.id);
			void this.safeDraw(k);
			try {
				await store.loadLevels(h, true);
			} finally {
				store.busy.delete(k.action.id);
				store.emit("change");
			}
			return;
		}
		if (!d.apply) return;
		const lv = store.levels.get(h.ID);
		const raw = lv?.raw;
		let next: any = true;
		if (d.value) {
			const cur = raw ? d.value(raw) : undefined;
			if (cur === null || cur === undefined || cur === "") return k.action.showAlert();
			next = d.next ? d.next(cur, raw) : undefined;
			if (next === undefined) return k.action.showAlert();
		}
		store.busy.add(k.action.id);
		void this.safeDraw(k);
		let ok = false;
		try {
			ok = await d.apply(h, next);
			if (ok && raw && d.field) {
				const [f, mod] = d.field.split(":");
				raw[f] = mod === "not" ? !next : next;
			}
			if (!ok) streamDeck.logger.warn(`setting ${key} failed for ${h.Name}`);
		} finally {
			store.busy.delete(k.action.id);
		}
		store.emit("change");
		// No tick on success: the key itself shows the new value. One-shot actions get one.
		if (!ok) await k.action.showAlert();
		else if (!d.value) await k.action.showOk();
	}
}
