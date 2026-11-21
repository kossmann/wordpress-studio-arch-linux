# Release history

Every package the CI has published, appended automatically by the publish job
(rows are never edited or removed). [`verify.sh`](verify.sh) uses this file to
find which vendor `.deb` and which `build.sh` commit produced a package, then
rebuilds it and checks that the result is identical.

Entries start with the first reproducible build. Earlier test builds are not listed.

| Published (UTC) | Package | Vendor version | Vendor .deb | Vendor .deb sha256 | Package sha256 | Build commit | Run |
|---|---|---|---|---|---|---|---|
| 2026-11-21 20:59 | `wordpress-studio-bin-2.3.1-4` | `2.3.1` | https://appscdn.wordpress.com/wp-content/uploads/2026/11/studio-x64-v2.3.1.deb | `6c49597b6a42c049b562a2c53b4834a417b71fc01ff89eaa64f9983a3bbd041d` | `23a1b38b011800fa13e07fd35f7f76710d6b6760a6143d9848918c04ecef64d6` | [`dccc653`](https://github.com/kossmann/wordpress-studio-arch-linux/commit/dccc653b7b59e24220c9dba216807e4d392a1131) | [run](https://github.com/kossmann/wordpress-studio-arch-linux/actions/runs/44949038623) |
