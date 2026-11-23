// One action for every headset command. The `command` setting picks what the key does; the
// `target` setting picks the headset ("selected" = the one opened from the main page, or a
// slot / fixed headset). Row 2 of the main page uses it with record / capture / snapshot.

import streamDeck, { action } from "@elgato/streamdeck";
import { displayName, post } from "../api";
import { KeyCtx, PROFILES, VrhmAction, flashTitle, switchTo } from "../common";
import { C, ICONS, KeyFace, batteryText, face, headsetLook } from "../render";
import { type Headset, store } from "../store";

export type Command =
	| "home"
	| "headsetpage"
	| "info"
	| "record"
	| "capture"
	| "snapshot"
	| "resetui"
	| "volup"
	| "voldown"
	| "brightup"
	| "brightdown"
	| "apps"
	| "kiosks"
	| "closeapp"
	| "eye"
	| "settings"
	| "size"
	| "reboot"
	| "shutdown";

type Settings = { command?: Command; target?: string; step?: number };

const HOLD_COMMANDS: Command[] = ["reboot", "shutdown"];

@action({ UUID: "com.lyonesport.vrhm.command" })
export class CommandAction extends VrhmAction<Settings> {
	private cmd(k: KeyCtx<Settings>): Command {
		return (k.settings.command ?? "record") as Command;
	}

	private target(k: KeyCtx<Settings>): Headset | undefined {
		const t = k.settings.target && k.settings.target !== "" ? k.settings.target : "selected";
		return store.resolveTarget(t, this.fallbackSlot(k));
	}

	protected override defaultTargetLabel(): string {
		return "Default: selected headset";
	}

	protected override hasLongPress(k: KeyCtx<Settings>): boolean {
		// record: press = snapshot, hold = recording on / off
		return HOLD_COMMANDS.includes(this.cmd(k)) || this.cmd(k) === "record";
	}

	protected override appeared(k: KeyCtx<Settings>): void {
		const c = this.cmd(k);
		if (["volup", "voldown", "brightup", "brightdown"].includes(c)) {
			const h = this.target(k);
			if (h) void store.loadLevels(h);
		}
	}

