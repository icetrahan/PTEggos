# PTEggos

Canonical Pterodactyl eggs for Primal Hosted / Primal Heaven. The `*_egg`
folders in the `PrimalEverything` workspace are **mirrors** — edits there deploy
nothing; this repo is the source.

| Egg | Folder | How it reaches production |
|---|---|---|
| DeathMatch | `isles/deathmatch` | **repo → ghcr → node.** `.github/workflows/isles.yml` builds `ghcr.io/icetrahan/isles:<game>` |
| Survival | `isles/survival` | ″ |
| Legacy Survival | `isles/legacy-survival` | ″ |
| Evrima Survival | `isles/evrima-survival` | ″ |
| **The Isle: Evrima (Windows / feathers)** — egg **40** | `isles/evrima-windows-feathers` | ⚠️ **panel → repo.** No image, no Dockerfile; the panel DB is what the daemon reads. This folder is the reviewable record + re-import source. See its README. |

⚠️ **A push is a deploy.** `isles.yml` triggers on any push to `main` touching
`isles/**` and rebuilds **all four** Linux images regardless of which path
changed (plus a weekly cron). See workspace BUGS **#398**.

`testing/` and `steamcmd/` are not customer-facing.
