/// JavaScript put into every web app page.
enum WebScripts {
    static let notifyHandler = "atriumNotify"
    static let logHandler = "atriumLog"

    /// Diagnostics only (`--debug-weblog`): what the page sees during drag-and-drop, plus errors and failed requests.
    static let debugLog = """
    (() => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(logHandler);
      if (!h || window.__atriumLog) return;
      window.__atriumLog = true;
      const say = (s) => { try { h.postMessage(String(s).slice(0, 500)); } catch (_) {} };
      const d = (el) => {
        if (!el || !el.tagName) return String(el);
        const id = el.getAttribute && (el.getAttribute('data-testid') || el.getAttribute('data-component-selector') || el.id);
        return el.tagName.toLowerCase() + (id ? '[' + id + ']' : '');
      };
      const dt = (e) => e.dataTransfer ? ' types=' + [...e.dataTransfer.types].join('|') + ' effect=' + e.dataTransfer.dropEffect + '/' + e.dataTransfer.effectAllowed : '';
      let last = 0, overs = 0;
      for (const t of ['dragstart', 'dragenter', 'dragleave', 'drop', 'dragend']) {
        window.addEventListener(t, (e) => {
          if ((t === 'dragenter' || t === 'dragleave') && Date.now() - last < 120) return;
          last = Date.now();
          say(t + ' ' + d(e.target) + ' x=' + e.clientX + ' y=' + e.clientY + ' atPoint=' + d(document.elementFromPoint(e.clientX, e.clientY)) + ' screen=' + e.screenX + ',' + e.screenY + dt(e) + ' handled=' + e.defaultPrevented);
        });
      }
      window.addEventListener('dragover', (e) => { if (++overs % 30 === 0) say('dragover #' + overs + ' ' + d(e.target) + ' y=' + e.clientY + ' handled=' + e.defaultPrevented); });
      window.addEventListener('pointerdown', (e) => say('pointerdown ' + d(e.target) + ' x=' + e.clientX + ' y=' + e.clientY + ' screen=' + e.screenX + ',' + e.screenY), true);
      window.addEventListener('error', (e) => say('error ' + e.message + ' @' + e.filename + ':' + e.lineno));
      window.addEventListener('unhandledrejection', (e) => say('rejection ' + ((e.reason && (e.reason.stack || e.reason.message)) || e.reason)));
      const ce = console.error;
      console.error = function (...a) { say('console.error ' + a.map(String).join(' ')); return ce.apply(this, a); };
      const of = window.fetch;
      window.fetch = function (...a) {
        const req = a[0], url = (req && req.url) || String(req), method = ((a[1] && a[1].method) || (req && req.method) || 'GET').toUpperCase();
        const quiet = method === 'GET' || /analytics|gasv3|metal|xpsearch|telemetry|events/.test(url);
        return of.apply(this, a).then((r) => {
          if (!quiet || !r.ok) say('fetch ' + method + ' ' + r.status + ' ' + url.split('?')[0]);
          return r;
        }, (err) => { say('fetch FAILED ' + method + ' ' + url.split('?')[0] + ' ' + err); throw err; });
      };
    })();
    """

    /// Web pages inside an app view have no notifications of their own. This gives them the standard `Notification`
    /// API (always allowed); each one is passed to Atrium, which shows it as a Mac notification. Clicking that calls
    /// back into the page (`__atriumNotificationClick`), so the site opens the right conversation, as in a browser.
    static let notificationShim = """
    (() => {
      if (window.__atriumNotify) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(notifyHandler);
      if (!handler) return;
      window.__atriumNotify = true;
      const live = new Map();
      let next = 1;
      class AtriumNotification extends EventTarget {
        constructor(title, options) {
          super();
          options = options || {};
          this.title = String(title);
          this.body = options.body ? String(options.body) : '';
          this.tag = options.tag ? String(options.tag) : '';
          this.data = options.data === undefined ? null : options.data;
          this.icon = options.icon || '';
          this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
          const id = String(next++);
          live.set(id, this);
          if (live.size > 100) live.delete(live.keys().next().value);
          handler.postMessage({ id: id, title: this.title, body: this.body, tag: this.tag });
          setTimeout(() => { const e = new Event('show'); this.dispatchEvent(e); if (typeof this.onshow === 'function') this.onshow(e); }, 0);
        }
        close() {}
        static get permission() { return 'granted'; }
        static requestPermission(callback) {
          if (typeof callback === 'function') callback('granted');
          return Promise.resolve('granted');
        }
        static get maxActions() { return 0; }
      }
      Object.defineProperty(window, 'Notification', { value: AtriumNotification, writable: true, configurable: true });
      window.__atriumNotificationClick = (id) => {
        const n = live.get(id);
        if (!n) return;
        const e = new Event('click', { cancelable: true });
        n.dispatchEvent(e);
        if (typeof n.onclick === 'function') n.onclick.call(n, e);
      };
      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (d) => (d && d.name === 'notifications')
          ? Promise.resolve({ name: 'notifications', state: 'granted', onchange: null, addEventListener() {}, removeEventListener() {} })
          : query(d);
      }
      if (window.ServiceWorkerRegistration && window.ServiceWorkerRegistration.prototype) {
        window.ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          new AtriumNotification(title, options);
          return Promise.resolve();
        };
      }
    })();
    """

    /// Calls the page's handler for a notification it posted (see `notificationShim`).
    static func notificationClick(id: String) -> String {
        let quoted = id.filter { $0.isNumber }                 // ids are plain numbers we made; never anything else
        return "window.__atriumNotificationClick && window.__atriumNotificationClick('\(quoted)')"
    }
}
