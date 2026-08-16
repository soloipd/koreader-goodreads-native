import com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight;
import com.amazon.ebook.booklet.reader.impl.annotation.personal.Note;
import com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType;
import com.amazon.ebook.booklet.reader.impl.whisperstore.WhisperStoreLipcBridge;
import com.amazon.kindle.restricted.runtime.Framework;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import testsupport.Fakes;

public final class GoodreadsAnnotationAgentV29Test {
    private static final String ASIN = "B0FLB24198";
    private static final String START = "AAAAAAAAAAAA";
    private static final String END = "AAAAAAAAAAAB";
    private static final String OTHER_START = "AAAAAAAAAAAC";
    private static final String OTHER_END = "AAAAAAAAAAAD";
    private static final int START_SHORT = 100;
    private static final int END_SHORT = 200;
    private static final String TERMINAL_START = "ATwFAAAVAQAA";
    private static final String TERMINAL_END = "ATwFAAD4AgAA";
    private static final String TERMINAL_END_NORMALIZED = "ATwFAAD3AgAA";
    private static int requestSequence = 10000000;

    private GoodreadsAnnotationAgentV29Test() {}

    public static void main(String[] ignored) throws Exception {
        verifyExactRangeIdentityParsing();

        Fakes.SDK sdk = new Fakes.SDK();
        sdk.activeBook = new Fakes.Book("test-guid");
        Framework.setService(sdk);
        WhisperStoreLipcBridge.reset();

        Map<String, String> created = run(sdk, desired("first note"), previous());
        expect("true", created.get("success"), "create should succeed: " + created);
        expect("true", created.get("local_verified"), "create should be verified after reopen");
        expect("true", created.get("native_notified"), "native reader should be notified");
        expect("2", created.get("native_notifications"), "highlight and note should reach KPP/KSDK");
        expect("0", created.get("ksdk_writes"), "legacy firmware must not use KSDK writes");
        expect("unavailable", created.get("ksdk_synced"), "disabled KSDK should be explicit");
        expect("1", created.get("highlights_created"), "highlight should be created");
        expect("1", created.get("notes_created"), "note should be created");
        expect("2", created.get("native_journal_edits"),
            "highlight and note should reach Kindle's native journal");
        expect("1", created.get("native_upload_requests"),
            "native journal upload should be requested once per reconciliation");
        expect("true", created.get("native_cloud_queued"), "native cloud queue should be confirmed");
        expect("true", created.get("legacy_journaled"), "legacy journal path should be confirmed");
        expect("0", created.get("cloud_edits"), "disabled WhisperStore must not receive false edits");
        expect("0", created.get("cloud_snapshots"), "disabled WhisperStore must not ingest snapshots");
        expect("unavailable", created.get("cloud_snapshot_synced"),
            "disabled WhisperStore snapshot should be explicit");
        expect(2, sdk.journaling.entries.size(), "two detached-book journal entries are required");
        expect(true, String.valueOf(sdk.journaling.books.get(0).book)
                .startsWith("/mnt/us/documents/Test_B0FLB24198.kfx|B0FLB24198|EBOK|0|"),
            "journal entry must retain the requested local-book identity");
        expect(1, sdk.whisperSync.requests, "WhisperSync upload should be requested");
        expect(2, sdk.content.manager.annotations.size(), "native store should contain highlight and note");
        expect(false, sdk.activeBook.closed, "active native book must remain open after create");
        expect(AnnotationWriteOperationType.CREATE, sdk.proxy.operations.get(0),
            "highlight create should notify KPP/KSDK");
        expect(AnnotationWriteOperationType.CREATE, sdk.proxy.operations.get(1),
            "note create should notify KPP/KSDK");

        Fakes.SDK duplicateIdentitySdk = new Fakes.SDK();
        duplicateIdentitySdk.activeBook = new Fakes.Book(
            "placeholder-guid", "/cloud/B0FLB24198");
        Framework.setService(duplicateIdentitySdk);
        Map<String, String> duplicateIdentity = run(
            duplicateIdentitySdk, desired("identity test"), previous());
        expect("false", duplicateIdentity.get("success"),
            "duplicate-ASIN reconciliation must wait for the exact local book");
        expect("inactive_identity_mismatch", duplicateIdentity.get("book_source"),
            "same-ASIN placeholder must not receive local-book annotations");
        expect("wait_for_active_book", duplicateIdentity.get("failed_stage"),
            "inactive books must be reported as retryable instead of synced");
        expect("0", duplicateIdentity.get("native_notifications"),
            "inactive book must not enter KPP's live-only proxy");
        expect(null, duplicateIdentitySdk.content.lastBook,
            "inactive reconciliation must not mutate a detached sidecar");

        Fakes.SDK matchingIdentitySdk = new Fakes.SDK();
        matchingIdentitySdk.activeBook = new Fakes.Book("test-guid");
        Framework.setService(matchingIdentitySdk);
        Map<String, String> matchingIdentity = run(
            matchingIdentitySdk, desired("identity test"), previous());
        expect("true", matchingIdentity.get("success"),
            "matching active-book reconciliation should succeed");
        expect("active", matchingIdentity.get("book_source"),
            "exact-path active local book should be reused");
        expect(null, matchingIdentitySdk.content.lastBook,
            "active reconciliation must not open a potentially aliased comparison handle");
        expect(false, matchingIdentitySdk.activeBook.closed,
            "selected active book must remain open");

        Framework.setService(sdk);

        Map<String, String> unchanged = run(sdk, desired("first note"), previous(START, END, true));
        expect("true", unchanged.get("success"), "unchanged reconciliation should succeed");
        expect("2", unchanged.get("native_notifications"),
            "persisted highlight and note should be re-announced to KPP");
        expect("0", unchanged.get("highlights_created"),
            "KPP refresh must not duplicate the persisted highlight");
        expect("0", unchanged.get("notes_created"),
            "KPP refresh must not duplicate the persisted note");

        Highlight corrupt = new Highlight(
            new Fakes.Position("AAAAAAAAAAAZ", 0),
            new Fakes.Position(START, START_SHORT)
        );
        sdk.content.manager.annotations.add(corrupt);
        List<String> migrationPayload = desired("first note");
        migrationPayload.add("repair_zero_endpoint=true");
        migrationPayload.add("purge_legacy_cloud=true");
        migrationPayload.add("force_cloud_replay=true");
        Map<String, String> migrated = run(
            sdk,
            migrationPayload,
            previous(START, END, true)
        );
        expect("true", migrated.get("success"), "migration replay should succeed: " + migrated);
        expect("0", migrated.get("highlights_created"), "migration should not duplicate highlights");
        expect("1", migrated.get("zero_endpoint_repairs"),
            "migration should remove the generation-6 zero-endpoint artifact");
        expect("3", migrated.get("native_notifications"),
            "migration should delete the corrupt record and refresh the persisted pair in KPP");
        expect("0", migrated.get("ksdk_writes"),
            "legacy migration must not claim KSDK writes");
        expect("5", migrated.get("native_journal_edits"),
            "migration should delete local/cloud artifacts and replay the correct pair");
        expect("0", migrated.get("cloud_edits"),
            "disabled WhisperStore must not receive migration edits");
        expect("2", migrated.get("legacy_cloud_deletes"),
            "migration should purge the malformed cloud highlight and note");

        Map<String, String> updated = run(sdk, desired("edited note"), previous(START, END, true));
        expect("true", updated.get("success"), "note update should succeed");
        expect("1", updated.get("notes_updated"), "note should be updated");
        expect("edited note", findNote(sdk).getText(), "native note text should change");
        expect(AnnotationWriteOperationType.UPDATE,
            sdk.proxy.operations.get(sdk.proxy.operations.size() - 1),
            "note update should notify KPP/KSDK");

        Map<String, String> noteRemoved = run(sdk, desired(""), previous(START, END, true));
        expect("true", noteRemoved.get("success"), "note removal should succeed");
        expect("1", noteRemoved.get("notes_deleted"), "owned note should be deleted");
        expect(1, sdk.content.manager.annotations.size(), "highlight should remain after note removal");
        expect(AnnotationWriteOperationType.DELETE,
            sdk.proxy.operations.get(sdk.proxy.operations.size() - 1),
            "note deletion should notify KPP/KSDK");

        Map<String, String> deleted = run(sdk, noDesired(), previous(START, END, false));
        expect("true", deleted.get("success"), "highlight deletion should succeed");
        expect("1", deleted.get("highlights_deleted"), "owned highlight should be deleted");
        expect(0, sdk.content.manager.annotations.size(), "owned range should be removed");

        Highlight nativeOnly = new Highlight(
            new Fakes.Position(OTHER_START, 300),
            new Fakes.Position(OTHER_END, 400)
        );
        sdk.content.manager.annotations.add(nativeOnly);
        Map<String, String> preserved = run(sdk, noDesired(), previous());
        expect("true", preserved.get("success"), "empty reconciliation should succeed");
        expect(1, sdk.content.manager.annotations.size(), "native-only highlight must be preserved");
        expect(nativeOnly, sdk.content.manager.annotations.get(0), "native-only object must be unchanged");

        Fakes.SDK reversedSdk = new Fakes.SDK();
        reversedSdk.activeBook = new Fakes.Book("test-guid");
        Framework.setService(reversedSdk);
        reversedSdk.content.manager.annotations.add(new Highlight(
            new Fakes.Position(END, END_SHORT),
            new Fakes.Position(START, START_SHORT)
        ));
        Map<String, String> reversed = run(
            reversedSdk,
            desired("note on reversed native range"),
            previous(START, END, false)
        );
        expect("true", reversed.get("success"), "reversed native range should reconcile");
        expect("0", reversed.get("highlights_created"), "existing reversed highlight must be reused");
        expect("1", reversed.get("notes_created"), "note should attach using native endpoint order");
        expect("2", reversed.get("native_notifications"),
            "reused reversed highlight and new note should both reach KPP");
        expect(2, reversedSdk.content.manager.annotations.size(), "reversed range must not duplicate highlight");

        Fakes.SDK terminalSdk = new Fakes.SDK();
        terminalSdk.activeBook = new Fakes.Book("test-guid");
        terminalSdk.content.positions.register(TERMINAL_START, 443000);
        terminalSdk.content.positions.register(TERMINAL_END_NORMALIZED, 443345);
        Framework.setService(terminalSdk);
        List<String> terminalPayload = basePayload();
        terminalPayload.add("desired_count=1");
        terminalPayload.add("desired.0.start=" + TERMINAL_START);
        terminalPayload.add("desired.0.start_short=443000");
        terminalPayload.add("desired.0.end=" + TERMINAL_END);
        terminalPayload.add("desired.0.end_short=443346");
        terminalPayload.add("desired.0.note_hex=");
        Map<String, String> terminal = run(
            terminalSdk,
            terminalPayload,
            previous(TERMINAL_START, TERMINAL_END, false)
        );
        expect("true", terminal.get("success"), "terminal endpoint repair should succeed");
        expect("1", terminal.get("terminal_endpoint_repairs"),
            "terminal endpoint should be moved to the final resolvable character");
        Highlight terminalHighlight = (Highlight) terminalSdk.content.manager.annotations.get(0);
        expect(TERMINAL_END_NORMALIZED, terminalHighlight.jd().nX(),
            "native highlight must use the decremented terminal endpoint");
        expect(Integer.valueOf(443345), terminalHighlight.jd().UF(),
            "native highlight must use the factory-resolved short endpoint");

        int beforeMalformed = reversedSdk.content.manager.annotations.size();
        List<String> malformed = basePayload();
        malformed.add("desired_count=1");
        malformed.add("desired.0.start=bad");
        malformed.add("desired.0.end=" + END);
        malformed.add("desired.0.note_hex=");
        malformed.add("previous_count=0");
        Map<String, String> rejected = run(reversedSdk, malformed, previous());
        expect("false", rejected.get("success"), "malformed position must fail");
        expect("validate_payload", rejected.get("failed_stage"), "malformed input must fail before opening");
        expect(ASIN, rejected.get("asin"), "payload failures must retain their correlation ASIN");
        expect(true, rejected.get("request_id") != null,
            "payload failures must retain their correlation request ID");
        expect(beforeMalformed, reversedSdk.content.manager.annotations.size(), "malformed input must not mutate native state");

        System.out.println("Annotation agent behavior tests passed.");
    }

