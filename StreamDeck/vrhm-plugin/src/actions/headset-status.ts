// Row 1 of the main page: one headset per column. Colour = state (offline / no ADB / ready /
// live / starting), red frame + dot = recording, bottom line = battery. Press = select this
// headset and open its config page.

import { action } from "@elgato/streamdeck";
import { fetchDataUri, get } from "../api";
import { KeyCtx, PROFILES, VrhmAction, switchTo } from "../common";
import { C, batteryText, face, headsetLook } from "../render";
import { type HeadsetStatus, store } from "../store";

// Icon of the running app, fetched once per path and inlined (null = no icon / failed).
const icons = new Map<string, string | null>();
const loading = new Set<string>();

function appIcon(path: string | undefined): string | undefined {
	if (!path || path === "-") return undefined;
	if (icons.has(path)) return icons.get(path) ?? undefined;
	if (!loading.has(path)) {
		loading.add(path);
		void fetchDataUri(path).then((uri) => {
			icons.set(path, uri);
			loading.delete(path);
			if (uri) store.emit("change");
		});
	}
	return undefined;
}

type Settings = { target?: string; onPress?: "config" | "none" };

/**
 * Headset on battery: reachable, battery known, not charging and no power source reported
 * (companion "plugged" field, when fresh). Its key blinks orange and shows the battery in red.
 */
function onBattery(st: HeadsetStatus | undefined): boolean {
	if (!st || !(st.ping || st.adb)) return false;
	if (!batteryText(st)) return false;
	if (st.charging) return false;
	const p = String(st.plugged ?? "").toLowerCase();
	return !p || p === "none";
}

const BLINK_MS = 400;

// Battery "low" level of the VRHM config (Monitoring.thresholds.headset_battery_warningLevel),
// re-read every minute. Fallback = config_files_loader.ps1 default.
let lowLevel = 40;
let lowLevelAt = 0;
function refreshLowLevel(): void {
	if (Date.now() - lowLevelAt < 60000) return;
	lowLevelAt = Date.now();
	void get<any>("/api/config").then((r) => {
		const n = Number(r.data?.Monitoring?.thresholds?.headset_battery_warningLevel);
		if (Number.isFinite(n) && n > 0) lowLevel = n;
	});
}

function batteryPct(st: HeadsetStatus | undefined): number | undefined {
	const n = parseInt(String(st?.battery ?? ""), 10);
	return Number.isFinite(n) ? n : undefined;
}

@action({ UUID: "com.lyonesport.vrhm.headset" })
export class HeadsetStatusAction extends VrhmAction<Settings> {
	private blinkOn = false;
	private blinkTimer: NodeJS.Timeout | undefined;

	protected override appeared(): void {
		if (this.blinkTimer) return;
		// One timer for every status key; redraws only while a headset is on battery
		// (paint() skips keys whose image did not change).
		this.blinkTimer = setInterval(() => {
			this.blinkOn = !this.blinkOn;
			for (const st of store.status.values()) {
				if (onBattery(st)) {
					this.redrawAll();
					return;
				}
			}
		}, BLINK_MS);
	}

	protected override allowSelectedTarget(): boolean {
		return true;
	}

	protected draw(k: KeyCtx<Settings>): Promise<void> {
		if (!store.serverOnline) return this.paint(k, face({ bg: C.server, top: "VRHM", main: "OFFLINE", mainColor: C.dim }));
		const h = store.resolveTarget(k.settings.target, this.fallbackSlot(k));
		if (!h) return this.paint(k, face({ bg: C.server, main: "-", mainColor: C.dim }));
		const st = store.status.get(h.ID);
		const look = headsetLook(st);
		const rec = !!st?.record;
		refreshLowLevel();
		const unplugged = onBattery(st);
		// On battery: border AND battery level blink together; border red under the low level.
		const pct = batteryPct(st);
		const low = pct !== undefined && pct < lowLevel;
		const border = unplugged && this.blinkOn ? (low ? C.rec : C.unplugged) : rec ? C.rec : undefined;
		const battery = unplugged && !this.blinkOn ? "" : batteryText(st);
		// Live: show the running game's icon instead of "LIVE" when the server has one.
		const icon = st?.scrcpy && !st.scrcpy_starting ? appIcon(st.running_app_icon) : undefined;
		return this.paint(
			k,
			face({
				bg: look.bg,
				top: h.Name,
				main: icon ? undefined : look.label,
				image: icon,
				imageInset: true,
				bottom: battery,
				border,
				bottomColor: unplugged ? C.lowText : undefined,
				bottomBold: unplugged,
				dot: rec ? C.rec : undefined,
			}),
		);
	}

	protected async press(k: KeyCtx<Settings>): Promise<void> {
		const h = store.resolveTarget(k.settings.target, this.fallbackSlot(k));
		if (!h) {
			await k.action.showAlert();
			return;
		}
		store.selectedId = h.ID;
		store.emit("change");
		if ((k.settings.onPress ?? "config") === "config") {
			await switchTo(k.action, PROFILES.headset);
		}
		// Volume / brightness read in the background (ADB, a few seconds).
		void store.loadLevels(h);
	}
}
