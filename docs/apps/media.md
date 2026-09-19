# Media

Everything runs in the `media` namespace and shares the `media-pool` volume
(two Longhorn replicas), mounted at `/media` in every app.

```text
Seerr (movies.harville.dev)  request
  -> Radarr                  add movie, search
  -> Prowlarr                indexers: The Pirate Bay, YTS, LimeTorrents
  -> qBittorrent (via VPN)   download to /media/downloads/complete/movies
  -> Radarr                  hardlink into /media/library/movies
  -> Jellyfin                Movies library
```

Books uses the same Prowlarr and qBittorrent (category `books`).

## Where the wiring lives

The apps store each other's addresses in their own databases, so these are
enforced from Git rather than set in the UIs:

| Link | Enforced by |
| --- | --- |
| Seerr -> Radarr server, Seerr -> Jellyfin address | `scripts/seerr_prepare.py`, on every Seerr start |
| Radarr download client and root folder | `scripts/media_links.py`, the `media-links` CronJob (every 30 minutes) |
| Prowlarr download client, Prowlarr -> Radarr link, indexer list | same |

All addresses are short service names (`radarr`, `prowlarr`, `qbittorrent`,
`jellyfin`), which resolve inside the namespace. Changes made in the UIs to
anything else (quality profiles, libraries, extra indexers) are left alone;
the job only creates or corrects what it declares and never deletes.

To apply a change immediately instead of waiting for the schedule:

```bash
kubectl -n media create job --from=cronjob/media-links media-links-now
kubectl -n media logs -f job/media-links-now
```

Indexers are added to Prowlarr and pushed to Radarr by Prowlarr's full sync.
Prowlarr will not sync an indexer that returns no results in Radarr's movie
categories; that is why LimeTorrents is present in Prowlarr but not Radarr.
