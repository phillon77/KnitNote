# CloudKit Development Integration

The `CloudKitDevelopmentIntegrationTests` live probe is off by default. A normal
test run reports it as **NOT RUN**; that is not a passing CloudKit integration.

To opt in, use a signed Development build whose configured container exists and
whose current iCloud account is available, then set both variables:

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=1
KNITNOTE_CLOUDKIT_ENVIRONMENT=Development
```

The environment marker must be exactly `Development` (case-insensitive).
`Production` is rejected before a `CKContainer` is constructed. Missing opt-in,
missing container configuration, a signed entitlement that is not explicitly
Development, unavailable account, or inaccessible container causes the test
trait to report **NOT RUN / unavailable**, never PASS. A signed Production
CloudKit environment is refused before `CKContainer` access.

An enabled run creates a uniquely named custom zone in the private Development
database, creates and fetches one probe record, updates and fetches it again,
then deletes the entire test zone. Error cleanup also attempts to delete the
zone. It does not deploy a Production schema and must never be run with a
Production environment marker.
