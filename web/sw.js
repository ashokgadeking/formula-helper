// Formula Helper Service Worker — handles push notifications

self.addEventListener('push', function(event) {
  let data = {title: 'Formula Helper', body: 'Notification'};
  try {
    data = event.data.json();
  } catch(e) {
    data.body = event.data ? event.data.text() : 'Notification';
  }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Formula Helper', {
      body: data.body || '',
      icon: data.icon || undefined,
      badge: data.badge || undefined,
      tag: data.tag || 'formula-helper',
      renotify: true,
    })
  );
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({type: 'window'}).then(function(list) {
      for (const client of list) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          return client.focus();
        }
      }
      return clients.openWindow('/');
    })
  );
});
