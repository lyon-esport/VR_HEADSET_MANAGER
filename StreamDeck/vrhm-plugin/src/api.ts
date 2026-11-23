// HTTP client of the VRHM web API. No connector: every call is a plain route of the web
// server (see CLAUDE.md, Pode_WebServer). Base URL comes from the plugin global settings.

export const DEFAULT_SERVER = "http://localhost:8080";

let serverUrl = DEFAULT_SERVER;

export function setServerUrl(url: string | undefined): void {
	let u = (url ?? "").trim();
	if (!u) u = DEFAULT_SERVER;
	if (!/^https?:\/\//i.test(u)) u = "http://" + u;
	serverUrl = u.replace(/\/+$/, "");
}

export function getServerUrl(): string {
	return serverUrl;
}

/** Name form most action routes expect (Convert-Displayname: spaces -> underscores). */
export function displayName(name: string): string {
	return (name ?? "").replace(/ /g, "_");
}

export type ApiResult<T = any> = { ok: boolean; status: number; data: T | null; error?: string };

async function call<T>(method: "GET" | "POST", path: string, body?: unknown, timeoutMs = 8000): Promise<ApiResult<T>> {
	try {
		const res = await fetch(serverUrl + path, {
			method,
			headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
			body: body !== undefined ? JSON.stringify(body) : method === "POST" ? "{}" : undefined,
			signal: AbortSignal.timeout(timeoutMs),
		});
		const text = await res.text();
		let data: any = null;
		try {
			data = text ? JSON.parse(text) : null;
		} catch {
			data = null;
		}
		const okFlag = data && typeof data === "object" && "ok" in data ? !!data.ok : res.ok;
		return { ok: res.ok && okFlag, status: res.status, data, error: data?.error ?? data?.message ?? (res.ok ? undefined : `HTTP ${res.status}`) };
	} catch (e: any) {
		return { ok: false, status: 0, data: null, error: e?.message ?? String(e) };
	}
}

export const get = <T = any>(path: string, timeoutMs?: number) => call<T>("GET", path, undefined, timeoutMs);
export const post = <T = any>(path: string, body?: unknown, timeoutMs?: number) => call<T>("POST", path, body ?? {}, timeoutMs);

/** Fetches a web asset (app icon) and returns it as a data URI, or null. */
export async function fetchDataUri(path: string): Promise<string | null> {
	try {
		const url = /^https?:/i.test(path) ? path : serverUrl + (path.startsWith("/") ? "" : "/") + path;
		const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
		if (!res.ok) return null;
		const type = res.headers.get("content-type")?.split(";")[0] || "image/png";
		const buf = Buffer.from(await res.arrayBuffer());
		return `data:${type};base64,${buf.toString("base64")}`;
	} catch {
		return null;
	}
}
