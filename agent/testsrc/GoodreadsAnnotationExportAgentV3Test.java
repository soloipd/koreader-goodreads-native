import com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight;
import com.amazon.ebook.booklet.reader.impl.annotation.personal.Note;
import com.amazon.kindle.restricted.runtime.Framework;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;
import testsupport.Fakes;

public final class GoodreadsAnnotationExportAgentV3Test {
    private static int sequence = 8100000;

    private GoodreadsAnnotationExportAgentV3Test() {}

    public static void main(String[] ignored) throws Exception {
        Fakes.SDK sdk = new Fakes.SDK();
        sdk.activeBook = new Fakes.Book("test-guid");
        Framework.setService(sdk);
        Fakes.Position start = new Fakes.Position("AAAAAAAAAAAA", 100);
        Fakes.Position end = new Fakes.Position("AAAAAAAAAAAB", 200);
        sdk.content.manager.annotations.add(new Highlight(start, end));
        sdk.content.manager.annotations.add(new Note("private note", start, end));
        Fakes.Position nearbyStart = new Fakes.Position("AAAAAAAAAAAA", 101);
        Fakes.Position nearbyEnd = new Fakes.Position("AAAAAAAAAAAB", 201);
        sdk.content.manager.annotations.add(new Highlight(nearbyStart, nearbyEnd));
        sdk.content.manager.annotations.add(new Note("nearby note", nearbyStart, nearbyEnd));
        sdk.content.manager.annotations.add(new Highlight(
            new Fakes.Position("AAAAAAAAAAAC", 300),
            new Fakes.Position("AAAAAAAAAAAD", 400)));

        Properties exported = run("/mnt/us/documents/Test_B0FLB24198.kfx");
        expect("true", exported.getProperty("success"), "export should succeed");
        expect("true", exported.getProperty("snapshot_complete"),
            "completed export must attest snapshot completeness");
        expect("3", exported.getProperty("count"),
            "only exact highlight/note pairs should collapse");
        expect("AAAAAAAAAAAA", exported.getProperty("item.0.start"), "start should be exact");
        expect("100", exported.getProperty("item.0.start_short"), "short start should be exact");
        expect("private note", decodeHex(exported.getProperty("item.0.note_hex")),
            "note should remain private but round trip intact");
        expect("101", exported.getProperty("item.1.start_short"),
            "nearby range with the same coarse start must remain distinct");
        expect("201", exported.getProperty("item.1.end_short"),
            "nearby range with the same coarse end must remain distinct");
        expect("nearby note", decodeHex(exported.getProperty("item.1.note_hex")),
            "a nearby note must remain attached to its exact range");
        expect(5, sdk.content.manager.annotations.size(), "read-only export must not mutate annotations");
        expect(0, sdk.proxy.operations.size(), "read-only export must not notify the native writer");
        expect(0, sdk.journaling.entries.size(), "read-only export must not journal");
        expect(0, sdk.whisperSync.requests, "read-only export must not request cloud sync");

        Properties activeSnapshot = runActiveSnapshot();
        expect("true", activeSnapshot.getProperty("success"),
            "active snapshot export should succeed without caller-supplied identity");
        expect("B0FLB24198", activeSnapshot.getProperty("asin"),
            "active snapshot must report the native identity");
        expect("/mnt/us/documents/Test_B0FLB24198.kfx",
            decodeHex(activeSnapshot.getProperty("native_path_hex")),
            "active snapshot must report the exact local path");

        Properties mismatch = run("/mnt/us/documents/Other_B0FLB24198.kfx");
        expect("false", mismatch.getProperty("success"), "wrong path must fail closed");
        expect("require_exact_active_book", mismatch.getProperty("failed_stage"),
            "identity mismatch must be explicit");
        expect(5, sdk.content.manager.annotations.size(), "failed export must not mutate annotations");
        System.out.println("Annotation export agent behavior tests passed.");
    }

    private static Properties run(String nativePath) throws Exception {
        return runPayload("exact", nativePath);
    }

    private static Properties runActiveSnapshot() throws Exception {
        return runPayload("active_snapshot", null);
    }

    private static Properties runPayload(String mode, String nativePath) throws Exception {
        String requestId = String.valueOf(sequence++);
        Path payloadPath = Paths.get("/tmp/goodreads-native-export-" + requestId + ".properties");
        Path resultPath = Paths.get("/tmp/goodreads-native-export-" + requestId + ".result");
        Properties payload = new Properties();
        payload.setProperty("request_id", requestId);
        payload.setProperty("mode", mode);
        if (nativePath != null) {
            payload.setProperty("asin", "B0FLB24198");
            payload.setProperty("native_path_hex", hexEncode(nativePath));
        }
        FileOutputStream output = new FileOutputStream(payloadPath.toFile());
        payload.store(output, null);
        output.close();
        GoodreadsAnnotationExportAgentV3.agentmain(payloadPath.toString(), null);
        Properties result = new Properties();
        FileInputStream input = new FileInputStream(resultPath.toFile());
        result.load(input);
        input.close();
        Files.deleteIfExists(resultPath);
        expect(false, Files.exists(payloadPath), "agent must remove its private request");
        return result;
    }

    private static String hexEncode(String value) {
        StringBuilder result = new StringBuilder();
        for (byte item : value.getBytes(StandardCharsets.UTF_8)) {
            result.append(String.format("%02x", Integer.valueOf(item & 0xff)));
        }
        return result.toString();
    }

    private static String decodeHex(String value) {
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static void expect(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + " actual=" + actual);
        }
    }
}