    private static void verifyExactRangeIdentityParsing() throws Exception {
        Properties payload = new Properties();
        payload.setProperty("desired_count", "3");
        addDesired(payload, 0, START, 100, END, 200, "");
        addDesired(payload, 1, START, 100, END, 200, "retained note");
        addDesired(payload, 2, START, 101, END, 201, "nearby note");
        Method reader = GoodreadsAnnotationAgentV29.class.getDeclaredMethod(
            "readRecords", Properties.class, String.class);
        reader.setAccessible(true);
        List<?> records = (List<?>) reader.invoke(null, payload, "desired");
        expect(2, records.size(),
            "nearby highlights sharing coarse locations must remain distinct");
        Field note = records.get(0).getClass().getDeclaredField("note");
        note.setAccessible(true);
        expect("retained note", note.get(records.get(0)),
            "an exact KFX collision must preserve its non-empty note");
    }

    private static void addDesired(
        Properties payload,
        int index,
        String start,
        int startShort,
        String end,
        int endShort,
        String note
    ) {
        String base = "desired." + index + ".";
        payload.setProperty(base + "start", start);
        payload.setProperty(base + "start_short", String.valueOf(startShort));
        payload.setProperty(base + "end", end);
        payload.setProperty(base + "end_short", String.valueOf(endShort));
        payload.setProperty(base + "note_hex", hex(note));
    }

