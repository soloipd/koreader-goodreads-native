import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/** Read-only export of the exact active Kindle book's highlight/note ranges. */
public final class GoodreadsAnnotationExportAgentV2 {
    private GoodreadsAnnotationExportAgentV2() {}

    public static void agentmain(String payloadPath, Instrumentation ignored) {
        PrintWriter out = null;
        String stage = "validate_payload";
        try {
            Properties payload = loadPayload(payloadPath);
            String requestId = requireRequestId(payload.getProperty("request_id"));
            String expected = "/tmp/goodreads-native-export-" + requestId + ".properties";
            if (!expected.equals(payloadPath)) {
                throw new IllegalArgumentException("request ID does not match payload path");
            }
            String mode = payload.getProperty("mode", "exact");
            String expectedAsin = null;
            String expectedPath = null;
            if ("exact".equals(mode)) {
                expectedAsin = requireAsin(payload.getProperty("asin"));
                expectedPath = requireNativePath(decodeHex(
                    payload.getProperty("native_path_hex", "")));
            } else if (!"active_snapshot".equals(mode)) {
                throw new IllegalArgumentException("invalid export mode");
            }
            out = new PrintWriter(new FileWriter(resultPath(requestId), false));
            out.println("version=1");
            out.println("request_id=" + requestId);

            stage = "resolve_reader_sdk";
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            Class<?> sdkType = Class.forName("com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Object sdk = framework.getMethod("getService", Class.class).invoke(null, sdkType);
            if (sdk == null) throw new IllegalStateException("ReaderSDK unavailable");

            stage = "require_exact_active_book";
            Object book = sdk.getClass().getMethod("jy").invoke(sdk);
            String asin = activeAsin(book);
            String nativePath = activePath(book);
            if ("exact".equals(mode)
                    && (!expectedAsin.equals(asin) || !expectedPath.equals(nativePath))) {
                throw new IllegalStateException("requested native book is not active");
            }
            out.println("asin=" + asin);
            out.println("native_path_hex=" + hexEncode(nativePath));

            stage = "read_native_annotations";
            Object content = sdk.getClass().getMethod("jE").invoke(sdk);
            Object manager = content.getClass().getMethod("xA").invoke(content);
            Object listed = invokeCompatible(manager, "Q", book);
            List<?> annotations = listed instanceof List ? (List<?>) listed : Collections.emptyList();
            Map<String, ExportRecord> ranges = new LinkedHashMap<String, ExportRecord>();
            for (Object annotation : annotations) {
                int type = ((Integer) annotation.getClass().getMethod("jm").invoke(annotation)).intValue();
                if (type != 1 && type != 2) continue;
                Object start = annotation.getClass().getMethod("jh").invoke(annotation);
                Object end = annotation.getClass().getMethod("jd").invoke(annotation);
                ExportRecord candidate = ExportRecord.from(start, end);
                ExportRecord record = ranges.get(candidate.key());
                if (record == null) {
                    if (ranges.size() >= 1000) {
                        throw new IllegalStateException("native annotation limit exceeded");
                    }
                    record = candidate;
                    ranges.put(record.key(), record);
                }
                if (type == 2) {
                    Object noteValue = annotation.getClass().getMethod("getText").invoke(annotation);
                    String note = noteValue == null ? "" : String.valueOf(noteValue);
                    if (note.getBytes(StandardCharsets.UTF_8).length > 65536) {
                        throw new IllegalStateException("native note limit exceeded");
                    }
                    record.note = note;
                }
            }

            int noteBytes = 0;
            for (ExportRecord record : ranges.values()) {
                noteBytes += record.note.getBytes(StandardCharsets.UTF_8).length;
                if (noteBytes > 200 * 1024) {
                    throw new IllegalStateException("native note payload limit exceeded");
                }
            }
            out.println("count=" + ranges.size());
            int index = 0;
            for (ExportRecord record : ranges.values()) {
                String base = "item." + index++ + ".";
                out.println(base + "start=" + record.startLong);
                out.println(base + "start_short=" + record.startShort);
                out.println(base + "end=" + record.endLong);
                out.println(base + "end_short=" + record.endShort);
                out.println(base + "note_hex=" + hexEncode(record.note));
            }
            // Consumers may perform deletions only when this explicit marker
            // proves that enumeration, validation, and serialization finished.
            out.println("snapshot_complete=true");
            out.println("success=true");
        } catch (Throwable error) {
            if (out != null) {
                out.println("success=false");
                out.println("failed_stage=" + stage);
                out.println("error_class=" + error.getClass().getName());
            }
        } finally {
            if (out != null) out.close();
            new File(payloadPath).delete();
        }
    }

    private static Properties loadPayload(String path) throws Exception {
        Properties payload = new Properties();
        FileInputStream input = new FileInputStream(path);
        try { payload.load(input); } finally { input.close(); }
        return payload;
    }

    private static String resultPath(String requestId) {
        return "/tmp/goodreads-native-export-" + requestId + ".result";
    }

    private static Object invokeCompatible(Object target, String name, Object argument)
            throws Exception {
        for (Method method : target.getClass().getMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (method.getName().equals(name) && parameters.length == 1
                    && parameters[0].isAssignableFrom(argument.getClass())) {
                return method.invoke(target, argument);
            }
        }
        throw new NoSuchMethodException(target.getClass().getName() + "." + name);
    }

    private static String activeAsin(Object book) {
        if (book == null) throw new IllegalStateException("native book is not active");
        try {
            Object metadata = book.getClass().getMethod("jg").invoke(book);
            String cdeKey = String.valueOf(metadata.getClass().getMethod("getCdeKey").invoke(metadata));
            return requireAsin(cdeKey);
        } catch (RuntimeException error) {
            throw error;
        } catch (Throwable error) {
            throw new IllegalStateException("native book identity unavailable");
        }
    }

    private static String activePath(Object book) {
        if (book == null) throw new IllegalStateException("native book is not active");
        try {
            return requireNativePath(String.valueOf(
                book.getClass().getMethod("getPath").invoke(book)));
        } catch (RuntimeException error) {
            throw error;
        } catch (Throwable error) {
            throw new IllegalStateException("native book path unavailable");
        }
    }

    private static String requireAsin(String value) {
        if (value == null || !value.matches("B[A-Z0-9]{9}")) {
            throw new IllegalArgumentException("invalid ASIN");
        }
        return value;
    }

    private static String requireRequestId(String value) {
        if (value == null || !value.matches("[0-9]{1,32}")) {
            throw new IllegalArgumentException("invalid request ID");
        }
        return value;
    }

    private static String requireNativePath(String value) {
        if (value == null || !value.startsWith("/mnt/us/documents/") || value.length() > 4096) {
            throw new IllegalArgumentException("invalid native path");
        }
        if (value.indexOf('\0') >= 0 || value.indexOf('\n') >= 0
                || value.indexOf('\r') >= 0 || value.contains("/../")) {
            throw new IllegalArgumentException("invalid native path");
        }
        return value;
    }

    private static String decodeHex(String value) {
        if (value == null || (value.length() & 1) != 0 || !value.matches("[0-9a-f]*")) {
            throw new IllegalArgumentException("invalid hex encoding");
        }
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static String hexEncode(String value) {
        StringBuilder encoded = new StringBuilder();
        for (byte item : value.getBytes(StandardCharsets.UTF_8)) {
            encoded.append(String.format("%02x", Integer.valueOf(item & 0xff)));
        }
        return encoded.toString();
    }

    private static final class ExportRecord {
        private String startLong;
        private int startShort;
        private String endLong;
        private int endShort;
        private String note = "";

        private static ExportRecord from(Object start, Object end) throws Exception {
            ExportRecord record = new ExportRecord();
            record.startLong = requireLong(String.valueOf(start.getClass().getMethod("nX").invoke(start)));
            record.startShort = readShort(start);
            record.endLong = requireLong(String.valueOf(end.getClass().getMethod("nX").invoke(end)));
            record.endShort = readShort(end);
            if (record.startLong.compareTo(record.endLong) > 0) {
                String longSwap = record.startLong;
                int shortSwap = record.startShort;
                record.startLong = record.endLong;
                record.startShort = record.endShort;
                record.endLong = longSwap;
                record.endShort = shortSwap;
            }
            return record;
        }

        private String key() { return startLong + ":" + endLong; }

        private static int readShort(Object position) throws Exception {
            int value = ((Integer) position.getClass().getMethod("UF").invoke(position)).intValue();
            if (value < 0) throw new IllegalArgumentException("invalid short position");
            return value;
        }

        private static String requireLong(String value) {
            if (value == null || !value.matches("A[A-Za-z0-9+/]{11}")) {
                throw new IllegalArgumentException("invalid long position");
            }
            return value;
        }
    }
}
