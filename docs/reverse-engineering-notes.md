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
