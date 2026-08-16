import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

/** Reconciles KOReader highlights with the native Kindle annotation store. */
public final class GoodreadsAnnotationAgentV4 {
    private GoodreadsAnnotationAgentV4() {}

    public static void agentmain(String payloadPath, Instrumentation instrumentation) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(resultPath(payloadPath), false));
        } catch (Throwable ignored) {
            return;
        }

        Object book = null;
        String stage = "validate_payload";
        Counters counters = new Counters();
        try {
            Properties payload = loadPayload(payloadPath);
            String asin = requireAsin(payload.getProperty("asin"));
            String requestId = requireRequestId(payload.getProperty("request_id"));
            if (!payloadPath.equals("/tmp/goodreads-annotations-" + requestId + ".properties")) {
                throw new IllegalArgumentException("request ID does not match payload path");
            }
            String nativePath = requireNativePath(decodeHex(payload.getProperty("native_path_hex", "")));
            List<Record> desired = readRecords(payload, "desired");
            Map<String, Boolean> previous = readPrevious(payload, "previous");
            out.println("asin=" + asin);
            out.println("request_id=" + requestId);
            out.println("requested=" + desired.size());

            stage = "resolve_reader_sdk";
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            Class<?> readerSdkType = Class.forName("com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Object readerSdk = framework.getMethod("getService", Class.class).invoke(null, readerSdkType);
            if (readerSdk == null) {
                throw new IllegalStateException("ReaderSDK unavailable");
            }
            Object contentSdk = readerSdk.getClass().getMethod("jE").invoke(readerSdk);

            stage = "open_book";
            book = invokeCompatible(contentSdk, "dt", nativePath);
            if (book == null) {
                throw new IllegalStateException("native book unavailable");
            }

            stage = "load_annotations";
            Object manager = contentSdk.getClass().getMethod("xA").invoke(contentSdk);
            Object listed = invokeCompatible(manager, "Q", book);
            List<?> annotations = listed instanceof List ? (List<?>) listed : Collections.emptyList();
            Map<String, Object> existing = indexAnnotations(annotations);

            stage = "reconcile_annotations";
            Set<String> desiredKeys = new HashSet<String>();
            for (Record record : desired) {
                desiredKeys.add(record.rangeKey());
                Object start = makePosition(contentSdk, book, record.startLong);
                Object end = makePosition(contentSdk, book, record.endLong);
                String highlightKey = typedKey(1, record.startLong, record.endLong);
                Object highlight = existing.get(highlightKey);
                if (highlight == null) {
                    highlight = construct(
                        "com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight",
                        start,
                        end
                    );
                    if (!invokeBoolean(manager, "c", highlight, book)) {
                        throw new IllegalStateException("native highlight create rejected");
                    }
                    existing.put(highlightKey, highlight);
                    counters.highlightsCreated++;
                } else {
                    // Some Kindle content engines return persisted annotation
                    // endpoints in the opposite order from the translated
                    // KOReader range. Use the native object's ordering when
                    // attaching a note so the manager accepts it.
                    start = highlight.getClass().getMethod("jh").invoke(highlight);
                    end = highlight.getClass().getMethod("jd").invoke(highlight);
                }

                String noteKey = typedKey(2, record.startLong, record.endLong);
                Object note = existing.get(noteKey);
                if (record.note.length() > 0) {
                    if (note == null) {
                        note = construct(
                            "com.amazon.ebook.booklet.reader.impl.annotation.personal.Note",
                            record.note,
                            start,
                            end
                        );
                        if (!invokeBoolean(manager, "c", note, book)) {
                            throw new IllegalStateException("native note create rejected");
                        }
                        existing.put(noteKey, note);
                        counters.notesCreated++;
                    } else {
                        String oldText = String.valueOf(note.getClass().getMethod("getText").invoke(note));
                        if (!record.note.equals(oldText)) {
                            note.getClass().getMethod("setText", String.class).invoke(note, record.note);
                            if (!invokeBoolean(manager, "e", note, book)) {
                                throw new IllegalStateException("native note update rejected");
                            }
                            counters.notesUpdated++;
                        }
                    }
                } else if (note != null && Boolean.TRUE.equals(previous.get(record.rangeKey()))) {
                    if (!invokeBoolean(manager, "d", note, book)) {
                        throw new IllegalStateException("native note delete rejected");
                    }
                    existing.remove(noteKey);
                    counters.notesDeleted++;
                }
            }

            for (Map.Entry<String, Boolean> oldEntry : previous.entrySet()) {
                String oldRange = oldEntry.getKey();
                if (desiredKeys.contains(oldRange)) {
                    continue;
                }
                String[] positions = splitRangeKey(oldRange);
                if (oldEntry.getValue().booleanValue()) {
                    deleteExisting(existing, manager, book, 2, positions[0], positions[1], counters);
                }
                deleteExisting(existing, manager, book, 1, positions[0], positions[1], counters);
            }

            // f/g/h only mutate AnnotationCacheImpl. The native reader uses
            // c/d/e so the KSDK dual-write proxy also receives each change.
            // Refuse success until a fresh Book can see the requested state.
            stage = "verify_native_annotations";
            book.getClass().getMethod("close").invoke(book);
            book = invokeCompatible(contentSdk, "dt", nativePath);
            if (book == null) {
                throw new IllegalStateException("native book unavailable during verification");
            }
            Object verifiedListed = invokeCompatible(manager, "Q", book);
            List<?> verifiedAnnotations = verifiedListed instanceof List
                ? (List<?>) verifiedListed : Collections.emptyList();
            Map<String, Object> verified = indexAnnotations(verifiedAnnotations);
            verifyDesired(verified, desired);
            verifyDeleted(verified, desiredKeys, previous);

            out.println("local_verified=true");
            out.println("success=true");
            counters.write(out);
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            out.println("success=false");
            out.println("failed_stage=" + stage);
            out.println("error_class=" + cause.getClass().getName());
            counters.write(out);
        } finally {
            if (book != null) {
                try {
                    book.getClass().getMethod("close").invoke(book);
                } catch (Throwable ignored) {
                    // Cleanup must not obscure a result already written.
                }
            }
            out.close();
        }
    }

    private static Properties loadPayload(String path) throws Exception {
        if (path == null || !path.matches("^/tmp/goodreads-annotations-[0-9]+\\.properties$")) {
            throw new IllegalArgumentException("invalid payload path");
        }
        File file = new File(path);
        if (!file.isFile() || file.length() < 1 || file.length() > 512 * 1024) {
            throw new IllegalArgumentException("invalid payload file");
        }
        Properties properties = new Properties();
        FileInputStream input = new FileInputStream(file);
        try {
            properties.load(input);
        } finally {
            input.close();
        }
        // The attached JVM, rather than the launching shell, owns request
        // deletion. Kindle's AttachLauncher may return before agentmain starts;
        // deleting from the shell creates a race with this first file open.
        if (!file.delete() && file.exists()) {
            throw new IllegalStateException("cannot remove consumed payload");
        }
        if (!"1".equals(properties.getProperty("version"))) {
            throw new IllegalArgumentException("unsupported payload version");
        }
        return properties;
    }

    private static String resultPath(String payloadPath) {
        if (payloadPath == null || !payloadPath.matches("^/tmp/goodreads-annotations-[0-9]+\\.properties$")) {
            throw new IllegalArgumentException("invalid payload path");
        }
        String requestId = payloadPath.substring(
            "/tmp/goodreads-annotations-".length(),
            payloadPath.length() - ".properties".length()
        );
        return "/tmp/goodreads-annotation-result-" + requestId + ".log";
    }

    private static List<Record> readRecords(Properties payload, String prefix) {
        int count = parseCount(payload.getProperty(prefix + "_count"));
        List<Record> records = new ArrayList<Record>();
        Set<String> unique = new HashSet<String>();
        for (int index = 0; index < count; index++) {
            String base = prefix + "." + index + ".";
            Record record = new Record(
                requireLongPosition(payload.getProperty(base + "start")),
                requireLongPosition(payload.getProperty(base + "end")),
                decodeHex(payload.getProperty(base + "note_hex", ""))
            );
            if (!unique.add(record.rangeKey())) {
                throw new IllegalArgumentException("duplicate annotation range");
            }
            records.add(record);
        }
        return records;
    }

    private static Map<String, Boolean> readPrevious(Properties payload, String prefix) {
        int count = parseCount(payload.getProperty(prefix + "_count"));
        Map<String, Boolean> keys = new HashMap<String, Boolean>();
        for (int index = 0; index < count; index++) {
            String value = payload.getProperty(prefix + "." + index);
            int separator = value == null ? -1 : value.lastIndexOf(':');
            if (separator < 1 || separator == value.length() - 1) {
                throw new IllegalArgumentException("invalid previous annotation state");
            }
            String range = value.substring(0, separator);
            String noteFlag = value.substring(separator + 1);
            String[] positions = splitRangeKey(range);
            if (!"0".equals(noteFlag) && !"1".equals(noteFlag)) {
                throw new IllegalArgumentException("invalid previous note state");
            }
            keys.put(pairKey(positions[0], positions[1]), Boolean.valueOf("1".equals(noteFlag)));
        }
        return keys;
    }

    private static Map<String, Object> indexAnnotations(List<?> annotations) throws Exception {
        Map<String, Object> indexed = new HashMap<String, Object>();
        for (Object annotation : annotations) {
            int type = ((Integer) annotation.getClass().getMethod("jm").invoke(annotation)).intValue();
            if (type != 1 && type != 2) {
                continue;
            }
            Object start = annotation.getClass().getMethod("jh").invoke(annotation);
            Object end = annotation.getClass().getMethod("jd").invoke(annotation);
            String startLong = String.valueOf(start.getClass().getMethod("nX").invoke(start));
            String endLong = String.valueOf(end.getClass().getMethod("nX").invoke(end));
            indexed.put(typedKey(type, startLong, endLong), annotation);
        }
        return indexed;
    }

    private static Object makePosition(Object contentSdk, Object book, String encoded) throws Exception {
        Object factory = invokeCompatible(contentSdk, "E", book);
        return invokeCompatible(factory, "a", encoded, book);
    }

    private static void deleteExisting(
        Map<String, Object> existing,
        Object manager,
        Object book,
        int type,
        String start,
        String end,
        Counters counters
    ) throws Exception {
        String key = typedKey(type, start, end);
        Object annotation = existing.get(key);
        if (annotation == null) {
            return;
        }
        if (!invokeBoolean(manager, "d", annotation, book)) {
            throw new IllegalStateException("native annotation delete rejected");
        }
        existing.remove(key);
        if (type == 1) {
            counters.highlightsDeleted++;
        } else {
            counters.notesDeleted++;
        }
    }

    private static void verifyDesired(Map<String, Object> existing, List<Record> desired)
            throws Exception {
        for (Record record : desired) {
            if (!existing.containsKey(typedKey(1, record.startLong, record.endLong))) {
                throw new IllegalStateException("native highlight durability check failed");
            }
            Object note = existing.get(typedKey(2, record.startLong, record.endLong));
            if (record.note.length() == 0) {
                if (note != null) {
                    throw new IllegalStateException("native note removal durability check failed");
                }
            } else {
                if (note == null) {
                    throw new IllegalStateException("native note durability check failed");
                }
                String text = String.valueOf(note.getClass().getMethod("getText").invoke(note));
                if (!record.note.equals(text)) {
                    throw new IllegalStateException("native note text durability check failed");
                }
            }
        }
    }

    private static void verifyDeleted(
        Map<String, Object> existing,
        Set<String> desiredKeys,
        Map<String, Boolean> previous
    ) {
        for (String oldRange : previous.keySet()) {
            if (desiredKeys.contains(oldRange)) {
                continue;
            }
            String[] positions = splitRangeKey(oldRange);
            if (existing.containsKey(typedKey(1, positions[0], positions[1]))
                    || existing.containsKey(typedKey(2, positions[0], positions[1]))) {
                throw new IllegalStateException("native annotation deletion durability check failed");
            }
        }
    }

    private static Object construct(String className, Object... arguments) throws Exception {
        Class<?> type = Class.forName(className);
        for (Constructor<?> constructor : type.getConstructors()) {
            Class<?>[] parameters = constructor.getParameterTypes();
            if (compatible(parameters, arguments)) {
                return constructor.newInstance(arguments);
            }
        }
        throw new NoSuchMethodException(className + " constructor");
    }

    private static Object invokeCompatible(Object target, String name, Object... arguments) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (method.getName().equals(name) && compatible(method.getParameterTypes(), arguments)) {
                return method.invoke(target, arguments);
            }
        }
        throw new NoSuchMethodException(name);
    }

    private static boolean invokeBoolean(Object target, String name, Object... arguments) throws Exception {
        Object value = invokeCompatible(target, name, arguments);
        return value instanceof Boolean && ((Boolean) value).booleanValue();
    }

    private static boolean compatible(Class<?>[] parameters, Object[] arguments) {
        if (parameters.length != arguments.length) {
            return false;
        }
        for (int index = 0; index < parameters.length; index++) {
            if (arguments[index] == null || !parameters[index].isAssignableFrom(arguments[index].getClass())) {
                return false;
            }
        }
        return true;
    }

    private static int parseCount(String value) {
        int count = Integer.parseInt(value == null ? "0" : value);
        if (count < 0 || count > 1000) {
            throw new IllegalArgumentException("invalid annotation count");
        }
        return count;
    }

    private static String requireAsin(String value) {
        if (value == null || !value.matches("^B[A-Z0-9]{9}$")) {
            throw new IllegalArgumentException("invalid ASIN");
        }
        return value;
    }

    private static String requireRequestId(String value) {
        if (value == null || !value.matches("^[0-9]{8,32}$")) {
            throw new IllegalArgumentException("invalid request ID");
        }
        return value;
    }

    private static String requireNativePath(String value) throws Exception {
        String lower = value == null ? "" : value.toLowerCase(java.util.Locale.ROOT);
        boolean supported = lower.endsWith(".kfx") || lower.endsWith(".azw")
            || lower.endsWith(".azw3") || lower.endsWith(".mobi") || lower.endsWith(".prc");
        if (value == null || !value.startsWith("/mnt/us/documents/") || !supported
                || value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0) {
            throw new IllegalArgumentException("invalid native book path");
        }
        String canonical = new File(value).getCanonicalPath();
        if (!canonical.startsWith("/mnt/us/documents/")) {
            throw new IllegalArgumentException("native book path is outside documents");
        }
        return canonical;
    }

    private static String requireLongPosition(String value) {
        if (value == null || !value.matches("^A[A-Za-z0-9+/]{11}$")) {
            throw new IllegalArgumentException("invalid KFX long position");
        }
        return value;
    }

    private static String decodeHex(String value) {
        if (value.length() > 131072 || (value.length() & 1) != 0 || !value.matches("^[0-9A-Fa-f]*$")) {
            throw new IllegalArgumentException("invalid note encoding");
        }
        byte[] bytes = new byte[value.length() / 2];
        for (int index = 0; index < bytes.length; index++) {
            bytes[index] = (byte) Integer.parseInt(value.substring(index * 2, index * 2 + 2), 16);
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static String typedKey(int type, String start, String end) {
        return type + ":" + pairKey(start, end);
    }

    private static String pairKey(String start, String end) {
        return start.compareTo(end) <= 0 ? start + ":" + end : end + ":" + start;
    }

    private static String[] splitRangeKey(String value) {
        if (value == null) {
            throw new IllegalArgumentException("missing annotation key");
        }
        int separator = value.indexOf(':');
        if (separator < 1 || separator != value.lastIndexOf(':')) {
            throw new IllegalArgumentException("invalid annotation key");
        }
        String start = requireLongPosition(value.substring(0, separator));
        String end = requireLongPosition(value.substring(separator + 1));
        return new String[] { start, end };
    }

    private static Throwable unwrap(Throwable error) {
        Throwable current = error;
        while (current instanceof InvocationTargetException
                && ((InvocationTargetException) current).getCause() != null) {
            current = ((InvocationTargetException) current).getCause();
        }
        return current;
    }

    private static final class Record {
        private final String startLong;
        private final String endLong;
        private final String note;

        private Record(String startLong, String endLong, String note) {
            this.startLong = startLong;
            this.endLong = endLong;
            this.note = note;
        }

        private String rangeKey() {
            return pairKey(startLong, endLong);
        }
    }

    private static final class Counters {
        private int highlightsCreated;
        private int highlightsDeleted;
        private int notesCreated;
        private int notesUpdated;
        private int notesDeleted;

        private void write(PrintWriter out) {
            out.println("highlights_created=" + highlightsCreated);
            out.println("highlights_deleted=" + highlightsDeleted);
            out.println("notes_created=" + notesCreated);
            out.println("notes_updated=" + notesUpdated);
            out.println("notes_deleted=" + notesDeleted);
        }
    }
}
