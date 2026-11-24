# argo-apps

Argo CD configuration for the **martin** cluster (k3s). Every workload currently running in the
cluster is declared here, reverse-engineered from the live objects — the previous deployment
method was `kubectl apply` by hand (plus four Helm releases), so there was no prior source.

Every plain manifest in `apps/` was verified to produce a **zero-diff** server-side apply against
the live cluster at time of writing. Nothing here is aspirational; it is what is running.

## Layout

```
bootstrap/            Applied by hand once; everything else follows from it
  projects.yaml       AppProjects (bootstrap / infra / media / projects / games)
  root.yaml           The app-of-apps root -> bootstrap/apps/
  apps/               media/games/projects ApplicationSets, the infra group Application, static

apps/
  media/<app>/        Plain manifests — one Application generated per directory
  games/<app>/        Plain manifests — one Application generated per directory
  projects/<namespace>/<app>/
                      Plain manifests — namespace taken from the path
  infra/
    <app>.yaml        Hand-written Application (Helm chart + version + values)
    <app>/            Its Helm values (and any extra manifests)

static/
  manifests/          Shared cluster resources no single app owns
    reference/        Verbatim `kubectl get -o yaml` dumps, NOT synced (kept for diffing)
```

### Adding an app

For **media**, **games** and **projects**, create a directory of manifests and push it. Nothing
else is needed. Each group is an ApplicationSet (`bootstrap/apps/<group>.yaml`) with a git
directory generator, so every directory matching its glob becomes an Application named after the
directory:

| ApplicationSet | Glob | Namespace |
|---|---|---|
| `media` | `apps/media/*` | `media` |
| `games` | `apps/games/*` | `games` |
| `projects` | `apps/projects/*/*` | the `<namespace>` path segment (`rebnz`, `russell`, `default`) |

A new projects namespace also needs adding to the `projects` AppProject's `destinations` and
to `static/manifests/namespaces.yaml`.

Directory names must be unique across all groups, because they become Application names.

Deleting a directory does **not** delete its Application (`applicationsSync: create-update`).
This is deliberate: a typo'd rename can't cascade-delete a workload and its PVCs. To retire an
app, remove its directory, then delete the Application by hand.

**infra** stays as hand-written Applications under `apps/infra/`, picked up by the `infra-apps`
Application (non-recursive, so it sees only the `<app>.yaml` files). Each infra app has its own chart, version and release name,
so there is nothing to generate.

## What is where

| Group | Namespace(s) | Apps |
|---|---|---|
| `apps/media` | `media` | plex, sonarr, radarr, prowlarr, nzbget, qbittorrent, overseerr, tautulli, cleanuparr, storyteller, tdarr |
| `apps/games` | `games` | caleb-mc, vanilla-mc, divine-journey |
| `apps/projects/<ns>` | `rebnz`, `russell`, `default` | docuseal, domainmod, grafana, uptime-kuma, pingvin-share, stirling-pdf, tailscale, falderia, mcp-servers, ghost |
| `apps/infra` | various | cert-manager, gpu-operator, ingress-nginx, traefik, keel, sealed-secrets, nextcloud, democratic-csi ×2 |

`tdarr` is one Application covering the `tdarr` and `tdarr-node` StatefulSets, the two
pause/unpause CronJobs, and the `tdarr-scaler` ServiceAccount/Role/RoleBinding they use.

## Helm

The nine `apps/infra` Applications consume **upstream charts directly** — nothing is forked or
vendored. Each uses Argo's two-source pattern: the chart from its own repo, plus this repo
mounted as `$values` so the values file stays editable here.

| App | Chart | Version | Notes |
|---|---|---|---|
| cert-manager | `charts.jetstack.io/cert-manager` | `v1.18.2` | Matches the live Helm release exactly |
| gpu-operator | `helm.ngc.nvidia.com/nvidia/gpu-operator` | `v25.3.4` | Matches the live release; see below |
| democratic-csi-app-data | `democratic-csi/democratic-csi` | `0.15.1` | Driver image is `latest` (pulled on every pod start) |
| democratic-csi-bulk-storage | `democratic-csi/democratic-csi` | `0.15.1` | See "bulk-storage StorageClass" below |
| ingress-nginx | `kubernetes.github.io/ingress-nginx` | `4.6.0` | **Migration** — was static manifests |
| traefik | `traefik.github.io/charts/traefik` | `42.4.1` | Replacing ingress-nginx; see below |
| keel | `charts.keel.sh/keel` | `1.2.3` | **Migration** — was a hand-rolled Deployment |
| sealed-secrets | `bitnami.github.io/sealed-secrets/sealed-secrets` | `2.22.0` | New install, in `kube-system`; see "Secrets" |
| nextcloud | `nextcloud.github.io/helm/nextcloud` | `9.4.5` | New install; see "Nextcloud" below |

