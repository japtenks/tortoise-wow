SnapJaw build-truth notes

This branch moves realmd login-build metadata into the login DB via
`snapjawrealmd.allowed_clients` and removes the old hardcoded login build list.

What is captured in code

- `realmd` loads enabled client builds from `allowed_clients`.
- Realm-list compatibility is based on `realmlist.realmbuilds` membership.
- Realm-list version labels are derived from the matched client build metadata.
- `mangosd` reads `SupportedClientBuilds` from config instead of a hardcoded list.
- Seed SQL is included for the initial Turtle login builds:
  - `7200`, `7205`, `7207` -> `1.17.2`
  - `7234` -> `1.18.0`
  - `7272` -> `1.18.1`

Important runtime finding

Turtle's world-session handshake is not identical to the login/session build
seen by `realmd`.

- `realmd` sees Turtle login builds like `7207` and `7272`.
- `mangosd` world auth can still present the legacy token `5875`.

Because of that, login-build truth and world-build compatibility should be
treated as related but separate concerns:

- `realmd` should use `allowed_clients` and `realmlist.realmbuilds`.
- `mangosd` should use `SupportedClientBuilds` for world-session acceptance.

SnapJaw live validation state from this branch

- Stable login/display truth was validated with:
  - `7207` -> `1.17.2`
  - `7272` -> `1.18.1`
- Stable world entry required `5875` to remain accepted on `mangosd`.
- PTR also required the same world-session compatibility treatment.

Operational notes used during validation

- Login DB: `snapjawrealmd`
- Manual SQL helper for existing DBs: `sql/allowed_clients_setup.sql`
- Stable live world config ended up accepting:
  - `5875 7200 7205 7207 7234 7272`
- PTR live world config ended up accepting:
  - `5875 7272`

Strict version-proof enforcement

During validation, live `realmd` used `StrictVersionCheck = 0` because the
exact Windows/Mac hashes for the new Turtle client rows were not populated yet.

That means:

- build membership and realm display were validated
- exact hash-proof enforcement still needs a follow-up pass

Follow-up work

- fill `windows_hash` / `mac_hash` for the concrete Turtle client variants
- re-enable strict version checking in live `realmd`
- decide whether to formalize a login-build -> world-token compatibility mapping
