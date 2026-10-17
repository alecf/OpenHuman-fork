# CloudKit schema

`schema.ckdb` describes the envelope written by `CloudKitMapping.ckRecord`. The
current reference types are `Split`, `Setting`, and `ImportanceRule`, registered
by the package's test harness. The Mail applications do not yet instantiate this
sync package or register payload adapters. Importing this schema does not enable
app sync.

Every type has the same custom fields:

| Field | CloudKit type | Value |
| --- | --- | --- |
| `f` | `INT64` | Envelope format version |
| `kid` | `STRING` | Encryption key identifier |
| `hlc` | `STRING` | Hybrid logical clock |
| `dev` | `STRING` | Writer device identifier |
| `del` | `INT64` | Boolean tombstone flag |
| `blob` | `ENCRYPTED BYTES` | Inline AES-GCM sealed payload |
| `asset` | `ASSET` | Larger AES-GCM sealed payload |

Only one of `blob` and `asset` is populated. The schema language supports
`ENCRYPTED BYTES`, but not `ENCRYPTED ASSET`; asset contents are sealed by
`CloudRecordCodec` before reaching CloudKit. System fields are declared without
indexes. No field has a queryable, sortable, or searchable index: `CKSyncEngine`
fetches zone changes and the adapter performs no queries.

`CloudKitDatabase` explicitly selects `container.privateCloudDatabase`. Schemas
are shared across a container's databases; grants do not select the database.
This file grants only `READ` and `WRITE` to `_creator`, with no `_world`, `_icloud`,
or public creation grant. Check the Console's effective permissions before
deployment, especially for a container that already has a schema.

Additional proposed types have no registered writers yet and are intentionally
absent: `Snippet`, `Reminder`, `WaitingOverride`, `AutoLabelCorrection`,
`RuleSetHead`, `PromptOverride`, `LearnedCounters`, `AIResult`, `EmbeddingPack`,
`Cursor`, and `Device`.

## Validate and import Development

Create the container and associate it with your app identifiers first. In
[CloudKit Console](https://icloud.developer.apple.com/), create a management token
under your account's Settings. Save it from Terminal.app's interactive prompt;
keep the token out of arguments, source files, and agent sessions:

```sh
xcrun cktool save-token --type management
```

From the repository root, replace `YOUR_TEAM_ID` and `YOUR_CONTAINER_ID`:

```sh
xcrun cktool validate-schema \
  --team-id YOUR_TEAM_ID \
  --container-id YOUR_CONTAINER_ID \
  --environment development \
  --file Packages/OpenHumanCloudSync/Schema/schema.ckdb

xcrun cktool import-schema --validate \
  --team-id YOUR_TEAM_ID \
  --container-id YOUR_CONTAINER_ID \
  --environment development \
  --file Packages/OpenHumanCloudSync/Schema/schema.ckdb
```

Both commands contact Apple; validation requires authentication too. Before
importing into an existing container, export its Development schema and reconcile
it with this file. Apple discourages reconstructing an existing schema by hand.

## Deploy Production

After validating the schema and testing app integration in Development, select
the container in CloudKit Console's Database app, choose **Deploy Schema
Changes**, review the diff, and select **Deploy** with an administrator account.
Production deployment merges schema changes and copies no records. Deployed
record types and fields cannot be deleted or renamed; review them before this
step. Use the Console for deployment.

## Verification and sources

`CloudKitSchemaTests` parses the file and compares its custom fields and types
with records built by the real mapper, including inline/asset and tombstone
paths for each reference type. It also checks the type registration, owner-only
grants, and absence of indexes. It runs locally without a CloudKit account.

The syntax, `ENCRYPTED BYTES`, and role names are documented in Apple's
[schema language grammar](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).
System-field declarations follow Apple's
[WWDC21 example at 5:51](https://developer.apple.com/videos/play/wwdc2021/10118/?time=351).
Command flags were checked against local `cktool` help; see also
[Using cktool](https://developer.apple.com/icloud/ck-tool/) and
[deploying a schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).
**Unconfirmed:** acceptance of this file by your container. The local parser
checks drift, not Apple's complete grammar or server permissions. No server
validation, import, or deployment has been performed for this file.
