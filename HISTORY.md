# Release history

Every package the CI has published, appended automatically by the publish job
(rows are never edited or removed). [`verify.sh`](verify.sh) uses this file to
find which vendor `.deb` and which `build.sh` commit produced a package, then
rebuilds it and checks that the result is identical.

Entries start with the first reproducible build. Earlier test builds are not listed.

| Published (UTC) | Package | Vendor version | Vendor .deb | Vendor .deb sha256 | Package sha256 | Build commit | Run |
|---|---|---|---|---|---|---|---|