`gpu-operator` sets `helm.releaseName: gpu-operator-1722298273` to preserve the generated names
of the node-feature-discovery sub-chart resources already in the cluster. Do not "tidy" this —
renaming the release renames those objects.

`gpu-operator` also syncs `apps/infra/gpu-operator/manifests/` as a third source, which holds
the `nvidia-device-plugin-config` ConfigMap (GPU time-slicing: the one GPU is advertised as 4
`nvidia.com/gpu` slots). `devicePlugin.config` in its values points at it. Its values also set
`validator.plugin: null`. Without that, chart v25.3.4 renders `plugin: null` into the ClusterPolicy,
which server-side apply rejects.

Chart 4.6.0 of ingress-nginx ships controller `v1.7.0`, i.e. the exact image already running, so
adopting it does not upgrade the controller.

`traefik` (v3.7.19) is taking over from ingress-nginx, which is retired upstream and will not be
patched for the nginx HTTP/2 bugs CVE-2026-123007 / CVE-2026-123633. Its ingress-nginx provider
serves the existing `ingressClassName: nginx` Ingresses and their `nginx.ingress.kubernetes.io/*`
annotations unchanged, so both controllers can run side by side. ingress-nginx stays deployed as
a fallback until Traefik has proven itself. Traefik's Service is the LoadBalancer on
192.168.1.251; the old hand-made ingress-nginx one is demoted to ClusterIP. The fallback steps
are in the comments of `apps/infra/traefik/values.yaml`.

### Nextcloud

`nextcloud` (Nextcloud 35.0.3) is served at **https://next.qinnovate.nz**. It is under
`apps/infra` only because that is where the Helm-based Applications live. The chart owns just the
Deployment, Service and Ingress; `apps/infra/nextcloud/manifests/` is synced as a third source
and holds everything stateful:

| What | Where | Storage |
|---|---|---|
| User files (`/var/www/html/data`) | PVC `nextcloud-data`, 2Ti | `bulk-storage` (TrueNAS NFS) |
| Code, config, apps (`/var/www/html`) | PVC `nextcloud-app`, 10Gi | `app-data` (TrueNAS NFS) |
| PostgreSQL 17 (`nextcloud-postgres`) | StatefulSet claim `data-nextcloud-postgres-0` | `local-path` (node disk) |
| Redis 8 (`nextcloud-redis`): file locks, cache, sessions | Deployment | none (disposable) |
| Collabora Online (`nextcloud-collabora`): document editing | Deployment (chart subchart) | none (stateless) |
| Nightly `pg_dump`, 14 days kept | PVC `nextcloud-db-backup`, 20Gi | `app-data` (TrueNAS NFS) |

The database is on local disk because PostgreSQL should not run on NFS; the 02:30 dump CronJob
is what gets it onto TrueNAS. Restore a dump with `pg_restore --clean --if-exists -d nextcloud`.

The admin, database, Redis, SMTP and Collabora admin-console credentials are the SealedSecrets
`nextcloud-admin`, `nextcloud-db`, `nextcloud-redis`, `nextcloud-smtp` and `nextcloud-collabora`. Mail goes out through Mailgun as
`nextcloud@mg.qinnovate.nz`.
The admin password is only used for the first install. Read it with:

```sh
kubectl --context martin get secret nextcloud-admin -n nextcloud \
  -o jsonpath='{.data.nextcloud-password}' | base64 -d
```

#### Nextcloud Office

Documents are edited with Collabora Online at **https://office.qinnovate.nz**, through the
Nextcloud Office (`richdocuments`) app. The app and its settings live in Nextcloud's database,
not in git; on a rebuild, set them again:

