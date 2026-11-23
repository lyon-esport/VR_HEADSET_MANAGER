// Base class of every VRHM key: keeps each visible key's settings, redraws them from the
// shared store, answers the property inspector datasources, and handles long presses.

import streamDeck, {
	type KeyAction,
	KeyDownEvent,
	KeyUpEvent,
	SendToPluginEvent,
	SingletonAction,
	DidReceiveSettingsEvent,
	WillAppearEvent,
	WillDisappearEvent,
} from "@elgato/streamdeck";
import type { JsonObject, JsonValue } from "@elgato/utils";
import { store } from "./store";

export const PROFILES = {
	main: "profiles/vrhm-main",
	headset: "profiles/vrhm-headset",
	apps: "profiles/vrhm-apps",
	kiosks: "profiles/vrhm-kiosks",
	views: "profiles/vrhm-views",
	settings: "profiles/vrhm-settings",
};

export const LONG_PRESS_MS = 700;

export type KeyCtx<S extends JsonObject> = { action: KeyAction<S>; settings: S; column: number; row: number };

export abstract class VrhmAction<S extends JsonObject> extends SingletonAction<S> {
	protected keys = new Map<string, KeyCtx<S>>();
	private lastImage = new Map<string, string>();
	private lastTitle = new Map<string, string>();
	private downAt = new Map<string, NodeJS.Timeout>();
	private longFired = new Set<string>();
	private subscribed = false;

	/** Draw one key from the store. */
	protected abstract draw(k: KeyCtx<S>): Promise<void> | void;
	/** Short press (or the only press when hasLongPress() is false). */
	protected abstract press(k: KeyCtx<S>): Promise<void> | void;
	/** Long press (held LONG_PRESS_MS). Return false when the key has none. */
	protected longPress(_k: KeyCtx<S>): Promise<void> | void | false {
		return false;
	}
	protected hasLongPress(_k: KeyCtx<S>): boolean {
		return false;
	}
	/** Called when a key appears (after settings stored). */
	protected appeared(_k: KeyCtx<S>): void {}
	protected disappeared(_id: string): void {}

	private subscribe(): void {
		if (this.subscribed) return;
		this.subscribed = true;
		store.on("change", () => this.redrawAll());
	}

	redrawAll(): void {
		for (const k of this.keys.values()) void this.safeDraw(k);
	}

	protected async safeDraw(k: KeyCtx<S>): Promise<void> {
		try {
			await this.draw(k);
		} catch (e) {
			streamDeck.logger.error(`draw failed: ${e}`);
		}
	}

	/** setImage / setTitle only when the value changed (avoids flooding Stream Deck). */
	protected async paint(k: KeyCtx<S>, image: string, title = ""): Promise<void> {
		const id = k.action.id;
		if (this.lastImage.get(id) !== image) {
			this.lastImage.set(id, image);
			await k.action.setImage(image);
		}
		if (this.lastTitle.get(id) !== title) {
			this.lastTitle.set(id, title);
			await k.action.setTitle(title);
		}
	}

	override async onWillAppear(ev: WillAppearEvent<S>): Promise<void> {
		if (!ev.action.isKey()) return;
		store.start();
		this.subscribe();
		const c = (ev.payload as any).coordinates ?? { column: 0, row: 0 };
		const k: KeyCtx<S> = { action: ev.action, settings: ev.payload.settings, column: c.column ?? 0, row: c.row ?? 0 };
		this.keys.set(ev.action.id, k);
		this.lastImage.delete(ev.action.id);
		this.lastTitle.delete(ev.action.id);
		this.appeared(k);
		await this.safeDraw(k);
	}

	override onWillDisappear(ev: WillDisappearEvent<S>): void {
		this.keys.delete(ev.action.id);
		this.lastImage.delete(ev.action.id);
		this.lastTitle.delete(ev.action.id);
		this.disappeared(ev.action.id);
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<S>): Promise<void> {
		const k = this.keys.get(ev.action.id);
		if (!k) return;
		k.settings = ev.payload.settings;
		this.lastImage.delete(k.action.id);
		this.appeared(k);
		await this.safeDraw(k);
	}

	override onKeyDown(ev: KeyDownEvent<S>): void {
		const k = this.keys.get(ev.action.id);
		if (!k) return;
		k.settings = ev.payload.settings;
		this.longFired.delete(k.action.id);
		if (this.hasLongPress(k)) {
			const t = setTimeout(() => {
				this.longFired.add(k.action.id);
				this.downAt.delete(k.action.id);
				void this.run(k, () => this.longPress(k));
			}, LONG_PRESS_MS);
			this.downAt.set(k.action.id, t);
		}
	}

	override async onKeyUp(ev: KeyUpEvent<S>): Promise<void> {
		const k = this.keys.get(ev.action.id);
		if (!k) return;
		const t = this.downAt.get(k.action.id);
		if (t) clearTimeout(t);
		this.downAt.delete(k.action.id);
		if (this.longFired.has(k.action.id)) {
			this.longFired.delete(k.action.id);
			return;
		}
		await this.run(k, () => this.press(k));
	}

	private async run(k: KeyCtx<S>, fn: () => unknown): Promise<void> {
		try {
			await fn();
		} catch (e) {
			streamDeck.logger.error(`action failed: ${e}`);
			await k.action.showAlert();
		}
	}

	/** Property inspector datasources: {event:"getTargets"} etc. */
	override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, S>): Promise<void> {
		const p = ev.payload as any;
		if (!p || typeof p !== "object" || !p.event) return;
		if (p.event === "getTargets") {
			const items: { label: string; value: string }[] = [];
			items.push({ value: "", label: this.defaultTargetLabel() });
			if (this.allowSelectedTarget()) items.push({ value: "selected", label: "Selected headset (config page)" });
			const n = Math.max(store.headsets.length, 5);
			for (let i = 1; i <= n; i++) {
				const h = store.headsets[i - 1];
				items.push({ value: `slot:${i}`, label: `Slot ${i}${h ? " (now " + h.Name + ")" : ""}` });
			}
			for (const h of store.headsets) items.push({ value: `id:${h.ID}`, label: `Always: ${h.Name} (#${h.ID})` });
			await streamDeck.ui.sendToPropertyInspector({ event: "getTargets", items });
		}
	}

	protected allowSelectedTarget(): boolean {
		return true;
	}

	/** Label of the empty target value in the property inspector. */
	protected defaultTargetLabel(): string {
		return "Default: slot = key column";
	}

	/** Default slot of a key placed on the deck: its column + 1. */
	protected fallbackSlot(k: KeyCtx<S>): number {
		return k.column + 1;
	}
}

export async function switchTo(action: KeyAction<any>, profile: string): Promise<void> {
	await streamDeck.profiles.switchToProfile(action.device.id, profile);
}

/** Flash a key title for a moment (e.g. "HOLD"). */
export function flashTitle(action: KeyAction<any>, text: string, ms = 1200): void {
	void action.setTitle(text);
	setTimeout(() => void action.setTitle(""), ms);
}