    private static List<String> basePayload() {
        List<String> lines = new ArrayList<String>();
        lines.add("version=1");
        lines.add("asin=" + ASIN);
        lines.add("request_id=" + (++requestSequence));
        lines.add("native_path_hex=" + hex("/mnt/us/documents/Test_B0FLB24198.kfx"));
        return lines;
    }

    private static List<String> desired(String note) {
        List<String> lines = basePayload();
        lines.add("desired_count=1");
        lines.add("desired.0.start=" + START);
        lines.add("desired.0.start_short=" + START_SHORT);
        lines.add("desired.0.end=" + END);
        lines.add("desired.0.end_short=" + END_SHORT);
        lines.add("desired.0.note_hex=" + hex(note));
        return lines;
    }

    private static List<String> noDesired() {
        List<String> lines = basePayload();
        lines.add("desired_count=0");
        return lines;
    }

    private static List<String> previous(String... values) {
        List<String> lines = new ArrayList<String>();
        lines.add("previous_count=" + (values.length / 3));
        for (int index = 0; index < values.length; index += 3) {
            lines.add("previous." + (index / 3) + "=" + values[index] + ":" + values[index + 1]
                + ":" + (Boolean.parseBoolean(values[index + 2]) ? "1" : "0"));
        }
        return lines;
    }

