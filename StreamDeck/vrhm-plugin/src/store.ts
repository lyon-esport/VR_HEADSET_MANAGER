// Shared state of the plugin: ONE poller for the whole deck (not one per key).
//   /api/headsets         every 10 s (registry: id, name, model, profile; display order)
//   /api/headsets-status  every 1.5 s (live status)
//   /api/timer status     every 1 s, only for headsets that have a visible timer key
// Keys subscribe with onChange() and redraw from the store.

import { EventEmitter } from "node:events";
import { displayName, get } from "./api";

export type Headset = {
	ID: number;
	Name: string;
	Model: string;
	Brand?: string;
	ScrcpyProfile: string;
	scrcpy_AutoRestart: string;
	Record: string;
};

export type HeadsetStatus = {
	id: number;
	name: string;
	display_name: string;
	ping: boolean;
	adb: boolean;
	adb_transport?: string;
	scrcpy: boolean;
	scrcpy_starting?: boolean;
	record: boolean;
	scrcpy_auto_restart: boolean;
	battery: string;
	charging?: boolean;
	plugged?: string | null;
	running_app?: string;
	running_app_icon?: string;
	capture_black?: boolean;
};

export type TimerStatus = { active: boolean; paused: boolean; value: string; minutes: number; seconds: number; mode: string };

/** Values read from /api/headset-settings (slow, ADB), cached per headset id. */
export type HeadsetLevels = { soundLevel?: number; brightness?: number; at: number; raw?: any };

class Store extends EventEmitter {
	serverOnline = false;
	headsets: Headset[] = [];
	status = new Map<number, HeadsetStatus>();
	timers = new Map<number, TimerStatus>();
	levels = new Map<number, HeadsetLevels>();
	/** Headset the config pages act on (set by a status key press). */
	selectedId = 0;
	/** Busy flags so a key shows "..." while its request runs. */
	busy = new Set<string>();

	private timerIds = new Map<string, number>(); // action context -> headset id
	private started = false;
	private lastHeadsetsAt = 0;
	private statusTimer: NodeJS.Timeout | undefined;
	private timerTimer: NodeJS.Timeout | undefined;

	start(): void {
		if (this.started) return;
		this.started = true;
		void this.pollStatus();
		void this.pollTimers();
	}

	/** Forces an immediate refresh (after an action changed something). */
	refreshSoon(delayMs = 300): void {
		setTimeout(() => {
			this.lastHeadsetsAt = 0;
			void this.pollStatus(true);
		}, delayMs);
	}

	private async pollStatus(once = false): Promise<void> {
		if (!once && this.statusTimer) clearTimeout(this.statusTimer);
		let delay = 1500;
		try {
			if (Date.now() - this.lastHeadsetsAt > 10000 || this.headsets.length === 0) {
				const r = await get<Headset[]>("/api/headsets", 5000);
				if (r.ok && Array.isArray(r.data)) {
					this.headsets = r.data.map((h) => ({ ...h, ID: Number(h.ID) }));
					this.lastHeadsetsAt = Date.now();
				}
			}
			const s = await get<HeadsetStatus[]>("/api/headsets-status", 5000);
			if (s.ok && Array.isArray(s.data)) {
				this.status.clear();
				for (const h of s.data) this.status.set(Number(h.id), h);
				this.serverOnline = true;
			} else {
				this.serverOnline = false;
				delay = 3000;
			}
		} catch {
			this.serverOnline = false;
			delay = 3000;
		}
		this.emit("change");
		if (!once) this.statusTimer = setTimeout(() => void this.pollStatus(), delay);
	}

	private async pollTimers(): Promise<void> {
		if (this.timerTimer) clearTimeout(this.timerTimer);
		const ids = new Set(this.timerIds.values());
		let changed = false;
		if (this.serverOnline) {
			await Promise.all(
				[...ids].filter((id) => id > 0).map(async (id) => {
					const r = await get<TimerStatus & { ok: boolean }>(`/api/timer?id=${id}&action=status`, 3000);
					if (r.ok && r.data) {
						const prev = this.timers.get(id);
						const next: TimerStatus = { active: !!r.data.active, paused: !!r.data.paused, value: String(r.data.value ?? ""), minutes: r.data.minutes, seconds: r.data.seconds, mode: r.data.mode };
						if (!prev || prev.active !== next.active || prev.paused !== next.paused || prev.value !== next.value) changed = true;
						this.timers.set(id, next);
					}
				}),
			);
		}
		if (changed) this.emit("timers");
		this.timerTimer = setTimeout(() => void this.pollTimers(), 1000);
	}

	watchTimer(context: string, headsetId: number): void {
		this.timerIds.set(context, headsetId);
	}
	unwatchTimer(context: string): void {
		this.timerIds.delete(context);
	}
	async refreshTimer(id: number): Promise<void> {
		const r = await get<TimerStatus>(`/api/timer?id=${id}&action=status`, 3000);
		if (r.ok && r.data) {
			this.timers.set(id, { active: !!r.data.active, paused: !!r.data.paused, value: String(r.data.value ?? ""), minutes: r.data.minutes, seconds: r.data.seconds, mode: r.data.mode });
			this.emit("timers");
		}
	}

	headsetById(id: number): Headset | undefined {
		return this.headsets.find((h) => h.ID === id);
	}

	/**
	 * Target of a key: "selected" (config pages), "slot:N" (N-th headset in display order) or
	 * "id:N" (a fixed headset). Empty = fallback slot (column of the key + 1).
	 */
	resolveTarget(target: string | undefined, fallbackSlot: number): Headset | undefined {
		const t = (target ?? "").trim();
		if (t === "selected") return this.headsetById(this.selectedId);
		let m = /^id:(\d+)$/.exec(t);
		if (m) return this.headsetById(Number(m[1]));
		m = /^slot:(\d+)$/.exec(t);
		const slot = m ? Number(m[1]) : fallbackSlot;
		return slot >= 1 ? this.headsets[slot - 1] : undefined;
	}

	/** Volume / brightness of a headset (ADB read, can take several seconds). */
	async loadLevels(h: Headset, force = false): Promise<HeadsetLevels | undefined> {
		const cur = this.levels.get(h.ID);
		if (cur && !force && Date.now() - cur.at < 60000) return cur;
		const r = await get<any>(`/api/headset-settings?name=${encodeURIComponent(displayName(h.Name))}`, 45000);
		if (r.data) {
			const lv: HeadsetLevels = {
				soundLevel: toNum(r.data.soundLevel),
				brightness: toNum(r.data.brightness),
				at: Date.now(),
				raw: r.data,
			};
			this.levels.set(h.ID, lv);
			this.emit("change");
			return lv;
		}
		return cur;
	}
}

function toNum(v: unknown): number | undefined {
	const n = typeof v === "number" ? v : parseInt(String(v ?? ""), 10);
	return Number.isFinite(n) ? n : undefined;
}

export const store = new Store();
store.setMaxListeners(100);