	// ---- drawing --------------------------------------------------------------------------
	protected draw(k: KeyCtx<Settings>): Promise<void> {
		const c = this.cmd(k);
		const busy = store.busy.has(k.action.id);
		if (c === "home") return this.paint(k, face({ bg: C.idle, icon: ICONS.home, main: "HOME" }));
		if (c === "headsetpage") return this.paint(k, face({ bg: C.idle, icon: ICONS.back, main: "BACK" }));

		if (!store.serverOnline) return this.paint(k, face({ bg: C.server, top: "VRHM", main: "OFFLINE", mainColor: C.dim }));
		const h = this.target(k);
		if (!h) return this.paint(k, face({ bg: C.server, main: "NO HEADSET", mainColor: C.dim }));
		const st = store.status.get(h.ID);
		const lv = store.levels.get(h.ID);
		const name = h.Name;
		const step = this.step(k);
		let f: KeyFace;
		switch (c) {
			case "info": {
				const look = headsetLook(st);
				f = { bg: look.bg, top: name, main: look.label, bottom: batteryText(st), border: st?.record ? C.rec : undefined, dot: st?.record ? C.rec : undefined };
				break;
			}
			case "record":
				f = st?.record
					? { bg: C.rec, top: name, icon: ICONS.camera, main: "REC ON", bottom: "hold: rec off" }
					: { bg: C.idle, top: name, icon: ICONS.camera, main: "REC OFF", mainColor: C.dim, bottom: "hold: rec on" };
				break;
			case "capture": {
				const live = !!st?.scrcpy || !!st?.scrcpy_starting;
				f = live
					? { bg: st?.scrcpy_starting ? C.starting : C.live, top: name, icon: ICONS.stop, main: st?.scrcpy_starting ? "STARTING" : "STOP CAST" }
					: { bg: C.idle, top: name, icon: ICONS.play, main: "START CAST" };
				break;
			}
			case "snapshot":
				f = { bg: C.idle, top: name, icon: ICONS.camera, main: "SNAPSHOT" };
				break;
			case "resetui":
				f = { bg: C.idle, top: name, icon: ICONS.ui, main: "RESET UI" };
				break;
			case "volup":
				f = { bg: C.idle, top: lvl("Vol", lv?.soundLevel), icon: ICONS.volUp, main: `VOL +${step}` };
				break;
			case "voldown":
				f = { bg: C.idle, top: lvl("Vol", lv?.soundLevel), icon: ICONS.volDown, main: `VOL -${step}` };
				break;
			case "brightup":
				f = { bg: C.idle, top: lvl("Light", lv?.brightness), icon: ICONS.sun, main: `LIGHT +${step}` };
				break;
			case "brightdown":
				f = { bg: C.idle, top: lvl("Light", lv?.brightness), icon: ICONS.sunDim, main: `LIGHT -${step}` };
				break;
			case "apps":
				f = { bg: C.idle, top: name, icon: ICONS.grid, main: "APPS" };
				break;
			case "kiosks":
				f = { bg: C.idle, top: name, icon: ICONS.monitor, main: "TO KIOSK" };
				break;
			case "closeapp": {
				const app = shortApp(st?.running_app);
				f = { bg: app ? C.danger : C.idle, top: app || "no app", icon: ICONS.x, main: "CLOSE APP", mainColor: app ? C.text : C.dim };
				break;
			}
			case "eye": // former eye key: an older installed headset page holds it at the same place
			case "settings":
				f = { bg: C.idle, top: name, icon: ICONS.gear, main: "SETTINGS" };
				break;
			case "size": {
				const p = parseProfile(h.ScrcpyProfile);
				const eye = p ? ({ L: "left eye", R: "right eye", M: "merged" } as Record<string, string>)[p.eye] ?? "eye " + p.eye : undefined;
				f = { bg: C.idle, top: "CAPTURE PROFILE", icon: ICONS.maximize, main: p ? p.view.toUpperCase() : "PROFILE", bottom: eye };
				break;
			}
			case "reboot":
				f = { bg: C.warn, top: name, icon: ICONS.reboot, main: "REBOOT", bottom: "hold" };
				break;
			case "shutdown":
				f = { bg: C.danger, top: name, icon: ICONS.power, main: "SHUTDOWN", bottom: "hold" };
				break;
			default:
				f = { bg: C.idle, main: String(c) };
		}
		if (busy) f = { ...f, bottom: "..." };
		return this.paint(k, face(f));
	}

	private step(k: KeyCtx<Settings>): number {
		const s = Number(k.settings.step);
		return Number.isFinite(s) && s > 0 && s <= 100 ? Math.round(s) : 10;
	}

	// ---- presses --------------------------------------------------------------------------
	protected async press(k: KeyCtx<Settings>): Promise<void> {
		const c = this.cmd(k);
		if (c === "home") return switchTo(k.action, PROFILES.main);
		if (c === "headsetpage") return switchTo(k.action, PROFILES.headset);
		if (HOLD_COMMANDS.includes(c)) {
			flashTitle(k.action, "HOLD");
			await k.action.showAlert();
			return;
		}
		const h = this.target(k);
		if (h && c === "record") {
			// short press = one picture of the stream; the hold toggles recording (longPress)
			await this.busyRun(k, () => this.execute(k, "snapshot", h));
			return;
		}
		if (!h) {
			await k.action.showAlert();
			return;
		}
		if (c === "apps") {
			store.selectedId = h.ID;
			return switchTo(k.action, PROFILES.apps);
		}
		if (c === "kiosks") {
			store.selectedId = h.ID;
			return switchTo(k.action, PROFILES.kiosks);
		}
		if (c === "eye" || c === "settings") {
			store.selectedId = h.ID;
			return switchTo(k.action, PROFILES.settings);
		}
		if (c === "size") {
			store.selectedId = h.ID;
			return switchTo(k.action, PROFILES.views);
		}
		if (c === "info") {
			await store.loadLevels(h, true);
			store.refreshSoon(0);
			await k.action.showOk();
			return;
		}
		await this.busyRun(k, () => this.execute(k, c, h));
	}

	protected override async longPress(k: KeyCtx<Settings>): Promise<void> {
		const c = this.cmd(k);
		const h = this.target(k);
		if (!h) {
			await k.action.showAlert();
			return;
		}
		await this.busyRun(k, () => this.execute(k, c, h));
	}

