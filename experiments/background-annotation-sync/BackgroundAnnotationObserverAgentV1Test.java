import com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight;
import com.amazon.kindle.restricted.runtime.Framework;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;
import testsupport.Fakes;

public final class BackgroundAnnotationObserverAgentV1Test {
    private BackgroundAnnotationObserverAgentV1Test() {}

    public static void main(String[] ignored) throws Exception {
        Fakes.SDK sdk = new Fakes.SDK();
        sdk.activeBook = new Fakes.Book();
        sdk.content.manager.annotations.add(new Highlight(
            new Fakes.Position("AAAAAAAAAAAA", 100),
            new Fakes.Position("AAAAAAAAAAAB", 200)));
        Framework.setService(sdk);
        Map<String, String> result = run();
        expect("true", result.get("success"), "observer should succeed");
        expect("1", result.get("native_highlights"), "highlight count should match");
        expect("1", result.get("canary_matches"), "exact canary should match once");
        expect("true", result.get("canary_present"), "canary should be present");
        expect("false", result.get("mutation_attempted"), "observer must be read-only");
        expect(1, sdk.content.manager.annotations.size(), "observer must not mutate state");
        System.out.println("Background annotation observer tests passed.");
    }

    private static Map<String, String> run() throws Exception {
        String id = "30000001";
        Path payload = Paths.get("/tmp/goodreads-background-observer-" + id + ".properties");
        Path result = Paths.get("/tmp/goodreads-background-observer-result-" + id + ".log");
        Files.write(payload, java.util.Arrays.asList(
            "version=1", "request_id=" + id, "asin=B0FLB24198",
            "native_path_hex=" + hex("/mnt/us/documents/Test_B0FLB24198.kfx"),
            "start=AAAAAAAAAAAA", "end=AAAAAAAAAAAB"),
            StandardCharsets.ISO_8859_1);
        Files.deleteIfExists(result);
        BackgroundAnnotationObserverAgentV1.agentmain(payload.toString(), null);
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
        for (byte item : value.getBytes(StandardCharsets.UTF_8))
            result.append(String.format("%02x", Integer.valueOf(item & 0xff)));
        return result.toString();
    }
    private static void expect(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual))
            throw new AssertionError(message + ": expected=" + expected + " actual=" + actual);
    }
}
