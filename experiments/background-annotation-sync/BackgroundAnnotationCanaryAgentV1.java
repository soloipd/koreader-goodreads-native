import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

/** Experimental journal-only canary. Never included in production packages. */
public final class BackgroundAnnotationCanaryAgentV1 {
    private static final String PREFIX = "/tmp/goodreads-background-canary-";
    private static final String SUFFIX = ".properties";
    private static final String CONFIRMATION = "BACKGROUND_CANARY_V1";
    private static CanaryState state;

    private BackgroundAnnotationCanaryAgentV1() {}

    public static synchronized void agentmain(String payloadPath, Instrumentation ignored) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(resultPath(payloadPath), false));
        } catch (Throwable error) {
            return;
        }
        Object detachedBook = null;
        String stage = "validate_payload";
        try {
            Properties payload = loadPayload(payloadPath);
            String mode = requireMode(payload.getProperty("mode"));
            String requestId = requireRequestId(payload.getProperty("request_id"));
            String asin = requireAsin(payload.getProperty("asin"));
            String nativePath = requireNativePath(decodeHex(
                payload.getProperty("native_path_hex", "")));
            String startLong = requireLong(payload.getProperty("start"));
            int startShort = requireShort(payload.getProperty("start_short"));
            String endLong = requireLong(payload.getProperty("end"));
            int endShort = requireShort(payload.getProperty("end_short"));
            if (!payloadPath.equals(PREFIX + requestId + SUFFIX)) {
                throw new IllegalArgumentException("request ID does not match path");
            }
            if (("create".equals(mode) || "delete".equals(mode))
                    && !CONFIRMATION.equals(payload.getProperty("confirm"))) {
                throw new IllegalArgumentException("write confirmation missing");
            }
            out.println("request_id=" + requestId);
            out.println("mode=" + mode);

            stage = "resolve_services";
            Class<?> framework = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework");
            Class<?> readerType = Class.forName(
                "com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Object reader = framework.getMethod("getService", Class.class)
                .invoke(null, readerType);
            if (reader == null) throw new IllegalStateException("ReaderSDK unavailable");
            Object activeBook = reader.getClass().getMethod("jy").invoke(reader);
            out.println("native_book_active=" + (activeBook != null));
            out.println("canary_state_present=" + (state != null));
            if ("status".equals(mode)) {
                out.println("mutation_attempted=false");
                out.println("success=true");
                return;
            }
            if (activeBook != null) {
                throw new IllegalStateException("native book must be inactive");
            }

            stage = "open_detached_book";
            Object content = reader.getClass().getMethod("jE").invoke(reader);
            detachedBook = invokeCompatible(content, "dt", nativePath);
            if (!bookMatches(detachedBook, asin, nativePath)) {
                throw new IllegalStateException("detached book identity mismatch");
            }
            out.println("detached_book_opened=true");

            stage = "validate_positions";
            Object factory = invokeCompatible(content, "E", detachedBook);
            Object start = invokeCompatible(factory, "a", startLong, detachedBook);
            Object end = invokeCompatible(factory, "a", endLong, detachedBook);
            if (!startLong.equals(invokeString(start, "nX"))
                    || !endLong.equals(invokeString(end, "nX"))
                    || readShort(start) != startShort || readShort(end) != endShort
                    || startShort >= endShort) {
                throw new IllegalStateException("canary position validation failed");
            }
            Object highlight = construct(
                "com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight",
                start, end);
            out.println("position_verified=true");
            if ("validate".equals(mode)) {
                out.println("mutation_attempted=false");
                out.println("success=true");
                return;
            }

            if ("create".equals(mode)) {
                if (state != null) throw new IllegalStateException("canary already exists");
            } else {
                if (state == null || !state.matches(asin, nativePath, startLong, endLong)) {
                    throw new IllegalStateException("matching in-memory canary unavailable");
                }
                highlight = state.annotation;
            }

            stage = "write_legacy_journal";
            journal(reader, highlight, detachedBook, nativePath,
                "create".equals(mode) ? "CREATE" : "DELETE");
            out.println("journal_entry_accepted=true");
            stage = "request_whispersync";
            requestUpload(reader);
            out.println("upload_requested=true");
            out.println("local_manager_mutated=false");
            out.println("mutation_attempted=true");
            if ("create".equals(mode)) {
                state = new CanaryState(asin, nativePath, startLong, endLong, highlight);
            } else {
                state = null;
            }
            out.println("canary_state_present=" + (state != null));
            out.println("success=true");
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            out.println("success=false");
            out.println("failed_stage=" + stage);
            out.println("error_class=" + cause.getClass().getName());
            out.println("canary_state_present=" + (state != null));
        } finally {
            if (detachedBook != null) invokeOptional(detachedBook, "close");
            out.close();
        }
    }

    private static void journal(Object reader, Object annotation, Object book,
            String nativePath, String operation) throws Exception {
        Object export = annotation.getClass().getMethod("Ci").invoke(annotation);
        Object sdkType = annotation.getClass().getMethod("CS").invoke(annotation);
        Class<?> annotationSync = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.AnnotationSync");
        Method mapper = null;
        for (Method method : annotationSync.getDeclaredMethods()) {
            if (method.getName().equals("a") && method.getParameterTypes().length == 1
                    && method.getParameterTypes()[0].getName().endsWith("annotation.JournalType")
                    && method.getReturnType().getName().endsWith("journal.JournalType")) {
                mapper = method;
            }
        }
        if (mapper == null) throw new IllegalStateException("journal mapper unavailable");
        mapper.setAccessible(true);
        Object journalType = mapper.invoke(null, sdkType);
        Class<?> actionType = Class.forName(
            "com.amazon.kindle.content.journal.JournalAction");
        Object action = actionType.getField("CREATE".equals(operation) ? "gbb" : "gbc")
            .get(null);
        Class<?> serviceType = Class.forName(
            "com.amazon.kindle.content.journal.JournalingService");
        Object service = invokeOptional(reader, "getService", serviceType);
        if (service == null) {
            Class<?> framework = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework");
            service = framework.getMethod("getService", Class.class)
                .invoke(null, serviceType);
        }
        if (service == null) throw new IllegalStateException("journal service unavailable");
        Object metadata = book.getClass().getMethod("jg").invoke(book);
        String cdeKey = invokeString(metadata, "getCdeKey");
        String cdeType = invokeString(metadata, "getCdeType");
        Integer version = (Integer) metadata.getClass().getMethod("getVersion").invoke(metadata);
        String guid = invokeString(metadata, "getGUID");
        int formatId = ((Integer) book.getClass().getMethod("jm").invoke(book)).intValue();
        String format = formatId == 0 ? "mobi7" : formatId == 1 ? "mobi8"
            : formatId == 2 ? "topaz" : formatId == 3 ? "pdf"
            : formatId == 4 ? "YJBinary" : null;
        if (format == null) throw new IllegalStateException("book format unavailable");
        Object journaledBook = invokeCompatible(service, "a", nativePath, cdeKey,
            cdeType, version, guid, format);
        Class<?> exportType = export.getClass();
        Object entry = invokeCompatibleNullable(service, "a", journalType, action,
            exportType.getField("czc").get(export),
            exportType.getField("czd").get(export),
            exportType.getField("czf").get(export),
            exportType.getField("metadata").get(export),
            exportType.getField("pos").get(export), Long.valueOf(-1), Long.valueOf(-1),
            exportType.getField("cze").get(export), exportType.getField("czg").get(export));
        if (entry == null || journaledBook == null) {
            throw new IllegalStateException("journal entry unavailable");
        }
        invokeCompatible(service, "a", journaledBook, entry);
    }

    private static void requestUpload(Object reader) throws Exception {
        Class<?> type = Class.forName(
            "com.amazon.kindle.restricted.webservices.whispersync.v1.WhisperSyncV1");
        Object service = invokeCompatible(reader, "getService", type);
        if (service == null) throw new IllegalStateException("WhisperSync unavailable");
        invokeCompatible(service, "bdl");
    }

    private static Properties loadPayload(String path) throws Exception {
        if (path == null || !path.matches(
                "^/tmp/goodreads-background-canary-[0-9]{8,32}\\.properties$")) {
            throw new IllegalArgumentException("invalid payload path");
        }
        File file = new File(path);
        if (!file.isFile() || file.length() < 1 || file.length() > 8192) {
            throw new IllegalArgumentException("invalid payload file");
        }
        Properties value = new Properties();
        FileInputStream input = new FileInputStream(file);
        try { value.load(input); } finally { input.close(); }
        if (!file.delete() && file.exists()) {
            throw new IllegalStateException("cannot remove payload");
        }
        if (!"1".equals(value.getProperty("version"))) {
            throw new IllegalArgumentException("unsupported payload version");
        }
        return value;
    }

    private static String resultPath(String payloadPath) {
        if (payloadPath == null || !payloadPath.startsWith(PREFIX)
                || !payloadPath.endsWith(SUFFIX)) {
            throw new IllegalArgumentException("invalid payload path");
        }
        return "/tmp/goodreads-background-canary-result-"
            + payloadPath.substring(PREFIX.length(), payloadPath.length() - SUFFIX.length())
            + ".log";
    }

    private static boolean bookMatches(Object book, String asin, String path) {
        if (book == null) return false;
        try {
            Object metadata = book.getClass().getMethod("jg").invoke(book);
            return asin.equals(invokeString(metadata, "getCdeKey"))
                && path.equals(invokeString(book, "getPath"));
        } catch (Throwable error) { return false; }
    }

    private static Object construct(String className, Object... args) throws Exception {
        for (Constructor<?> constructor : Class.forName(className).getConstructors()) {
            if (compatible(constructor.getParameterTypes(), args)) {
                return constructor.newInstance(args);
            }
        }
        throw new NoSuchMethodException(className + " constructor");
    }

    private static Object invokeCompatible(Object target, String name, Object... args)
            throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (method.getName().equals(name) && compatible(method.getParameterTypes(), args)) {
                return method.invoke(target, args);
            }
        }
        throw new NoSuchMethodException(name);
    }

    private static Object invokeCompatibleNullable(Object target, String name, Object... args)
            throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(name) || method.getParameterTypes().length != args.length) {
                continue;
            }
            boolean matches = true;
            Class<?>[] types = method.getParameterTypes();
            for (int i = 0; i < types.length; i++) {
                if (args[i] == null) {
                    if (types[i].isPrimitive()) matches = false;
                } else if (!compatible(new Class<?>[] { types[i] }, new Object[] { args[i] })) {
                    matches = false;
                }
            }
            if (matches) return method.invoke(target, args);
        }
        throw new NoSuchMethodException(name);
    }

    private static Object invokeOptional(Object target, String name, Object... args) {
        try { return invokeCompatible(target, name, args); }
        catch (Throwable error) { return null; }
    }

    private static boolean compatible(Class<?>[] types, Object[] args) {
        if (types.length != args.length) return false;
        for (int i = 0; i < types.length; i++) {
            if (args[i] == null) return false;
            Class<?> type = types[i];
            Class<?> arg = args[i].getClass();
            if (type.isPrimitive()) {
                if (!((type == Integer.TYPE && arg == Integer.class)
                        || (type == Long.TYPE && arg == Long.class)
                        || (type == Boolean.TYPE && arg == Boolean.class))) return false;
            } else if (!type.isAssignableFrom(arg)) return false;
        }
        return true;
    }

    private static String invokeString(Object target, String name) throws Exception {
        return String.valueOf(target.getClass().getMethod(name).invoke(target));
    }
    private static int readShort(Object position) throws Exception {
        return ((Integer) position.getClass().getMethod("UF").invoke(position)).intValue();
    }
    private static String requireMode(String value) {
        if (!"validate".equals(value) && !"create".equals(value)
                && !"delete".equals(value) && !"status".equals(value)) {
            throw new IllegalArgumentException("invalid mode");
        }
        return value;
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
    private static int requireShort(String value) {
        if (value == null || !value.matches("^[0-9]{1,10}$"))
            throw new IllegalArgumentException("invalid short position");
        long parsed = Long.parseLong(value);
        if (parsed > Integer.MAX_VALUE) throw new IllegalArgumentException("short overflow");
        return (int) parsed;
    }
    private static String decodeHex(String value) {
        if (value == null || value.length() > 4096 || (value.length() & 1) != 0
                || !value.matches("^[0-9A-Fa-f]*$"))
            throw new IllegalArgumentException("invalid hex");
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }
    private static Throwable unwrap(Throwable error) {
        Throwable value = error;
        while (value instanceof InvocationTargetException
                && ((InvocationTargetException) value).getCause() != null) {
            value = ((InvocationTargetException) value).getCause();
        }
        return value;
    }

    private static final class CanaryState {
        final String asin, path, start, end;
        final Object annotation;
        CanaryState(String asin, String path, String start, String end, Object annotation) {
            this.asin = asin; this.path = path; this.start = start; this.end = end;
            this.annotation = annotation;
        }
        boolean matches(String candidateAsin, String candidatePath,
                String candidateStart, String candidateEnd) {
            return asin.equals(candidateAsin) && path.equals(candidatePath)
                && start.equals(candidateStart) && end.equals(candidateEnd);
        }
    }
}
