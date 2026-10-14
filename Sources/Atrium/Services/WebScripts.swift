/// JavaScript put into every web app page.
enum WebScripts {
    static let notifyHandler = "atriumNotify"

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
