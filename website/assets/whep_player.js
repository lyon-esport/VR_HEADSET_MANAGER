/* WHEP client (WebRTC HTTP Egress Protocol) used by recordings.html.
 * Same connect logic as the live [video].html template, minus the retry loop:
 * the caller (a playback session) decides what to do on failure.
 *   WhepPlayer.connect(videoEl, url) -> Promise<handle>
 *   WhepPlayer.close(handle)
 */
(function () {
  'use strict';

  function close(handle) {
    if (!handle) return;
    var pc = handle.pc;
    if (pc) {
      pc.oniceconnectionstatechange = null;
      pc.ontrack = null;
      try { pc.close(); } catch (e) {}
    }
    handle.pc = null;
    if (handle.videoEl && handle.videoEl.srcObject) {
      try { handle.videoEl.srcObject = null; } catch (e2) {}
    }
  }

  // retries: the publisher may need a moment to appear (404 first), so a few
  // quick attempts are made before giving up.
  function connect(videoEl, url, opts) {
    opts = opts || {};
    var attempts = opts.attempts || 8;
    var handle = { pc: null, videoEl: videoEl, url: url, closed: false, onDrop: null };

    function once() {
      var pc = new RTCPeerConnection();
      handle.pc = pc;
      pc.addTransceiver('video', { direction: 'recvonly' });
      try { pc.addTransceiver('audio', { direction: 'recvonly' }); } catch (e) {}
      pc.ontrack = function (evt) {
        if (evt.streams && evt.streams[0]) videoEl.srcObject = evt.streams[0];
      };
      pc.oniceconnectionstatechange = function () {
        var s = pc.iceConnectionState;
        if ((s === 'failed' || s === 'closed') && !handle.closed && handle.onDrop) handle.onDrop(s);
      };
      return pc.createOffer()
        .then(function (offer) { return pc.setLocalDescription(offer); })
        .then(function () {
          return new Promise(function (resolve) {
            if (pc.iceGatheringState === 'complete') { resolve(); return; }
            pc.onicegatheringstatechange = function () {
              if (pc.iceGatheringState === 'complete') resolve();
            };
            setTimeout(resolve, 500);
          });
        })
        .then(function () {
          return fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/sdp' },
            body: pc.localDescription.sdp
          });
        })
        .then(function (res) {
          if (!res.ok) throw new Error('WHEP response: ' + res.status);
          return res.text();
        })
        .then(function (sdp) { return pc.setRemoteDescription({ type: 'answer', sdp: sdp }); })
        .then(function () { return handle; });
    }

    function attempt(n) {
      if (handle.closed) return Promise.reject(new Error('closed'));
      return once().catch(function (err) {
        if (handle.pc) { try { handle.pc.close(); } catch (e) {} handle.pc = null; }
        if (handle.closed || n + 1 >= attempts) throw err;
        return new Promise(function (r) { setTimeout(r, Math.min(500 * (n + 1), 2000)); })
          .then(function () { return attempt(n + 1); });
      });
    }

    var p = attempt(0);
    p.handle = handle;
    return p;
  }

  window.WhepPlayer = {
    connect: connect,
    close: function (h) { if (h) { h.closed = true; } close(h); }
  };
})();
