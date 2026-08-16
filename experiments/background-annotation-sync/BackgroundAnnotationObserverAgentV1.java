import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;
import java.util.Properties;

/** Read-only exact-range observer for the experimental canary. */
public final class BackgroundAnnotationObserverAgentV1 {
    private static final String PREFIX = "/tmp/goodreads-background-observer-";
    private static final String SUFFIX = ".properties";

    private BackgroundAnnotationObserverAgentV1() {}

    public static void agentmain(String payloadPath, Instrumentation ignored) {
        PrintWriter out;
        try { out = new PrintWriter(new FileWriter(resultPath(payloadPath), false)); }
        catch (Throwable error) { return; }
        String stage = "validate_payload";
        try {
            Properties payload = loadPayload(payloadPath);
            String requestId = requireRequestId(payload.getProperty("request_id"));
            String asin = requireAsin(payload.getProperty("asin"));
            String nativePath = requireNativePath(decodeHex(
                payload.getProperty("native_path_hex", "")));
            String start = requireLong(payload.getProperty("start"));
            String end = requireLong(payload.getProperty("end"));
            if (!payloadPath.equals(PREFIX + requestId + SUFFIX))
                throw new IllegalArgumentException("request ID does not match path");
            out.println("request_id=" + requestId);

            stage = "resolve_active_book";
            Class<?> framework = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework");
            Class<?> readerType = Class.forName(
                "com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Object reader = framework.getMethod("getService", Class.class)
                .invoke(null, readerType);
            if (reader == null) throw new IllegalStateException("ReaderSDK unavailable");
            Object book = reader.getClass().getMethod("jy").invoke(reader);
            out.println("native_book_active=" + (book != null));
            if (!bookMatches(book, asin, nativePath))
                throw new IllegalStateException("exact native book is not active");
            out.println("exact_book_active=true");

            stage = "read_annotations";
            Object content = reader.getClass().getMethod("jE").invoke(reader);
            Object manager = content.getClass().getMethod("xA").invoke(content);
            Object listed = invokeCompatible(manager, "Q", book);
            List<?> annotations = listed instanceof List
                ? (List<?>) listed : Collections.emptyList();
            int highlights = 0, notes = 0, canary = 0;
            String target = pair(start, end);
            for (Object annotation : annotations) {
                int type = ((Integer) annotation.getClass().getMethod("jm")
                    .invoke(annotation)).intValue();
                if (type == 1) highlights++;
                if (type == 2) notes++;
                if (type != 1) continue;
                Object annotationStart = annotation.getClass().getMethod("jh")
                    .invoke(annotation);
                Object annotationEnd = annotation.getClass().getMethod("jd")
                    .invoke(annotation);
                String actual = pair(
                    String.valueOf(annotationStart.getClass().getMethod("nX")
                        .invoke(annotationStart)),
                    String.valueOf(annotationEnd.getClass().getMethod("nX")
                        .invoke(annotationEnd)));
                if (target.equals(actual)) canary++;
            }
            out.println("native_highlights=" + highlights);
            out.println("native_notes=" + notes);
            out.println("canary_matches=" + canary);
            out.println("canary_present=" + (canary == 1));
            out.println("mutation_attempted=false");
            out.println("success=true");
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            out.println("mutation_attempted=false");
            out.println("success=false");
            out.println("failed_stage=" + stage);
            out.println("error_class=" + cause.getClass().getName());
        } finally { out.close(); }
    }

    private static Properties loadPayload(String path) throws Exception {
        if (path == null || !path.matches(
                "^/tmp/goodreads-background-observer-[0-9]{8,32}\\.properties$"))
            throw new IllegalArgumentException("invalid payload path");
        File file = new File(path);
        if (!file.isFile() || file.length() < 1 || file.length() > 8192)
            throw new IllegalArgumentException("invalid payload file");
        Properties value = new Properties();
        FileInputStream input = new FileInputStream(file);
        try { value.load(input); } finally { input.close(); }
        if (!file.delete() && file.exists())
            throw new IllegalStateException("cannot remove payload");
        if (!"1".equals(value.getProperty("version")))
            throw new IllegalArgumentException("unsupported payload version");
        return value;
    }

    private static String resultPath(String payloadPath) {
        if (payloadPath == null || !payloadPath.startsWith(PREFIX)
                || !payloadPath.endsWith(SUFFIX))
            throw new IllegalArgumentException("invalid payload path");
        return "/tmp/goodreads-background-observer-result-"
            + payloadPath.substring(PREFIX.length(), payloadPath.length() - SUFFIX.length())
            + ".log";
    }

    private static Object invokeCompatible(Object target, String name, Object... args)
            throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(name)
                    || method.getParameterTypes().length != args.length) continue;
            boolean compatible = true;
            for (int i = 0; i < args.length; i++) {
                if (args[i] == null
                        || !method.getParameterTypes()[i].isAssignableFrom(args[i].getClass()))
                    compatible = false;
            }
            if (compatible) return method.invoke(target, args);
        }
        throw new NoSuchMethodException(name);
    }

    private static boolean bookMatches(Object book, String asin, String path) {
        if (book == null) return false;
        try {
            Object metadata = book.getClass().getMethod("jg").invoke(book);
            return asin.equals(String.valueOf(metadata.getClass().getMethod("getCdeKey")
                .invoke(metadata)))
                && path.equals(String.valueOf(book.getClass().getMethod("getPath")
                    .invoke(book)));
        } catch (Throwable error) { return false; }
    }
    private static String pair(String first, String second) {
        return first.compareTo(second) <= 0 ? first + ":" + second
            : second + ":" + first;
    }
    private static String requireRequestId(String value) {
        if (value == null || !value.matches("^[0-9]{8,32}$"))
            throw new IllegalArgumentException("invalid request ID");
        return value;
    }
    private static String requireAsin(String value) {
        if (value == null || !value.matches("^B[A-Z0-9]{9}$"))
            throw new IllegalArgumentException("invalid ASIN");
        return value;
    }
    private static String requireNativePath(String value) throws Exception {
        if (value == null || !value.startsWith("/mnt/us/documents/")
                || !value.toLowerCase(java.util.Locale.ROOT).endsWith(".kfx"))
            throw new IllegalArgumentException("invalid native path");
        String path = new File(value).getCanonicalPath();
        if (!path.startsWith("/mnt/us/documents/"))
            throw new IllegalArgumentException("native path outside documents");
        return path;
    }
    private static String requireLong(String value) {
        if (value == null || !value.matches("^A[A-Za-z0-9+/]{11}$"))
            throw new IllegalArgumentException("invalid long position");
        return value;
    }
    private static String decodeHex(String value) {
        if (value == null || value.length() > 4096 || (value.length() & 1) != 0
                || !value.matches("^[0-9A-Fa-f]*$"))
            throw new IllegalArgumentException("invalid hex");
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++)
            bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        return new String(bytes, StandardCharsets.UTF_8);
    }
    private static Throwable unwrap(Throwable error) {
        Throwable value = error;
        while (value instanceof InvocationTargetException
                && ((InvocationTargetException) value).getCause() != null)
            value = ((InvocationTargetException) value).getCause();
        return value;
    }
}