    private static List<String> previous(String start, String end, boolean note) {
        return previous(start, end, Boolean.toString(note));
    }

    private static Map<String, String> run(
        Fakes.SDK sdk,
        List<String> payload,
        List<String> prior
    ) throws Exception {
        payload.addAll(prior);
        String requestId = value(payload, "request_id");
        Path path = Paths.get("/tmp/goodreads-annotations-" + requestId + ".properties");
        Path result = Paths.get("/tmp/goodreads-annotation-result-" + requestId + ".log");
        Files.write(path, payload, StandardCharsets.ISO_8859_1);
        Files.deleteIfExists(result);
        GoodreadsAnnotationAgentV29.agentmain(path.toString(), null);
        expect(false, Files.exists(path), "agent must remove payload after loading it");
        Map<String, String> fields = readResult(result);
        Files.deleteIfExists(result);
        if (fields.containsKey("asin") || fields.containsKey("request_id")) {
            expect(ASIN, fields.get("asin"), "result ASIN should match");
            expect(requestId, fields.get("request_id"), "result request should match");
        } else {
            expect("false", fields.get("success"), "only pre-correlation validation failures may omit IDs");
        }
        return fields;
    }

    private static Map<String, String> readResult(Path result) throws Exception {
        Map<String, String> fields = new HashMap<String, String>();
        for (String line : Files.readAllLines(result, StandardCharsets.UTF_8)) {
            int separator = line.indexOf('=');
            if (separator > 0) {
                fields.put(line.substring(0, separator), line.substring(separator + 1));
            }
        }
        return fields;
    }

    private static Note findNote(Fakes.SDK sdk) {
        for (Object annotation : sdk.content.manager.annotations) {
            if (annotation instanceof Note) {
                return (Note) annotation;
            }
        }
        throw new AssertionError("native note not found");
    }

    private static String value(List<String> lines, String key) {
        String prefix = key + "=";
        for (String line : lines) {
            if (line.startsWith(prefix)) {
                return line.substring(prefix.length());
            }
        }
        throw new IllegalArgumentException("missing " + key);
    }

    private static String hex(String value) {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        StringBuilder encoded = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) {
            encoded.append(String.format("%02x", item & 0xff));
        }
        return encoded.toString();
    }

    private static void expect(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + " actual=" + actual);
        }
    }
}
