// Foreground-only, generic local previews. No messaging credentials or push sender.
window.medisyncAlerts = (() => {
  const visible = new Map();
  return {
    async request() {
      if (!window.isSecureContext || !('Notification' in window)) return false;
      return (await Notification.requestPermission()) === 'granted';
    },
    show(id, kind) {
      if (!('Notification' in window) || Notification.permission !== 'granted' || document.visibilityState !== 'visible') return false;
      try {
        visible.get(id)?.notification.close();
        const notification = new Notification(kind === 'workflow' ? 'MediSync update' : 'MediSync reminder', {
          body: kind === 'workflow' ? 'A workflow status changed. Open MediSync to check current updates.' : 'An appointment is approaching. Open MediSync to check its current status.',
          tag: id,
        });
        visible.set(id, {notification, kind});
        notification.onclick = () => { window.focus(); notification.close(); };
        return true;
      } catch (_) { return false; }
    },
    clear(remindersOnly) {
      for (const [id, item] of visible) {
        if (!remindersOnly || item.kind !== 'workflow') {
          item.notification.close(); visible.delete(id);
        }
      }
    },
  };
})();
