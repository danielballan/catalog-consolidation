Start local PG instance with podman.

```sh
podman run --rm --name tiled-test-postgres -p 5432:5432 -e POSTGRES_PASSWORD=secret -d docker.io/postgres:16
```

Initialize empty `src` and `dst` catalogs. Populate `src` with example data.

```sh
./setup.sh
```

Run consolidation script, grafting the children of node 0 in src onto node 1 in dst.

```sh
psql postgresql://postgres:secret@localhost:5432/dst -f consolidate.sql
```

Examine the results.

```sh
python review_dst.py
```

Clean up.

```sh
./clean.sh
```
