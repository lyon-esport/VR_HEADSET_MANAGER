// Row 3 of the main page: the timer of one headset (same backend as timer_control.html,
// GET /api/timer?id=&action=). Short press = start / pause / resume; hold = stop + reset.

import { action } from "@elgato/streamdeck";
import { get } from "../api";
import { KeyCtx, VrhmAction } from "../common";
import { C, face } from "../render";
import { store, type TimerStatus } from "../store";

type Settings = { target?: string };

@action({ UUID: "com.lyonesport.vrhm.timer" })
export class TimerAction extends VrhmAction<Settings> {
	// Blink of an expired countdown: the key alternates red / white every BLINK_MS. The interval
	// only runs while at least one watched timer is expired.
	private blinkTimer: NodeJS.Timeout | undefined;
	private blinkOn = false;

	constructor() {
		super();
		store.on("timers", () => {
			this.syncBlink();
			this.redrawAll();
		});
	}

	private syncBlink(): void {
		const anyExpired = [...store.timers.values()].some(isExpired);
		if (anyExpired && !this.blinkTimer) {
			this.blinkTimer = setInterval(() => {
				this.blinkOn = !this.blinkOn;
				this.redrawAll();
			}, BLINK_MS);
		} else if (!anyExpired && this.blinkTimer) {
			clearInterval(this.blinkTimer);
			this.blinkTimer = undefined;
			this.blinkOn = false;
		}
	}

	protected override allowSelectedTarget(): boolean {
		return true;
	}

	private headsetId(k: KeyCtx<Settings>): number {
		return store.resolveTarget(k.settings.target, this.fallbackSlot(k))?.ID ?? 0;
	}

	protected override appeared(k: KeyCtx<Settings>): void {
		store.watchTimer(k.action.id, this.headsetId(k));
	}
	protected override disappeared(id: string): void {
		store.unwatchTimer(id);
	}

	protected override hasLongPress(): boolean {
		return true;
	}

	protected draw(k: KeyCtx<Settings>): Promise<void> {
		if (!store.serverOnline) return this.paint(k, face({ bg: C.server, top: "TIMER", main: "OFFLINE", mainColor: C.dim }));
		const h = store.resolveTarget(k.settings.target, this.fallbackSlot(k));
		if (!h) return this.paint(k, face({ bg: C.server, main: "-", mainColor: C.dim }));
		// Slot -> id can change when the registry order changes.
		store.watchTimer(k.action.id, h.ID);
		const t = store.timers.get(h.ID);
		const configured = t ? `${pad(t.minutes)}:${pad(t.seconds)}` : "--:--";
		if (t && isExpired(t)) {
			return this.paint(
				k,
				this.blinkOn
					? face({ bg: "#ffffff", top: h.Name, main: "TIME UP", bottom: "press: restart", mainColor: C.rec, textColor: C.rec })
					: face({ bg: C.rec, top: h.Name, main: "TIME UP", bottom: "press: restart" }),
			);
		}
		// Paused: the server reports active=false + paused=true and keeps the frozen value.
		if (t && t.paused) return this.paint(k, face({ bg: C.warn, top: h.Name, main: t.value || configured, bottom: "paused" }));
		if (!t || !t.active) {
			return this.paint(k, face({ bg: C.idle, top: h.Name, main: configured, bottom: "start", mainColor: C.dim }));
		}
		const value = t.value || configured;
		return this.paint(k, face({ bg: C.ok, top: h.Name, main: value, bottom: t.mode === "inc" ? "counting" : "running" }));
	}

	protected async press(k: KeyCtx<Settings>): Promise<void> {
		const id = this.headsetId(k);
		if (!id) return k.action.showAlert();
		const t = store.timers.get(id);
		const act = t && t.paused ? "resume" : !t || !t.active ? "start" : "pause";
		const r = await get(`/api/timer?id=${id}&action=${act}`);
		await store.refreshTimer(id);
		if (!r.ok) await k.action.showAlert();
	}

	protected override async longPress(k: KeyCtx<Settings>): Promise<void> {
		const id = this.headsetId(k);
		if (!id) return k.action.showAlert();
		const r = await get(`/api/timer?id=${id}&action=reset`);
		await store.refreshTimer(id);
		if (r.ok) await k.action.showOk();
		else await k.action.showAlert();
	}
}

const BLINK_MS = 500;

/** A countdown that reached zero: the timer job writes "Time's up !" as its last value. */
function isExpired(t: TimerStatus): boolean {
	return t.mode !== "inc" && /time.?s up/i.test(t.value);
}

function pad(n: number | undefined): string {
	const v = Number.isFinite(Number(n)) ? Number(n) : 0;
	return String(v).padStart(2, "0");
}

