# Formula Helper — Improvements

## Backend

- [ ] Add file locking (e.g. `fcntl.flock` or threading lock) to prevent race conditions on JSON file read/writes
- [ ] Move expiry side effects (save_state, send_ntfy) out of the GET `/api/state` endpoint into a background task or POST-only route
- [ ] Log errors instead of silently swallowing exceptions in save_settings, save_state, _save_backup_status, send_ntfy
- [ ] Move hardcoded NTFY_TOPIC and BACKUP_URL to environment variables or a config file
- [ ] Fix COUNTDOWN_SECS default — currently 10 seconds (test value) instead of intended 65 minutes
- [ ] Add input validation on `/api/start` and `/api/settings` to handle bad input gracefully instead of 500s

## Frontend

- [ ] Add error handling and user feedback for failed fetch calls (startTimer, calcStart, saveModal, deleteEntry, etc.)
- [ ] Only update the currently visible screen in pollState instead of all screens every 5 seconds
- [ ] Replace `confirm()` delete dialog with a mobile-friendly UX (swipe-to-delete or undo toast)
- [ ] Add PWA support (service worker + manifest) for offline resilience on the Pi
- [ ] Bundle Chart.js locally instead of loading from CDN, so trends work offline

## General

- [ ] Add basic authentication since the app binds to 0.0.0.0