	private async busyRun(k: KeyCtx<Settings>, fn: () => Promise<boolean>): Promise<void> {
		if (store.busy.has(k.action.id)) return;
		store.busy.add(k.action.id);
		void this.safeDraw(k);
		let ok = false;
		try {
			ok = await fn();
		} finally {
			store.busy.delete(k.action.id);
			void this.safeDraw(k);
		}
		if (ok) await k.action.showOk();
		else await k.action.showAlert();
		store.refreshSoon();
	}

	private async execute(k: KeyCtx<Settings>, c: Command, h: Headset): Promise<boolean> {
		const name = displayName(h.Name);
		const st = store.status.get(h.ID);
		switch (c) {
			case "record": {
				const r = await post("/api/recording", { name, value: !st?.record }, 30000);
				if (!r.ok && r.data?.storageLow) flashTitle(k.action, "DISK FULL", 2500);
				return r.ok;
			}
			case "capture": {
				const live = !!st?.scrcpy || !!st?.scrcpy_starting;
				if (live) {
					// Auto-restart OFF first, else the monitor starts it again at once.
					const a = await post("/api/autorestart", { name, value: false });
					const s = await post("/api/stop-scrcpy", { name }, 20000);
					return a.ok && s.ok;
				}
				// Auto-restart ON = the monitor starts the capture now (Request-ScrcpyCheck).
				return (await post("/api/autorestart", { name, value: true })).ok;
			}
			case "snapshot": {
				const r = await post("/api/headset-snapshot", { id: h.ID }, 30000);
				if (!r.ok) streamDeck.logger.warn(`snapshot failed: ${r.error}`);
				return r.ok;
			}
			case "resetui":
				return (await post("/api/headset-diag/action", { id: h.ID, action: "recover_reset_ui" }, 30000)).ok;
			case "volup":
			case "voldown":
			case "brightup":
			case "brightdown": {
				const isVol = c === "volup" || c === "voldown";
				const lv = (await store.loadLevels(h)) ?? { at: 0 };
				const cur = (isVol ? lv.soundLevel : lv.brightness) ?? 50;
				const sign = c === "volup" || c === "brightup" ? 1 : -1;
				const next = Math.max(0, Math.min(100, cur + sign * this.step(k)));
				const settings = isVol ? { soundLevel: next } : { brightness: next };
				const r = await post("/api/headset-settings/apply", { name, settings }, 30000);
				if (r.ok) {
					const now = store.levels.get(h.ID) ?? { at: Date.now() };
					if (isVol) now.soundLevel = next;
					else now.brightness = next;
					store.levels.set(h.ID, now);
					store.emit("change");
				}
				return r.ok;
			}
			case "closeapp": {
				const pkg = st?.running_app;
				if (!pkg || isShell(pkg)) return false;
				return (await post("/api/stopapp", { name, package: pkg }, 20000)).ok;
			}
			case "reboot":
				return (await post("/api/reboot", { name }, 30000)).ok;
			case "shutdown":
				return (await post("/api/shutdown", { name }, 30000)).ok;
		}
		return false;
	}
}

function lvl(label: string, v: number | undefined): string {
	return v === undefined ? label : `${label} ${v}%`;
}

const SHELL = ["com.oculus.vrshell", "com.oculus.systemux", "com.oculus.shellenv", "meta.systemui"];
function isShell(pkg: string): boolean {
	return SHELL.includes(pkg) || pkg.startsWith("com.oculus.vrshell");
}

function shortApp(pkg: string | undefined): string {
	if (!pkg || pkg === "-" || isShell(pkg)) return "";
	const parts = pkg.split(".");
	return parts[parts.length - 1];
}

export function parseProfile(p: string | undefined): { view: string; eye: string; audio: string; fps: string; bw: string } | null {
	if (!p) return null;
	let parts = p.split("-");
	if (parts.length === 4 && /^[LRM]$/.test(parts[0])) parts = ["portrait", ...parts];
	if (parts.length !== 5) return null;
	return { view: parts[0], eye: parts[1], audio: parts[2], fps: parts[3], bw: parts[4] };
}
