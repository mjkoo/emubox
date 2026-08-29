# secrets

`secrets.yaml` (not yet created) is one sops file encrypted to the admin's
age key and the host SSH key; see `.sops.yaml`. Keys it will hold:
Cloudflare tunnel credentials, Backblaze B2 key pair, restic password,
RetroAchievements credentials, ScreenScraper credentials, WiFi PSK, admin
password hash, GitHub deploy key.
