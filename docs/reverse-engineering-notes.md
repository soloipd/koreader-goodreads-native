# Kindle native-service notes

These notes document the minimum native surface used by the plugin. Names are
obfuscated and may change between firmware releases.

## Tested environment

- Kindle firmware 5.19.5
- KOReader v2026.07.1
- Amazon framework Java 21 with `jdk.attach`

## Shelf action

- Publisher: `com.lab126.kppkaf`
- Hash property: `kppAddToGoodreadShelf`
- Payload fields: `action`, `cdekey`
- Actions used: `com.amazon.home.actions.goodread_reading` and
  `com.amazon.home.actions.goodread_read`

## Progress request

- Request class:
  `com.amazon.kindle.restricted.webservices.grok.PostShareProgressRequest`
- Request type: `ShareProgressPost`
- Command: `cmd.grok.postShareProgress`
- HTTP method: POST
- Progress type: `Percent`
- Network: `goodreads`
- Application component: `SHARE_PROGRESS_FROM_CHROME`
- Application: `reader.eink`

The request contains this logical shape:

```json
{
  "asin": "BXXXXXXXXX",
  "progress": {
    "progress_type": "Percent",
    "numerator": 42,
    "denominator": 1
  },
  "social_networks": ["goodreads"],
  "language": "en"
}
```

`ReaderSharingService.aqB()` supplies the application-version header at
runtime. `Framework.getService(GrokService.class).b(request)` performs the
authenticated request. The plugin never reads or exports the framework's
Amazon session.

The tested request returned HTTP 202 and a valid native response. Native reader
code also treats HTTP 200 as success, HTTP 422 as a parameter mismatch, and
404/502/503/504 as transient or timeout failures.

## Rating request

- Publisher: `com.lab126.grokservice`
- Hash property: `rateABook`
- Payload fields: `asin`, `rating`, `updateGoodreads`, `origin`
- Accepted rating: integer 0–5 (`0` clears the rating)
- `updateGoodreads`: integer `0` or `1`

Firmware 5.19.5 routes the property through
`com.amazon.kindle.restricted.grok.LipcHelperUtil`. Its validation rejects
missing fields, ratings outside 0–5, and non-boolean Goodreads flags before
dispatch. The plugin sends `updateGoodreads = 1` and a fixed `reader.eink`
origin. An invalid rating of 6 was confirmed to return `lipcErrInvalidArg`.

`EndActions.jar` also exposes the native interactive completion route through
`com.lab126.reading_actions / launchEndActions`, but the plugin uses the
smaller `rateABook` surface after collecting an explicit choice in KOReader.

## Annotation boundary

KOReader emits `AnnotationsModified` for highlight/note creation, edits, and
deletions. The plugin can safely observe these events and count annotation
types without reading text into its log.

Firmware 5.19.5 exposes both `com.lab126.CVMAnnotationProxy / sendAnnotations`
and direct `ReaderContentSDK` annotation management. Sanitized read-only probes
confirmed native type `1` for highlights and type `2` for text notes. The
12-character native long position decodes to nine bytes: a version byte,
little-endian 32-bit KFX EID, and little-endian 32-bit EID offset. The short
position is the KFX base PID plus that offset.

The converter branch now writes a versioned, text-free position map and tags
converted elements with their KFX anchor. The runtime translator follows the
EPUB spine and KOReader's normalized XPointer, then calculates the Unicode
offset from the nearest tagged ancestor. Ambiguous EID-to-base-PID mappings are
rejected instead of guessed.

The native bridge reconciles against the explicitly opened KFX book and uses
the native annotation manager for create, update, and delete operations.
Persisted annotations may report their start and end positions in the opposite
order from the translated KOReader range. Reconciliation therefore identifies
ranges without direction and attaches notes using the persisted highlight's
native endpoint order.
The manager's low-level durable methods do not call WhisperStore on this
firmware because `WhisperStoreKwisUtils.Ls()` is false. The agent therefore
invokes `WhisperStoreLipcBridge.a(...)` and `.d(...)` explicitly, enables the
native shadow-mode sync lanes before writing, then asks the annotation
controller to enqueue synchronization. The outgoing Java bridge also contains
an `annotationsDualWriteToKSDK` route, but this firmware does not export that
LIPC property—even while a native book is open—so the agent treats direct KSDK
writing as unavailable instead of reporting a false success. Color highlights need
a cloud-only proxy whose `Cf()` is null because this firmware returns a color
map from `Highlight.Cf()` but WhisperStore casts that value to `String`.

Older agents also discarded the converter's short PID. A long-position
round-trip could still succeed while the reconstructed end PID was zero. The
upgrade migration reconstructs those exact malformed cloud identities, sends
deletions, and replays the desired ranges with explicit short and long
coordinates.
Visibility remains governed by the Kindle/Amazon annotation pipeline; the
plugin does not invent or override a public-sharing flag.
