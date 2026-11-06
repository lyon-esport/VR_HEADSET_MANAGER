package com.vrheadsetmanager.companion

import android.accessibilityservice.AccessibilityService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.text.Normalizer

/**
 * Optional auto-approve of Horizon's "allow debugging" popup so a headset can be onboarded without
 * a tap inside the headset. OFF by default (ApproveConfig.autoApprove).
 *
 * Technique (from the MIT eu.project_simple.adbautoenable, reimplemented):
 *  - The popup is an overlay in a window titled "VrUsb" and is accessibility-data-sensitive, so the
 *    service MUST declare isAccessibilityTool="true" (see approve_a11y.xml) or getWindows() is empty.
 *  - Scan windows on ALL displays (the popup may be on a non-default display), match the "VrUsb"
 *    title, take its root and click the "always allow" button by id (android:id/button3). Some
 *    firmwares instead use a checkbox + positive button, so we handle that shape too.
 *  - No gestures / key injection (canPerformGestures breaks Horizon input); click nodes by action.
 *  - The popup can appear before its content is reachable, so retry every 250 ms up to 20 times.
 *
 * Safety (our add over adbautoenable): the per-COMPUTER popup shows an RSA fingerprint; we approve it
 * only if that fingerprint is on the allowlist ApproveConfig provisioned from VRHM. The network popup
 * is approved (operator opted in) only when positively identified by its SSID/BSSID lines; a popup
 * with no readable fingerprint that is not identified is left alone. Every decision is logged.
 */
