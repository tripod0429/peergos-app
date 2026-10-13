**Create the first account.** On first start Peergos prints a single-use signup link to the app logs. Look for the line containing `signup=true` and open it **without** the `:8000` that Peergos adds, i.e. `$CLOUDRON-APP-ORIGIN/?signup=true&token=...`. The first sync with the Peergos PKI can take a few minutes.

**Built-in apps need subdomains.** The PDF viewer, calendar, editor and other apps are served from subdomains of this app. Add the alias `*.$CLOUDRON-APP-FQDN` under the app's Location settings (needs a DNS provider Cloudron can drive, for the wildcard certificate). Without a wildcard, add `pdf.$CLOUDRON-APP-FQDN`, `calendar.$CLOUDRON-APP-FQDN`, `code-editor.$CLOUDRON-APP-FQDN`, `markup-viewer.$CLOUDRON-APP-FQDN`, `email.$CLOUDRON-APP-FQDN` and `address-book.$CLOUDRON-APP-FQDN` as aliases; third-party apps won't work then.

**Peer-to-peer ports.** Allow port 4001 over TCP and UDP in any firewall in front of the server.

**Settings** live in `/app/data/env.sh`. Edit it with the File Manager, then restart the app. Each setting is explained in the file; the most useful are `PEERGOS_ADMIN_USERNAMES` and `PEERGOS_DEFAULT_QUOTA` (1 GiB per user by default).
