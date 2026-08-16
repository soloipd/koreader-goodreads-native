import com.amazon.kindle.content.journal.JournalAction;
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

public final class BackgroundAnnotationCanaryAgentV1Test {
    private static final String ASIN = "B0FLB24198";
    private static final String PATH = "/mnt/us/documents/Test_B0FLB24198.kfx";
    private static final String START = "AAAAAAAAAAAA";
    private static final String END = "AAAAAAAAAAAB";
    private static int request = 20000000;

    private BackgroundAnnotationCanaryAgentV1Test() {}

    public static void main(String[] ignored) throws Exception {
        Fakes.SDK sdk = new Fakes.SDK();
        Framework.setService(sdk);

        Map<String, String> validated = run("validate", false);
        expect("true", validated.get("success"), "validation should pass");
        expect("false", validated.get("mutation_attempted"),
            "validation must be read-only");
        expect(0, sdk.journaling.entries.size(), "validation must not journal");
        expect(0, sdk.whisperSync.requests, "validation must not upload");

        Map<String, String> created = run("create", true);
        expect("true", created.get("success"), "create should pass: " + created);
        expect("true", created.get("journal_entry_accepted"),
            "create journal entry should be accepted");
        expect("true", created.get("upload_requested"),
            "create should request WhisperSync");
        expect("true", created.get("canary_state_present"),
            "create must retain exact rollback state");
        expect(1, sdk.journaling.entries.size(), "create should journal exactly once");
        expect(JournalAction.gbb, sdk.journaling.entries.get(0).action,
            "first journal action should be CREATE");
        expect(1, sdk.whisperSync.requests, "create should request one upload");
        expect(0, sdk.content.manager.annotations.size(),
            "background canary must not mutate detached local annotation state");

        Map<String, String> status = run("status", false);
        expect("true", status.get("success"), "status should pass");
        expect("true", status.get("canary_state_present"),
            "status must observe rollback state");
        expect(1, sdk.journaling.entries.size(), "status must not journal");

        Map<String, String> deleted = run("delete", true);
        expect("true", deleted.get("success"), "delete should pass: " + deleted);
        expect("false", deleted.get("canary_state_present"),
            "delete must clear rollback state");
        expect(2, sdk.journaling.entries.size(), "delete should journal exactly once");
        expect(JournalAction.gbc, sdk.journaling.entries.get(1).action,
            "second journal action should be DELETE");
        expect(2, sdk.whisperSync.requests, "delete should request one more upload");
        expect(0, sdk.content.manager.annotations.size(),
            "delete must not mutate detached local annotation state");

        sdk.activeBook = new Fakes.Book();
        Map<String, String> rejected = run("create", true);
        expect("false", rejected.get("success"),
            "writes must be rejected while a native book is active");
        expect("resolve_services", rejected.get("failed_stage"),
            "active-book rejection should happen before detached open");
        expect(2, sdk.journaling.entries.size(), "rejection must not journal");

        System.out.println("Background annotation canary tests passed.");
    }

    private static Map<String, String> run(String mode, boolean confirm) throws Exception {
        String id = Integer.toString(++request);
        Path payload = Paths.get("/tmp/goodreads-background-canary-" + id + ".properties");
        Path result = Paths.get(
            "/tmp/goodreads-background-canary-result-" + id + ".log");
        List<String> lines = new ArrayList<String>();
        lines.add("version=1");
        lines.add("request_id=" + id);
        lines.add("mode=" + mode);
        lines.add("asin=" + ASIN);
        lines.add("native_path_hex=" + hex(PATH));
        lines.add("start=" + START);
        lines.add("start_short=100");
        lines.add("end=" + END);
        lines.add("end_short=200");
        if (confirm) lines.add("confirm=BACKGROUND_CANARY_V1");
        Files.write(payload, lines, StandardCharsets.ISO_8859_1);
        Files.deleteIfExists(result);
        BackgroundAnnotationCanaryAgentV1.agentmain(payload.toString(), null);
        expect(false, Files.exists(payload), "agent must consume its payload");
        Map<String, String> values = new HashMap<String, String>();
        for (String line : Files.readAllLines(result, StandardCharsets.UTF_8)) {
            int separator = line.indexOf('=');
            if (separator > 0) values.put(
                line.substring(0, separator), line.substring(separator + 1));
        }
        Files.deleteIfExists(result);
        return values;
    }

    private static String hex(String value) {
        StringBuilder result = new StringBuilder();
        for (byte item : value.getBytes(StandardCharsets.UTF_8)) {
            result.append(String.format("%02x", Integer.valueOf(item & 0xff)));
        }
        return result.toString();
    }

    private static void expect(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + " actual=" + actual);
        }
    }
}
