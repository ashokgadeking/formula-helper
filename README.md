# Formula Helper

A baby feeding tracker built for a Raspberry Pi touchscreen kiosk, accessible from anywhere via a serverless AWS backend.

## What it does

Tracks everything around newborn feeding in one place — formula prep, diaper changes, and baby weight — with a UI designed for one-handed use at 3am.

### Formula tracking
- Tap **90 / 100 / 120 ml** to start a countdown timer for that bottle size
- Timer counts down and sends a push notification (via ntfy) when the formula is about to expire
- Log each completed bottle with one tap; edit or delete entries from the log
- Custom amount calculator for non-standard sizes
- Sample sizes reference screen

### Diaper tracking
- **💧 Pee** and **💩 Poo** quick-log buttons on the main screen
- Shows last diaper changed time on the relevant button
- Today's pee/poo counts displayed inline
- Manual entry with date/time picker for logging missed changes

### Trends
- **Formula trends** — daily ml consumed, bottle count, 7/30/365-day/all-time bar chart, optional baby weight overlay (upload CSV from Greater Goods scale)
- **Diaper trends** — vertical 24-hour timeline per day; pee (yellow) and poo (brown) bars plotted at their exact time of day; optional formula feeding overlay (blue bars) for correlation; Today/Week/Month/All ranges

### Log
- Unified formula + diaper log screen with tab picker
- Navigate by day with prev/next arrows
- Edit formula entries (adjust ml, mark leftover)
- Delete any entry with confirmation

## Architecture

```
Raspberry Pi (kiosk)          AWS (serverless)
┌─────────────────┐           ┌──────────────────────────┐
│ Chromium kiosk  │◄─────────►│ CloudFront CDN            │
│ (800×480 touch) │           │  ├─ /api/* → API Gateway  │
└─────────────────┘           │  │    └─ Lambda (Python)  │
                              │  │         └─ DynamoDB    │
Any browser / HomePod ────────►  └─ /* → S3 static site  │
                              └──────────────────────────┘
```

- **Frontend** — single `index.html` with vanilla JS + Chart.js; Outfit font; dark theme
- **Backend** — AWS SAM (Lambda + API Gateway HTTP API + DynamoDB); Python 3.12
- **Auth** — WebAuthn passkeys (no passwords)
- **Notifications** — ntfy.sh push notifications for bottle expiry
- **Hosting** — S3 static site behind CloudFront; API Gateway on same CloudFront distribution

## Hardware

- Raspberry Pi (any model with WiFi)
- 5" 800×480 HDMI touchscreen
- Optional: Greater Goods baby scale (CSV weight export → weight overlay on formula trends)

## Deployment

Requires AWS CLI with SSO profile `viper`.

```bash
# Deploy backend (Lambda + API Gateway + DynamoDB)
sam build
sam deploy --stack-name formula-helper --resolve-s3 --capabilities CAPABILITY_IAM --profile viper

# Deploy frontend
aws s3 cp web/index.html s3://formula-helper-web/index.html --profile viper
aws cloudfront create-invalidation --distribution-id <dist-id> --paths "/index.html" --profile viper
```

## Running tests

```bash
pip install -r requirements-dev.txt
pytest tests/
```