class ApproveService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    private var retriesLeft = 0
    private var scheduled = false

    private val POPUP_WINDOW_TITLE = "vrusb"
    private val ALWAYS_ALLOW_BUTTON_ID = "android:id/button3" // AlertDialog neutral = "Always allow..."
    private val POSITIVE_BUTTON_ID = "android:id/button1"

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "connected; autoApprove=${ApproveConfig.autoApprove(this)} trusted=${ApproveConfig.trustedFingerprints(this).size}; tool=${isTool()}")
        kick()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        handler.removeCallbacksAndMessages(null)
        scheduled = false
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val t = event.eventType
        if (t != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            t != AccessibilityEvent.TYPE_WINDOWS_CHANGED) return
        kick()
    }

    /** (Re)arm a bounded 250 ms x 20 scan burst. Never an unbounded poll (that ANR'd before). */
    private fun kick() {
        retriesLeft = 20
        if (!scheduled) {
            scheduled = true
            handler.post(scanRunnable)
        }
    }

    private val scanRunnable = object : Runnable {
        override fun run() {
            val handled = try { scanOnce() } catch (e: Throwable) { Log.i(TAG, "scan error: ${e.message}"); false }
            retriesLeft--
            if (!handled && retriesLeft > 0) {
                handler.postDelayed(this, 250)
            } else {
                scheduled = false
            }
        }
    }

    private fun isTool(): Boolean =
        try { serviceInfo?.isAccessibilityTool == true } catch (_: Throwable) { false }

    /** @return true when a popup was found and acted on (so the burst can stop). */
    private fun scanOnce(): Boolean {
        val popup = findPopupWindow() ?: return false
        val root = popup.root ?: return false
        val budget = intArrayOf(600)
        val texts = ArrayList<String>()
        collectText(root, texts, 0, budget)
        Log.i(TAG, "VrUsb popup: " + texts.joinToString(" | ").take(400))

        val fp = extractFingerprint(texts)
        val ownKeyFp = try { SelfAdb.get(this).fingerprint() } catch (_: Throwable) { null }
        val popupIsOwnKey = fp != null && ownKeyFp != null && ownKeyFp.equals(fp, ignoreCase = true)

        // The companion's OWN self-ADB key is always approved, whatever the switch: it is the app
        // trusting itself, and without it the popup returns at every boot and reconnect.
        // The "allow wireless debugging on this network" popup is approved whenever the master
        // "auto-enable ADB WiFi on boot" switch is on: the operator asked for cable-free ADB, and
        // that popup is the step that otherwise keeps it off until someone taps it in the headset.
        val networkOk = AdbBootManager.autoEnabled(this) && fp == null && isNetworkPopup(texts)
        if (!ApproveConfig.autoApprove(this) && !popupIsOwnKey && !networkOk) {
            Log.i(TAG, "autoApprove OFF - observe only")
            return true // found it; nothing to do, stop the burst
        }

        if (fp != null) {
            // The companion's OWN self-ADB connection raises this popup with the companion's own
            // key; always approve that (it is the engine trusting itself). Other computers must be
            // on the operator-provisioned allowlist.
            val isOwn = popupIsOwnKey
            if (!isOwn && ApproveConfig.trustedFingerprints(this).none { it.equals(fp, ignoreCase = true) }) {
                Log.i(TAG, "per-computer fingerprint $fp NOT own and NOT on allowlist - leaving popup for a human")
                return true
            }
            Log.i(TAG, "per-computer fingerprint $fp approved (" + (if (isOwn) "own self-ADB key" else "allowlist") + ")")
        } else if (isNetworkPopup(texts)) {
            Log.i(TAG, "wireless-debugging NETWORK popup (SSID/BSSID shown, no fingerprint) - approving (operator opted in)")
        } else {
            // No readable fingerprint and not positively the network popup: could be a per-computer
            // popup whose key we cannot read. Never click it blind.
            Log.w(TAG, "popup not identified (no fingerprint, not the network popup) - leaving it for a human")
            return true
        }
        return approve(root)
    }

    /**
     * Positive identification of the "allow wireless debugging on this network" popup: it shows the
     * network name (SSID) and/or Wi-Fi address (BSSID) - these acronyms appear untranslated in every
     * locale - and carries no per-computer key wording (RSA / fingerprint / empreinte / cle).
     */
    private fun isNetworkPopup(texts: List<String>): Boolean {
        val all = fold(texts.joinToString(" "))
        val hasNetworkId = Regex("\\bb?ssid\\b").containsMatchIn(all)
        val perComputer = all.contains("rsa") || all.contains("fingerprint") || all.contains("empreinte") ||
            Regex("\\bcle\\b").containsMatchIn(all)
        return hasNetworkId && !perComputer
    }

    /**
     * Find the system debug popup window by its "VrUsb" title across all displays. Title ONLY - a
     * text match would catch our own UI (its mode label contains "wireless debugging") and any other
     * app mentioning debugging. The popup's own window is reliably titled "VrUsb" on Horizon, and
     * our own package is excluded defensively.
     */
    private fun findPopupWindow(): AccessibilityWindowInfo? {
        val all = ArrayList<AccessibilityWindowInfo>()
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val byDisplay = windowsOnAllDisplays
                for (i in 0 until byDisplay.size()) byDisplay.valueAt(i)?.let { all.addAll(it) }
            } catch (_: Throwable) {}
        }
        if (all.isEmpty()) windows?.let { all.addAll(it) }

        return all.firstOrNull { w ->
            w.title?.toString()?.lowercase()?.contains(POPUP_WINDOW_TITLE) == true &&
                w.root?.packageName?.toString() != packageName
        }
    }

    private fun approve(root: AccessibilityNodeInfo): Boolean {
        // Preferred: the neutral "always allow" button (button3).
        root.findAccessibilityNodeInfosByViewId(ALWAYS_ALLOW_BUTTON_ID)?.firstOrNull()?.let { btn ->
            val ok = btn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            Log.i(TAG, "clicked button3 (always allow) -> $ok")
            return ok
        }
        // Horizon VR panel: the choice is a clickable node with no android:id, matched by its text
        // ("Toujours autoriser depuis cet ordinateur" / "Always allow from this computer").
        find(root) { it.isClickable && fold(nodeText(it)).let { s ->
            s.contains("toujours autoriser") || s.contains("always allow") } }?.let { btn ->
            val ok = btn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            Log.i(TAG, "clicked always-allow by text (${btn.text}) -> $ok")
            if (ok) return true
        }
        // Fallback shape: tick an "always allow" checkbox, then click the positive button.
        find(root) { (it.isCheckable || it.className?.contains("CheckBox") == true) &&
            fold(nodeText(it)).let { s -> s.contains("toujours") || s.contains("always") } }
            ?.let { cb -> if (cb.isCheckable && !cb.isChecked) Log.i(TAG, "tick always -> " + cb.performAction(AccessibilityNodeInfo.ACTION_CLICK)) }
        val pos = root.findAccessibilityNodeInfosByViewId(POSITIVE_BUTTON_ID)?.firstOrNull()
            ?: find(root) { it.isClickable && fold(nodeText(it)).let { s -> s == "autoriser" || s == "allow" || s == "ok" } }
        if (pos != null) {
            val ok = pos.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            Log.i(TAG, "clicked positive (id=${pos.viewIdResourceName} text=${pos.text}) -> $ok")
            return ok
        }
        Log.i(TAG, "no clickable approve button found")
        return false
    }

    private val fpRegex = Regex("([0-9A-Fa-f]{2}:){6,}[0-9A-Fa-f]{2}")
    private fun extractFingerprint(texts: List<String>): String? =
        texts.firstNotNullOfOrNull { fpRegex.find(it)?.value }

    private fun nodeText(n: AccessibilityNodeInfo): String =
        (n.text?.toString() ?: "") + " " + (n.contentDescription?.toString() ?: "") + " " + (n.viewIdResourceName ?: "")

    private fun collectText(node: AccessibilityNodeInfo?, out: MutableList<String>, depth: Int, budget: IntArray) {
        if (node == null || depth > 15 || budget[0] <= 0) return
        budget[0]--
        node.text?.toString()?.takeIf { it.isNotBlank() }?.let { out.add(it) }
        node.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { out.add(it) }
        val n = node.childCount
        for (i in 0 until n) { if (budget[0] <= 0) return; collectText(node.getChild(i), out, depth + 1, budget) }
    }

    private fun find(node: AccessibilityNodeInfo?, pred: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (node == null) return null
        if (pred(node)) return node
        for (i in 0 until node.childCount) { val r = find(node.getChild(i), pred); if (r != null) return r }
        return null
    }

    private fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()

    override fun onInterrupt() {}

    companion object { const val TAG = "VRHMApprove" }
}