```bash
occ() { kubectl --context martin -n nextcloud exec deploy/nextcloud -c nextcloud -- \
  su -s /bin/sh www-data -c "php occ $*"; }
occ app:install richdocuments
occ config:app:set richdocuments wopi_url --value=http://nextcloud-collabora:9980
occ config:app:set richdocuments public_wopi_url --value=https://office.qinnovate.nz
occ richdocuments:activate-config
```

Chart upgrades move Nextcloud itself: it only supports upgrading one major version at a time, so
do not skip chart versions that span more than one.

## Secrets

**No plaintext secrets are in this repo.** New secrets go in as SealedSecrets (below). The
older ones predate that: they already exist in the cluster and are left alone. If the cluster is
ever rebuilt from scratch, these must be recreated by hand:

| Secret | Namespace | Used by |
|---|---|---|
| `app-data-democratic-csi-driver-config` | `storage` | democratic-csi — holds the TrueNAS API key |
| `bulk-storage-democratic-csi-driver-config` | `storage` | democratic-csi — holds the TrueNAS API key |
| `tailscale-auth` | `rebnz` | tailscale — `TS_AUTHKEY` |
| `tailscale-state` | `rebnz` | tailscale — written by the pod itself, do not pre-create |
| `mcp-servers-env` | `russell` | mcp-servers — env file |
| `ghcr-russell` | `russell` | falderia, mcp-servers — ghcr.io pull secret |
| `ghcr-keel` | `keel` | keel — ghcr.io credentials for polling private images |
| `storyteller-secret` | `media` | storyteller |

The democratic-csi Applications use the chart's `driver.existingConfigSecret` to read the whole
driver config from the secret already in the cluster, so the TrueNAS API key never enters git.
Verified: with that set, the chart emits no config Secret, so a sync cannot clobber the live one.

All `*-tls` secrets are cert-manager output and regenerate themselves from the Ingresses.

### Sealed Secrets

The `sealed-secrets` app runs the controller as `sealed-secrets-controller` in `kube-system`,
which is where `kubeseal` looks by default. To add a secret, seal it against the cluster and
commit the result next to the app that uses it:

```sh
kubectl create secret generic my-secret -n my-namespace \
  --from-literal=password=... --dry-run=client -o yaml \
  | kubeseal --context martin --format yaml > my-secret.sealed.yaml
```

A SealedSecret is bound to its name and namespace; it will not decrypt under a different one.

**Back up the sealing key.** It lives only in the cluster. Without it, a rebuilt cluster cannot
decrypt anything sealed here. Keep the output somewhere outside the cluster and outside git,
and repeat after key renewals (a new key is added every 30 days; old ones are kept):

```sh
kubectl --context martin get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
```

To restore, apply that file to the new cluster before syncing `sealed-secrets`.

## Adopting the live cluster

Auto-sync is **deliberately off** on every app Application. The root app and the group
Applications/ApplicationSets self-sync (they only manage Argo objects); the leaf apps do not, so that the first diff of each can
be eyeballed before anything is written to a live workload.

```sh
kubectl --context martin create namespace argocd
# install Argo CD itself, then:
kubectl --context martin apply -f bootstrap/projects.yaml
kubectl --context martin apply -f bootstrap/root.yaml
```

The root app creates the ApplicationSets and the infra group Application, which together create
the 33 leaf Applications. They will
all report `OutOfSync` initially — that is expected, because Argo has not yet stamped its
tracking label on anything. Sync them one at a time and confirm the diff is only labels.

Once satisfied, enable auto-sync by adding the following to the `syncPolicy`. For an infra app,
add it in its `apps/infra/<app>.yaml`. For media, games or projects, add it in the ApplicationSet
`template`, which turns it on for the whole group:

```yaml
    automated:
      selfHeal: true
```

Don't toggle auto-sync on a generated app in the UI. The ApplicationSet owns those Applications
and reverts the change on its next reconcile.

Leave `prune: false` (the default) on the leaf apps. Pruning is how a typo in a path deletes a
24Ti PVC.

`ServerSideApply=true` is set on every app. This matters for adoption: these objects carry large
`kubectl.kubernetes.io/last-applied-configuration` annotations from years of manual applies, and
client-side apply conflicts with them.

## Known issues found while capturing this

