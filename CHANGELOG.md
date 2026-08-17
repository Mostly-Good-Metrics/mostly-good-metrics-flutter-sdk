## Unreleased

- `$identify` event now includes `$anonymous_id` (the stored anonymous ID used before `identify()`) so the backend can merge the pre-identify anonymous profile into the identified user. Omitted when the anonymous ID is absent or already equals the identified user ID.

## 0.3.0

- A/B testing support: `getVariant(name, {fallback})` + `ready({timeout})` (never hangs)
- Server-assigned variants with a shared_preferences-backed cache (stale-while-revalidate, no expiry)
- Automatic `$experiment_exposure` events with persisted dedup
- `anonymous_id` sent on identified experiment fetches (stable assignment across identify)

## 0.1.0

- Initial release
- Core analytics tracking functionality
- User identification and session management
- Automatic app lifecycle event tracking
- Event batching and automatic flushing
- Persistent event storage
- Support for all Flutter platforms (iOS, Android, Web, macOS, Windows, Linux)
