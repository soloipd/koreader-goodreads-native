import com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight;
import com.amazon.ebook.booklet.reader.impl.annotation.personal.Note;
import com.amazon.kindle.restricted.runtime.Framework;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import testsupport.Fakes;

public final class GoodreadsAnnotationAgentV1Test {
    private static final String ASIN = "B0FLB24198";
    private static final String START = "AAAAAAAAAAAA";
    private static final String END = "AAAAAAAAAAAB";
    private static final String OTHER_START = "AAAAAAAAAAAC";
    private static final String OTHER_END = "AAAAAAAAAAAD";
    private static final Path RESULT = Paths.get("/tmp/goodreads-annotation-result.log");
    private static int requestSequence = 10000000;

    private GoodreadsAnnotationAgentV1Test() {}

    public static void main(String[] ignored) throws Exception {
        Fakes.SDK sdk = new Fakes.SDK();
        Framework.setService(sdk);

        Map<String, String> created = run(sdk, desired("first note"), previous());
        expect("true", created.get("success"), "create should succeed");
        expect("1", created.get("highlights_created"), "highlight should be created");
        expect("1", created.get("notes_created"), "note should be created");
        expect(2, sdk.content.manager.annotations.size(), "native store should contain highlight and note");
        expect(true, sdk.content.lastBook.closed, "native book should close after create");

        Map<String, String> updated = run(sdk, desired("edited note"), previous(START, END, true));
        expect("true", updated.get("success"), "note update should succeed");
        expect("1", updated.get("notes_updated"), "note should be updated");
        expect("edited note", findNote(sdk).getText(), "native note text should change");

        Map<String, String> noteRemoved = run(sdk, desired(""), previous(START, END, true));
        expect("true", noteRemoved.get("success"), "note removal should succeed");
        expect("1", noteRemoved.get("notes_deleted"), "owned note should be deleted");
        expect(1, sdk.content.manager.annotations.size(), "highlight should remain after note removal");

        Map<String, String> deleted = run(sdk, noDesired(), previous(START, END, false));
        expect("true", deleted.get("success"), "highlight deletion should succeed");
        expect("1", deleted.get("highlights_deleted"), "owned highlight should be deleted");
        expect(0, sdk.content.manager.annotations.size(), "owned range should be removed");

        Highlight nativeOnly = new Highlight(
            new Fakes.Position(OTHER_START),
            new Fakes.Position(OTHER_END)
        );
        sdk.content.manager.annotations.add(nativeOnly);
        Map<String, String> preserved = run(sdk, noDesired(), previous());
        expect("true", preserved.get("success"), "empty reconciliation should succeed");
        expect(1, sdk.content.manager.annotations.size(), "native-only highlight must be preserved");
        expect(nativeOnly, sdk.content.manager.annotations.get(0), "native-only object must be unchanged");

        int beforeMalformed = sdk.content.manager.annotations.size();
        List<String> malformed = basePayload();
        malformed.add("desired_count=1");
        malformed.add("desired.0.start=bad");
        malformed.add("desired.0.end=" + END);
        malformed.add("desired.0.note_hex=");
        malformed.add("previous_count=0");
        Map<String, String> rejected = run(sdk, malformed, previous());
        expect("false", rejected.get("success"), "malformed position must fail");
        expect("validate_payload", rejected.get("failed_stage"), "malformed input must fail before opening");
        expect(beforeMalformed, sdk.content.manager.annotations.size(), "malformed input must not mutate native state");

        Files.deleteIfExists(RESULT);
        System.out.println("Annotation agent behavior tests passed.");
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
        lines.add("desired.0.end=" + END);
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
        Files.write(path, payload, StandardCharsets.ISO_8859_1);
        Files.deleteIfExists(RESULT);
        GoodreadsAnnotationAgentV1.agentmain(path.toString(), null);
        Files.deleteIfExists(path);
        Map<String, String> result = readResult();
        if (result.containsKey("asin") || result.containsKey("request_id")) {
            expect(ASIN, result.get("asin"), "result ASIN should match");
            expect(requestId, result.get("request_id"), "result request should match");
        } else {
            expect("false", result.get("success"), "only pre-correlation validation failures may omit IDs");
        }
        return result;
    }

    private static Map<String, String> readResult() throws Exception {
        Map<String, String> fields = new HashMap<String, String>();
        for (String line : Files.readAllLines(RESULT, StandardCharsets.UTF_8)) {
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