These are pre-existing conditions in the cluster, not problems introduced by this repo.

**keel cannot be adopted in place.** The chart's Deployment selector is
`{app: keel, release: keel}`; the live hand-rolled one is `{app: keel}`. Deployment selectors are
immutable, so the first sync will fail with `spec.selector: field is immutable` until the old
Deployment is removed:

```sh
kubectl --context martin delete deployment keel -n keel
```

keel is a stateless image-update poller, so this costs nothing but a short gap in polling. The
hand-made `keel` ClusterRole/ClusterRoleBinding/ServiceAccount are superseded by the chart's.

**ingress-nginx will roll once.** Adopting the chart adds Helm labels and the `--publish-service`
flag, and drops the dead `--tcp-services-configmap` flag (see below), which restarts the
controller pod. The image is unchanged. Delete the old `tcp-services` ConfigMap by hand afterwards.
The admission ServiceAccount/RBAC and the two `ingress-nginx-admission-*` Jobs are Helm hooks in
the chart, but were permanent objects in the old static install, so Argo flags them for pruning
until the first sync. Their `before-hook-creation` delete policy replaces them during the sync,
so Job immutability is not a blocker.

**The `bulk-storage` StorageClass is missing from the cluster.** Its Helm release declares it, but
it is not present — something deleted it. `media/data` (24Ti) is already bound so it still works,
but new `bulk-storage` claims would fail. Syncing `democratic-csi-bulk-storage` recreates it.

**Two default StorageClasses.** Both `app-data` and `local-path` are marked
`is-default-class: true`. A PVC with no `storageClassName` gets whichever the API server picks.
Worth fixing, but out of scope here — `local-path` is k3s-managed, not in this repo.

**The TCP passthrough was dead and has been dropped.** The live `tcp-services` ConfigMap mapped
25565/25566 to the Minecraft Services, but no traffic could reach it: the LoadBalancer Service
only exposes 80/443, the controller never listened on those ports, and the game Services don't
expose them. Players connect on the NodePorts (31115-31117).

**`plex` has `serviceName: ''`** on its StatefulSet, and the `plex-0` Service was hand-made with
pod labels pasted onto it (the stale ones were stripped here). Both reproduced as-is.

## Deliberately excluded

- **Orphaned leftovers.** The `terriblehack` (dribdat) and `podinate-quick-start` namespaces hold
  Services/Ingresses/PVCs with no workloads behind them. Also orphaned: the `clickhouse-http`,
  `clickhouse-native` and `trilium` Services and the `trilium` Ingress in `rebnz`, and the
  `data-superset-postgresql-0`, `local-config-plex-0`, `config-sonarr-0` (media) and
  `config-nzbget-0`, `data-clickhouse-0`, `logs-clickhouse-0` (rebnz) PVCs. These can be deleted.
- **StatefulSet-generated PVCs.** Claims like `config-plex-0` come from `volumeClaimTemplates` and
  must not be declared separately. Only the three standalone shared claims (`media`, `data`,
  `local-data`) are in `static/manifests/`, with `volumeName` pinned so they adopt their existing
  PVs rather than provisioning empty ones.
- **k3s-managed components.** coredns, metrics-server, local-path-provisioner, klipper-lb, and the
  `kube-system` nvidia device plugin. These are managed by k3s itself.
- **Cluster CRDs and RuntimeClasses** not owned by an app in this repo.

## Argo CD UI

Argo CD itself is installed from upstream manifests and is not managed here. The one exception
is `static/manifests/argocd-ingress.yaml`, which serves it at **https://argocd.qinnovate.nz**.
nginx terminates the Let's Encrypt cert and re-encrypts to `argocd-server`'s own TLS
(`backend-protocol: HTTPS`), so Argo's server config is untouched. The CLI must use gRPC-web
through nginx:

```sh
argocd login argocd.qinnovate.nz --grpc-web
```

## Pinned NodePorts

Several Services pin `nodePort` equal to `port` deliberately, and these are externally
meaningful — do not let them be reallocated:

| Service | Port |
|---|---|
| `games/caleb-mc` | 31115 |
| `games/vanilla-mc` | 31116 |
| `games/divine-journey` | 31117 |
| `media/plex-0` | 32400 |
| `rebnz/kumanp` | 30400 |
