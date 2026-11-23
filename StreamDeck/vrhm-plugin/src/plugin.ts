// VR Headset Manager - Stream Deck plugin entry point.
// Talks only to the existing VRHM web API (no connector). Server address = global setting
// `serverUrl` (default http://localhost:8080), editable from any key's property inspector.

import streamDeck from "@elgato/streamdeck";
import { setServerUrl } from "./api";
import { CommandAction } from "./actions/command";
import { HeadsetStatusAction } from "./actions/headset-status";
import { SettingAction } from "./actions/settings";
import { AppSlotAction, KioskSlotAction } from "./actions/slots";
import { TimerAction } from "./actions/timer";
import { ViewSlotAction } from "./actions/views";
import { store } from "./store";

type GlobalSettings = { serverUrl?: string };

streamDeck.logger.setLevel("info");

streamDeck.actions.registerAction(new HeadsetStatusAction());
streamDeck.actions.registerAction(new CommandAction());
streamDeck.actions.registerAction(new TimerAction());
streamDeck.actions.registerAction(new AppSlotAction());
streamDeck.actions.registerAction(new KioskSlotAction());
streamDeck.actions.registerAction(new ViewSlotAction());
streamDeck.actions.registerAction(new SettingAction());

streamDeck.settings.onDidReceiveGlobalSettings<GlobalSettings>((ev) => {
	setServerUrl(ev.settings.serverUrl);
	store.refreshSoon(0);
});

await streamDeck.connect();
const g = await streamDeck.settings.getGlobalSettings<GlobalSettings>();
setServerUrl(g.serverUrl);
store.start();
