---
name: cloudron-app-publishing
description: Distribute Cloudron apps via CloudronVersions.json. Covers cloudron versions init/add/update/revoke/list, manifest requirements for publishing, and distribution methods. Use when the user wants to publish, distribute, or share a Cloudron app package with others, or mentions CloudronVersions.json.
---

# Cloudron App Publishing

Distribute Cloudron apps independently using a `CloudronVersions.json` version catalog. Users add the file's URL in their dashboard or install via `cloudron install --versions-url <url>`.

## Prerequisites

Each published version needs a Docker image in a registry. On-server builds (`cloudron install` without a registry image) do not produce registry-hosted images and cannot be published.

If a registry is in use, build with `cloudron builder build` (after `cloudron builder login`). Do **not** use `cloudron build`. `cloudron versions add` uses the last `cloudron builder` image. On a TTY it asks for confirmation. `--last-build` skips the prompt. `--image` records a specific image (no prompt).

```bash
cloudron versions add
cloudron versions add --last-build
cloudron versions add --image registry.example.com/username/myapp:1.0.0
```

## Workflow

```
cloudron versions init       # create CloudronVersions.json, scaffold manifest
cloudron versions add        # add version (last builder image, or --image / --last-build)
# host CloudronVersions.json at a public URL
```

## Initialize

```bash
cloudron versions init
```

Creates `CloudronVersions.json` in the package directory. Also adds missing publishing fields to `CloudronManifest.json` with placeholder values and creates stub files:

- `DESCRIPTION.md` — detailed app description
- `CHANGELOG` — version changelog
- `POSTINSTALL.md` — post-install message shown to users

Edit all placeholders and stubs before adding a version.

### Required manifest fields for publishing

Beyond what `cloudron init` provides, publishing requires:

| Field | Example |
|-------|---------|
| `id` | `com.example.myapp` |
| `title` | `My App` |
| `author` | `Jane Developer <jane@example.com>` |
| `tagline` | `A short one-line description` |
| `version` | `1.0.0` |
| `website` | `https://example.com/myapp` |
| `contactEmail` | `support@example.com` |
| `iconUrl` | `https://example.com/icon.png` |
| `packagerName` | `Jane Developer` |
| `packagerUrl` | `https://example.com` |
| `tags` | `["productivity", "collaboration"]` |
| `mediaLinks` | `["https://example.com/screenshot.png"]` |
| `description` | `file://DESCRIPTION.md` |
| `changelog` | `file://CHANGELOG` |
| `postInstallMessage` | `file://POSTINSTALL.md` |
| `minBoxVersion` | `9.1.0` |

`cloudron versions init` scaffolds all of these with defaults.

## Versions commands

### cloudron versions add

Adds the current version to `CloudronVersions.json`. Reads the version from `CloudronManifest.json` and records the last builder image or `--image`.

```bash
cloudron versions add --last-build
Added 1.0.0 in CloudronVersions.json
```

### cloudron versions list

```bash
cloudron versions list
```

Shows all versions with their creation date, image, and publish state.

### cloudron versions update

Updates an existing version entry. Primarily used to change the publish state.

```bash
cloudron versions update --version 1.0.0 --state published
```

Avoid changing the manifest or image of a published version — users may have already installed it. To ship changes, revoke the existing version and add a new one.

### cloudron versions revoke

Marks the latest published version as revoked. Users who have not yet updated will not receive it.

```bash
cloudron versions revoke
Marked 1.0.0 as revoked in CloudronVersions.json
```

To ship a fix: bump the version in `CloudronManifest.json`, then `cloudron versions add` (or `--image` / `--last-build`).

## Distribution

Host `CloudronVersions.json` at any publicly accessible URL (static file host, git repo, web server).

Users install in two ways:

- **Dashboard** — Add the URL under Community apps in the dashboard settings. Updates appear automatically.
- **CLI** — `cloudron install --versions-url <url>`

## Typical release cycle

```bash
# 1. Edit code, bump version in CloudronManifest.json
# 2. Add to catalog (last builder image, or pass --image)
cloudron versions add --last-build

# 3. Commit and push CloudronVersions.json to hosting
git add CloudronVersions.json && git commit -m "release 1.1.0" && git push
```

## Forum

Post about new packages in the [App Packaging & Development](https://forum.cloudron.io/category/96/app-packaging-development) category.
