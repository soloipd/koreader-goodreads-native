import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

/** Reconciles KOReader highlights with the native Kindle annotation store. */
public final class GoodreadsAnnotationAgentV30 {
    private GoodreadsAnnotationAgentV30() {}

    public static void agentmain(String payloadPath, Instrumentation instrumentation) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(resultPath(payloadPath), false));
        } catch (Throwable ignored) {
            return;
        }

        Object book = null;
        Object kppBook = null;
        boolean notifyKpp = false;
        String stage = "validate_payload";
        Counters counters = new Counters();
        try {
            Properties payload = loadPayload(payloadPath);
            String asin = requireAsin(payload.getProperty("asin"));
            String requestId = requireRequestId(payload.getProperty("request_id"));
            if (!payloadPath.equals("/tmp/goodreads-annotations-" + requestId + ".properties")) {
                throw new IllegalArgumentException("request ID does not match payload path");
            }
            out.println("asin=" + asin);
            out.println("request_id=" + requestId);
            String nativePath = requireNativePath(decodeHex(payload.getProperty("native_path_hex", "")));
            boolean repairZeroEndpoint = "true".equals(
                payload.getProperty("repair_zero_endpoint"));
            boolean forceCloudReplay = "true".equals(
                payload.getProperty("force_cloud_replay"));
            boolean purgeLegacyCloud = "true".equals(
                payload.getProperty("purge_legacy_cloud"));
            List<Record> desired = readRecords(payload, "desired");
            Map<String, Boolean> previous = readPrevious(payload, "previous");
            out.println("requested=" + desired.size());

            stage = "resolve_reader_sdk";
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            Class<?> readerSdkType = Class.forName("com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Object readerSdk = framework.getMethod("getService", Class.class).invoke(null, readerSdkType);
            if (readerSdk == null) {
                throw new IllegalStateException("ReaderSDK unavailable");
            }
            Object contentSdk = readerSdk.getClass().getMethod("jE").invoke(readerSdk);
            boolean ksdkEnabled = invokeStaticBoolean(
                "com.amazon.ebook.booklet.reader.impl.annotation.proxy.ksdkannotations.KSDKAnnotationsConfig",
                "Em"
            );
            boolean whisperStoreEnabled = invokeStaticBoolean(
                "com.amazon.ebook.booklet.reader.impl.whisperstore.WhisperStoreKwisUtils",
                "Ls"
            );
            out.println("ksdk_enabled=" + ksdkEnabled);
            out.println("whisperstore_enabled=" + whisperStoreEnabled);

            stage = "open_book";
            Object activeBook = invokeOptional(readerSdk, "jy");
            if (bookMatchesAsin(activeBook, asin)
                    && bookMatchesPath(activeBook, nativePath)) {
                book = activeBook;
                kppBook = activeBook;
                notifyKpp = true;
                out.println("book_source=active");
            } else {
                out.println("book_source=" + (bookMatchesAsin(activeBook, asin)
                    ? "inactive_identity_mismatch" : "inactive"));
                stage = "wait_for_active_book";
                throw new IllegalStateException("requested native book is not active");
            }
            if (book == null) {
                throw new IllegalStateException("native book unavailable");
            }

            stage = "load_annotations";
            Object manager = contentSdk.getClass().getMethod("xA").invoke(contentSdk);
            Object listed = invokeCompatible(manager, "Q", book);
            List<?> annotations = listed instanceof List ? (List<?>) listed : Collections.emptyList();
            Map<String, Object> existing = indexAnnotations(annotations);

            if (repairZeroEndpoint) {
                stage = "repair_generation_6_annotations";
                repairGenerationSixAnnotations(
                    annotations, manager, readerSdk, book, kppBook, nativePath, desired,
                    notifyKpp, ksdkEnabled, whisperStoreEnabled, counters);
                listed = invokeCompatible(manager, "Q", book);
                annotations = listed instanceof List ? (List<?>) listed : Collections.emptyList();
                existing = indexAnnotations(annotations);
            }

            if (purgeLegacyCloud) {
                stage = "purge_generation_6_cloud_annotations";
                purgeGenerationSixCloudAnnotations(
                    contentSdk, readerSdk, book, nativePath, desired, previous,
                    notifyKpp, ksdkEnabled, whisperStoreEnabled, counters);
            }

            stage = "normalize_terminal_endpoints";
            desired = normalizeDesiredRecords(contentSdk, book, desired, counters);
            previous = normalizePreviousRanges(contentSdk, book, previous);

            stage = "reconcile_annotations";
            Set<String> desiredKeys = new HashSet<String>();
            for (Record record : desired) {
                desiredKeys.add(record.rangeKey());
                Object start = makePosition(
                    contentSdk, book, record.startLong, record.startShort);
                Object end = makePosition(
                    contentSdk, book, record.endLong, record.endShort);
                String highlightKey = typedKey(1, record);
                Object highlight = existing.get(highlightKey);
                if (highlight != null && !positionMatches(highlight, record)) {
                    if (!invokeBoolean(manager, "g", highlight, book)) {
                        throw new IllegalStateException("invalid native highlight repair rejected");
                    }
                    if (notifyKpp) {
                        notifyNativeReader(readerSdk, highlight, kppBook, "DELETE",
                            false, counters);
                    }
                    syncNativeCloudEdit(readerSdk, highlight, book, nativePath, "DELETE",
                        ksdkEnabled, whisperStoreEnabled, counters);
                    counters.highlightsDeleted++;
                    counters.zeroEndpointRepairs++;
                    existing.remove(highlightKey);
                    highlight = null;
                }
                if (highlight == null) {
                    highlight = construct(
                        "com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight",
                        start,
                        end
                    );
                    if (!invokeBoolean(manager, "f", highlight, book)) {
                        throw new IllegalStateException("native highlight create rejected");
                    }
                    if (notifyKpp) {
                        notifyNativeReader(readerSdk, highlight, kppBook, "CREATE",
                            false, counters);
                    }
                    syncNativeCloudEdit(readerSdk, highlight, book, nativePath, "CREATE",
                        ksdkEnabled, whisperStoreEnabled, counters);
                    existing.put(highlightKey, highlight);
                    counters.highlightsCreated++;
                } else {
                    // Some Kindle content engines return persisted annotation
                    // endpoints in the opposite order from the translated
                    // KOReader range. Use the native object's ordering when
                    // attaching a note so the manager accepts it.
                    start = highlight.getClass().getMethod("jh").invoke(highlight);
                    end = highlight.getClass().getMethod("jd").invoke(highlight);
                    // A detached reconciliation can leave KPP's live annotation
                    // index stale even though ReaderSDK can read the durable
                    // record back. Re-announce the persisted object as an update
                    // so the native reader refreshes/upserts it by annotation ID.
                    if (notifyKpp) {
                        notifyKppReader(readerSdk, highlight, kppBook, "UPDATE", counters);
                    }
                    if (forceCloudReplay) {
                        syncNativeCloudEdit(readerSdk, highlight, book, nativePath, "UPDATE",
                            ksdkEnabled, whisperStoreEnabled, counters);
                    }
                }

                String noteKey = typedKey(2, record);
                Object note = existing.get(noteKey);
                if (record.note.length() > 0) {
                    if (note == null) {
                        note = construct(
                            "com.amazon.ebook.booklet.reader.impl.annotation.personal.Note",
                            record.note,
                            start,
                            end
                        );
                        if (!invokeBoolean(manager, "f", note, book)) {
                            throw new IllegalStateException("native note create rejected");
                        }
                        if (notifyKpp) {
                            notifyNativeReader(readerSdk, note, kppBook, "CREATE",
                                false, counters);
                        }
                        syncNativeCloudEdit(readerSdk, note, book, nativePath, "CREATE",
                            ksdkEnabled, whisperStoreEnabled, counters);
                        existing.put(noteKey, note);
                        counters.notesCreated++;
                    } else {
                        String oldText = String.valueOf(note.getClass().getMethod("getText").invoke(note));
                        if (!record.note.equals(oldText)) {
                            note.getClass().getMethod("setText", String.class).invoke(note, record.note);
                            if (!invokeBoolean(manager, "h", note, book)) {
                                throw new IllegalStateException("native note update rejected");
                            }
                            if (notifyKpp) {
                                notifyNativeReader(readerSdk, note, kppBook, "UPDATE",
                                    false, counters);
                            }
                            syncNativeCloudEdit(readerSdk, note, book, nativePath, "UPDATE",
                                ksdkEnabled, whisperStoreEnabled, counters);
                            counters.notesUpdated++;
                        } else {
                            if (notifyKpp) {
                                notifyKppReader(readerSdk, note, kppBook, "UPDATE", counters);
                            }
                            if (forceCloudReplay) {
                                syncNativeCloudEdit(readerSdk, note, book, nativePath, "UPDATE",
                                    ksdkEnabled, whisperStoreEnabled, counters);
                            }
                        }
                    }
                } else if (note != null && previousHadNote(previous, record)) {
                    if (!invokeBoolean(manager, "g", note, book)) {
                        throw new IllegalStateException("native note delete rejected");
                    }
                    if (notifyKpp) {
                        notifyNativeReader(readerSdk, note, kppBook, "DELETE",
                            false, counters);
                    }
                    syncNativeCloudEdit(readerSdk, note, book, nativePath, "DELETE",
                        ksdkEnabled, whisperStoreEnabled, counters);
                    existing.remove(noteKey);
                    counters.notesDeleted++;
                }
            }

            for (Map.Entry<String, Boolean> oldEntry : previous.entrySet()) {
                String oldRange = oldEntry.getKey();
                if (desiredKeys.contains(oldRange)) {
                    continue;
                }
                RangeIdentity positions = splitRangeKey(oldRange);
                if (oldEntry.getValue().booleanValue()) {
                    deleteExisting(existing, manager, readerSdk, book, 2, positions,
                        kppBook, nativePath, notifyKpp,
                        ksdkEnabled, whisperStoreEnabled, counters);
                }
                deleteExisting(existing, manager, readerSdk, book, 1, positions,
                    kppBook, nativePath, notifyKpp,
                    ksdkEnabled, whisperStoreEnabled, counters);
            }

            stage = "verify_native_annotations";
            Object verifiedListed = invokeCompatible(manager, "Q", book);
            List<?> verifiedAnnotations = verifiedListed instanceof List
                ? (List<?>) verifiedListed : Collections.emptyList();
            Map<String, Object> verified = indexAnnotations(verifiedAnnotations);
            verifyDesired(verified, desired);
            verifyDeleted(verified, desiredKeys, previous);

            if (whisperStoreEnabled) {
                stage = "sync_cloud_snapshot";
                syncCloudSnapshot(book, verifiedAnnotations, counters);
            }

            if (!ksdkEnabled && counters.nativeJournalEdits > 0) {
                stage = "request_native_cloud_upload";
                requestNativeCloudUpload(readerSdk, counters);
            }

            boolean nativeNotified = counters.nativeNotifications > 0;
            boolean ksdkQueued = counters.ksdkWrites > 0;
            boolean legacyQueued = counters.nativeJournalEdits > 0
                && counters.nativeUploadRequests > 0;
            boolean cloudSnapshotQueued = counters.cloudSnapshots > 0;
            boolean nativeCloudQueued = ksdkQueued || legacyQueued
                || counters.cloudEdits > 0 || cloudSnapshotQueued;
            out.println("local_verified=true");
            out.println("native_notified=" + (nativeNotified ? "true" : "unavailable"));
            out.println("ksdk_synced=" + (ksdkQueued ? "true" : "unavailable"));
            out.println("legacy_journaled=" + (legacyQueued ? "true" : "unavailable"));
            out.println("upload_requested=" + (!ksdkEnabled
                ? (counters.nativeUploadRequests > 0 ? "true" : "false")
                : "unavailable"));
            out.println("native_cloud_queued=" + nativeCloudQueued);
            out.println("cloud_synced=" + (nativeCloudQueued ? "queued" : "unchanged"));
            out.println("cloud_snapshot_synced="
                + (cloudSnapshotQueued ? "true" : "unavailable"));
            out.println("success=true");
            counters.write(out);
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            out.println("success=false");
            out.println("failed_stage=" + stage);
            out.println("error_class=" + cause.getClass().getName());
            StackTraceElement[] trace = cause.getStackTrace();
            for (int index = 0; index < trace.length && index < 8; index++) {
                StackTraceElement frame = trace[index];
                out.println("error_trace_" + index + "="
                    + frame.getClassName() + "." + frame.getMethodName()
                    + ":" + frame.getLineNumber());
            }
            counters.write(out);
        } finally {
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
        Map<String, Record> unique = new LinkedHashMap<String, Record>();
        for (int index = 0; index < count; index++) {
            String base = prefix + "." + index + ".";
            Record record = new Record(
                requireLongPosition(payload.getProperty(base + "start")),
                requireShortPosition(payload.getProperty(base + "start_short")),
                requireLongPosition(payload.getProperty(base + "end")),
                requireShortPosition(payload.getProperty(base + "end_short")),
                decodeHex(payload.getProperty(base + "note_hex", ""))
            );
            Record existing = unique.get(record.rangeKey());
            if (existing == null) {
                unique.put(record.rangeKey(), record);
            } else if (existing.note.length() == 0 && record.note.length() > 0) {
                // Distinct EPUB ranges can resolve to one exact KFX range at a
                // position-map boundary. Kindle can represent only one native
                // annotation there, so retain one highlight and its note while
                // leaving KOReader's source annotations untouched.
                unique.put(record.rangeKey(), record);
            }
        }
        return new ArrayList<Record>(unique.values());
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
            RangeIdentity positions = splitRangeKey(range);
            if (!"0".equals(noteFlag) && !"1".equals(noteFlag)) {
                throw new IllegalArgumentException("invalid previous note state");
            }
            keys.put(positions.key(), Boolean.valueOf("1".equals(noteFlag)));
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
            int startShort = readShortPosition(start);
            int endShort = readShortPosition(end);
            indexed.put(typedKey(type, new RangeIdentity(
                startLong, Integer.valueOf(startShort),
                endLong, Integer.valueOf(endShort))), annotation);
        }
        return indexed;
    }

    private static Object makePosition(
        Object contentSdk,
        Object book,
        String encoded,
        int shortPosition
    ) throws Exception {
        Object factory = invokeCompatible(contentSdk, "E", book);
        Object position = invokeCompatible(factory, "a", encoded, book);
        String roundTrip = String.valueOf(position.getClass().getMethod("nX").invoke(position));
        if (!encoded.equals(roundTrip)) {
            throw new IllegalStateException("native long position round-trip failed");
        }
        if (readShortPosition(position) != shortPosition) {
            throw new IllegalStateException("native short position mismatch");
        }
        return position;
    }

    /**
     * Reconstruct only the malformed generation-6 cloud identity so it can be
     * deleted. This synthetic zero-short position is never persisted locally.
     */
    private static Object makeLegacyBrokenPosition(
        Object contentSdk,
        Object book,
        String encoded
    ) throws Exception {
        Object factory = invokeCompatible(contentSdk, "E", book);
        Object resolved = invokeCompatible(factory, "a", encoded, book);
        for (Constructor<?> constructor : resolved.getClass().getDeclaredConstructors()) {
            Class<?>[] parameters = constructor.getParameterTypes();
            if (parameters.length == 3
                    && parameters[0].isAssignableFrom(book.getClass())
                    && parameters[1] == String.class
                    && parameters[2] == Integer.TYPE) {
                constructor.setAccessible(true);
                Object broken = constructor.newInstance(book, encoded, Integer.valueOf(0));
                if (readShortPosition(broken) == 0
                        && encoded.equals(String.valueOf(
                            broken.getClass().getMethod("nX").invoke(broken)))) {
                    return broken;
                }
            }
        }
        throw new IllegalStateException("legacy broken cloud position unavailable");
    }

    private static List<Record> normalizeDesiredRecords(
        Object contentSdk,
        Object book,
        List<Record> records,
        Counters counters
    ) throws Exception {
        List<Record> normalized = new ArrayList<Record>(records.size());
        Object factory = invokeCompatible(contentSdk, "E", book);
        for (Record record : records) {
            Object start = invokeCompatible(factory, "a", record.startLong, book);
            if (readShortPosition(start) != record.startShort) {
                throw new IllegalStateException("native start position mismatch");
            }
            Object end = invokeCompatible(factory, "a", record.endLong, book);
            int nativeEndShort = readShortPosition(end);
            if (nativeEndShort == record.endShort) {
                normalized.add(record);
                continue;
            }
            if (nativeEndShort != 0 || record.endShort <= record.startShort) {
                throw new IllegalStateException("native end position mismatch");
            }
            String previousLong = decrementLongPosition(record.endLong);
            Object previousEnd = invokeCompatible(factory, "a", previousLong, book);
            int previousShort = readShortPosition(previousEnd);
            if (previousShort != record.endShort - 1
                    || !previousLong.equals(String.valueOf(
                        previousEnd.getClass().getMethod("nX").invoke(previousEnd)))) {
                throw new IllegalStateException("terminal native end position is unresolved");
            }
            normalized.add(new Record(
                record.startLong,
                record.startShort,
                previousLong,
                previousShort,
                record.note
            ));
            counters.terminalEndpointRepairs++;
        }
        return normalized;
    }

    private static Map<String, Boolean> normalizePreviousRanges(
        Object contentSdk,
        Object book,
        Map<String, Boolean> previous
    ) throws Exception {
        Map<String, Boolean> normalized = new HashMap<String, Boolean>();
        Object factory = invokeCompatible(contentSdk, "E", book);
        for (Map.Entry<String, Boolean> entry : previous.entrySet()) {
            RangeIdentity positions = splitRangeKey(entry.getKey());
            String startLong = positions.startLong;
            Object start = invokeCompatible(factory, "a", startLong, book);
            int startShort = positions.startShort == null
                ? readShortPosition(start) : positions.startShort.intValue();
            String endLong = positions.endLong;
            Object end = invokeCompatible(factory, "a", endLong, book);
            int endShort = positions.endShort == null
                ? readShortPosition(end) : positions.endShort.intValue();
            if (readShortPosition(end) == 0 && endShort > startShort) {
                String candidateLong = decrementLongPosition(endLong);
                Object candidate = invokeCompatible(factory, "a", candidateLong, book);
                if (readShortPosition(candidate) > 0
                        && candidateLong.equals(String.valueOf(
                            candidate.getClass().getMethod("nX").invoke(candidate)))) {
                    endLong = candidateLong;
                    endShort = readShortPosition(candidate);
                }
            }
            normalized.put(pairKey(
                startLong, startShort, endLong, endShort), entry.getValue());
        }
        return normalized;
    }

    private static String decrementLongPosition(String encoded) {
        final String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        if (encoded == null || encoded.length() != 12) {
            throw new IllegalArgumentException("invalid native long position");
        }
        byte[] raw = new byte[9];
        for (int group = 0; group < 3; group++) {
            int base = group * 4;
            int value = 0;
            for (int index = 0; index < 4; index++) {
                int digit = alphabet.indexOf(encoded.charAt(base + index));
                if (digit < 0) {
                    throw new IllegalArgumentException("invalid native long position");
                }
                value = (value << 6) | digit;
            }
            raw[group * 3] = (byte) ((value >>> 16) & 0xff);
            raw[group * 3 + 1] = (byte) ((value >>> 8) & 0xff);
            raw[group * 3 + 2] = (byte) (value & 0xff);
        }
        if ((raw[5] | raw[6] | raw[7] | raw[8]) == 0) {
            throw new IllegalArgumentException("native long position offset is zero");
        }
        for (int index = 5; index <= 8; index++) {
            int value = raw[index] & 0xff;
            if (value > 0) {
                raw[index] = (byte) (value - 1);
                break;
            }
            raw[index] = (byte) 0xff;
        }
        StringBuilder result = new StringBuilder(12);
        for (int group = 0; group < 3; group++) {
            int value = ((raw[group * 3] & 0xff) << 16)
                | ((raw[group * 3 + 1] & 0xff) << 8)
                | (raw[group * 3 + 2] & 0xff);
            result.append(alphabet.charAt((value >>> 18) & 0x3f));
            result.append(alphabet.charAt((value >>> 12) & 0x3f));
            result.append(alphabet.charAt((value >>> 6) & 0x3f));
            result.append(alphabet.charAt(value & 0x3f));
        }
        return result.toString();
    }

    private static void deleteExisting(
        Map<String, Object> existing,
        Object manager,
        Object readerSdk,
        Object book,
        int type,
        RangeIdentity range,
        Object kppBook,
        String nativePath,
        boolean notifyKpp,
        boolean ksdkEnabled,
        boolean whisperStoreEnabled,
        Counters counters
    ) throws Exception {
        if (!range.hasShortPositions()) {
            return;
        }
        String key = typedKey(type, range);
        Object annotation = existing.get(key);
        if (annotation == null) {
            return;
        }
        if (!invokeBoolean(manager, "g", annotation, book)) {
            throw new IllegalStateException("native annotation delete rejected");
        }
        if (notifyKpp) {
            notifyNativeReader(readerSdk, annotation, kppBook, "DELETE",
                false, counters);
        }
        syncNativeCloudEdit(readerSdk, annotation, book, nativePath, "DELETE",
            ksdkEnabled, whisperStoreEnabled, counters);
        existing.remove(key);
        if (type == 1) {
            counters.highlightsDeleted++;
        } else {
            counters.notesDeleted++;
        }
    }

    private static void notifyNativeReader(
        Object readerSdk,
        Object annotation,
        Object book,
        String operationName,
        boolean ksdkDualWriteAvailable,
        Counters counters
    ) throws Exception {
        Object proxy = invokeCompatible(readerSdk, "xB");
        if (proxy == null) {
            throw new IllegalStateException("native annotation proxy unavailable");
        }
        Class<?> operationType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType"
        );
        @SuppressWarnings({"rawtypes", "unchecked"})
        Object operation = Enum.valueOf((Class) operationType, operationName);
        if (ksdkDualWriteAvailable) {
            invokeKsdkProxy(proxy, annotation, book, operation);
            counters.ksdkWrites++;
        }
        notifyKppReader(readerSdk, annotation, book, operationName, counters);
    }

    private static void notifyKppReader(
        Object readerSdk,
        Object annotation,
        Object book,
        String operationName,
        Counters counters
    ) throws Exception {
        Object proxy = invokeCompatible(readerSdk, "xB");
        if (proxy == null) {
            throw new IllegalStateException("native annotation proxy unavailable");
        }
        Class<?> operationType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType"
        );
        @SuppressWarnings({"rawtypes", "unchecked"})
        Object operation = Enum.valueOf((Class) operationType, operationName);
        Class<?> bookDataType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.proxy.BookData"
        );
        Object optionalBookData = invokeStaticCompatible(bookDataType, "ah", book);
        boolean bookDataPresent = ((Boolean) optionalBookData.getClass()
            .getMethod("isPresent").invoke(optionalBookData)).booleanValue();
        if (!bookDataPresent) {
            throw new IllegalStateException("native annotation book data unavailable");
        }
        Object bookData = optionalBookData.getClass().getMethod("get").invoke(optionalBookData);
        Class<?> recordType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.proxy.AnnotationRecord"
        );
        Object record = invokeStaticCompatible(recordType, "a", bookData, annotation);
        invokeCompatible(proxy, "a", record, operation);
        counters.nativeNotifications++;
    }

    private static void syncKsdkEdit(
        Object readerSdk,
        Object annotation,
        Object book,
        String operationName,
        Counters counters
    ) throws Exception {
        Object proxy = invokeCompatible(readerSdk, "xB");
        if (proxy == null) {
            throw new IllegalStateException("native annotation proxy unavailable");
        }
        Class<?> operationType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType"
        );
        @SuppressWarnings({"rawtypes", "unchecked"})
        Object operation = Enum.valueOf((Class) operationType, operationName);
        invokeKsdkProxy(proxy, annotation, book, operation);
        counters.ksdkWrites++;
    }

    private static void syncNativeCloudEdit(
        Object readerSdk,
        Object annotation,
        Object book,
        String nativePath,
        String operationName,
        boolean ksdkEnabled,
        boolean whisperStoreEnabled,
        Counters counters
    ) throws Exception {
        if (ksdkEnabled) {
            syncKsdkEdit(readerSdk, annotation, book, operationName, counters);
        } else {
            journalLegacyEdit(readerSdk, annotation, book, nativePath, operationName);
            counters.nativeJournalEdits++;
        }
        if (whisperStoreEnabled) {
            syncCloudEdit(annotation, book, operationName, counters);
        }
    }

    private static void journalLegacyEdit(
        Object readerSdk,
        Object annotation,
        Object book,
        String nativePath,
        String operationName
    ) throws Exception {
        Object export = annotation.getClass().getMethod("Ci").invoke(annotation);
        Object sdkJournalType = annotation.getClass().getMethod("CS").invoke(annotation);
        Class<?> annotationSyncType = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.annotation.AnnotationSync"
        );
        Method mapJournalType = null;
        for (Method method : annotationSyncType.getDeclaredMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (method.getName().equals("a") && parameters.length == 1
                    && parameters[0].getName().equals(
                        "com.amazon.ebook.booklet.reader.sdk.content.annotation.JournalType")
                    && method.getReturnType().getName().equals(
                        "com.amazon.kindle.content.journal.JournalType")) {
                mapJournalType = method;
            }
        }
        if (mapJournalType == null) {
            throw new IllegalStateException("native journaling helpers unavailable");
        }
        mapJournalType.setAccessible(true);
        Object journalType = mapJournalType.invoke(null, sdkJournalType);

        Class<?> actionType = Class.forName("com.amazon.kindle.content.journal.JournalAction");
        String actionField = "CREATE".equals(operationName) ? "gbb"
            : ("DELETE".equals(operationName) ? "gbc" : "gbd");
        Object action = actionType.getField(actionField).get(null);
        Class<?> journalingServiceType = Class.forName(
            "com.amazon.kindle.content.journal.JournalingService"
        );
        Object service = invokeOptional(readerSdk, "getService", journalingServiceType);
        if (service == null) {
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            service = framework.getMethod("getService", Class.class)
                .invoke(null, journalingServiceType);
        }
        if (service == null) {
            Object context = invokeOptional(readerSdk, "xn");
            if (context != null) {
                service = invokeOptional(context, "getService", journalingServiceType);
            }
        }
        if (service == null) {
            throw new IllegalStateException("native journaling service unavailable");
        }

        Object bookMetadata = book.getClass().getMethod("jg").invoke(book);
        String cdeKey = String.valueOf(
            bookMetadata.getClass().getMethod("getCdeKey").invoke(bookMetadata));
        String cdeType = String.valueOf(
            bookMetadata.getClass().getMethod("getCdeType").invoke(bookMetadata));
        Integer version = (Integer) bookMetadata.getClass()
            .getMethod("getVersion").invoke(bookMetadata);
        String guid = String.valueOf(
            bookMetadata.getClass().getMethod("getGUID").invoke(bookMetadata));
        int bookFormat = ((Integer) book.getClass().getMethod("jm").invoke(book)).intValue();
        String format = bookFormat == 0 ? "mobi7"
            : bookFormat == 1 ? "mobi8"
            : bookFormat == 2 ? "topaz"
            : bookFormat == 3 ? "pdf"
            : bookFormat == 4 ? "YJBinary" : null;
        if (cdeKey.length() == 0 || cdeType.length() == 0 || guid.length() == 0
                || format == null) {
            throw new IllegalStateException("native journal identity unavailable");
        }
        Object journaledBook = invokeCompatible(
            service, "a", nativePath, cdeKey, cdeType, version, guid, format);
        if (journalType == null || journaledBook == null) {
            throw new IllegalStateException("native journal book unavailable");
        }

        Class<?> exportType = export.getClass();
        Object entry = invokeCompatibleNullable(
            service,
            "a",
            journalType,
            action,
            exportType.getField("czc").get(export),
            exportType.getField("czd").get(export),
            exportType.getField("czf").get(export),
            exportType.getField("metadata").get(export),
            exportType.getField("pos").get(export),
            Long.valueOf(-1L),
            Long.valueOf(-1L),
            exportType.getField("cze").get(export),
            exportType.getField("czg").get(export)
        );
        if (entry == null) {
            throw new IllegalStateException("native journal entry unavailable");
        }
        invokeCompatible(service, "a", journaledBook, entry);
    }

    private static Object invokeCompatibleNullable(
        Object target,
        String name,
        Object... arguments
    ) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (!method.getName().equals(name) || parameters.length != arguments.length) {
                continue;
            }
            boolean matches = true;
            for (int index = 0; index < parameters.length; index++) {
                if (arguments[index] == null) {
                    if (parameters[index].isPrimitive()) matches = false;
                } else if (!compatible(
                        new Class<?>[] { parameters[index] },
                        new Object[] { arguments[index] })) {
                    matches = false;
                }
            }
            if (matches) return method.invoke(target, arguments);
        }
        throw new NoSuchMethodException(name);
    }

    private static void requestNativeCloudUpload(Object readerSdk, Counters counters)
            throws Exception {
        Class<?> whisperSyncType = Class.forName(
            "com.amazon.kindle.restricted.webservices.whispersync.v1.WhisperSyncV1"
        );
        Object service = invokeCompatible(readerSdk, "getService", whisperSyncType);
        if (service == null) {
            throw new IllegalStateException("native WhisperSync service unavailable");
        }
        invokeCompatible(service, "bdl");
        counters.nativeUploadRequests++;
    }

    private static boolean invokeStaticBoolean(String className, String methodName)
            throws Exception {
        Object value = Class.forName(className).getMethod(methodName).invoke(null);
        if (!(value instanceof Boolean)) {
            throw new IllegalStateException("native feature flag unavailable");
        }
        return ((Boolean) value).booleanValue();
    }

    private static void invokeKsdkProxy(
        Object proxy,
        Object annotation,
        Object book,
        Object operation
    ) throws Exception {
        try {
            invokeCompatible(proxy, "a", annotation, book, operation);
            return;
        } catch (NoSuchMethodException missingFacadeMethod) {
            for (Field field : proxy.getClass().getDeclaredFields()) {
                field.setAccessible(true);
                Object candidate = field.get(proxy);
                if (candidate == null) {
                    continue;
                }
                for (Method method : candidate.getClass().getMethods()) {
                    if (method.getName().equals("a")
                            && compatible(method.getParameterTypes(),
                                new Object[] { annotation, book, operation })) {
                        method.invoke(candidate, annotation, book, operation);
                        return;
                    }
                }
            }
            throw missingFacadeMethod;
        }
    }

    private static void syncCloudEdit(
        Object annotation,
        Object book,
        String operationName,
        Counters counters
    ) throws Exception {
        Class<?> bridge = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.whisperstore.WhisperStoreLipcBridge"
        );
        Object accepted;
        if ("DELETE".equals(operationName)) {
            accepted = invokeStaticCompatible(bridge, "d", annotation, book);
        } else {
            Object cloudAnnotation = cloudCompatibleAnnotation(annotation);
            accepted = invokeStaticCompatible(
                bridge,
                "a",
                cloudAnnotation,
                book,
                Boolean.valueOf("CREATE".equals(operationName))
            );
        }
        if (!(accepted instanceof Boolean) || !((Boolean) accepted).booleanValue()) {
            throw new IllegalStateException("native cloud annotation edit rejected");
        }
        counters.cloudEdits++;
    }

    /**
     * Color-capable firmware returns a map from Highlight.Cf(), while this
     * firmware's WhisperStore bridge casts Cf() directly to String. Present a
     * delegating Annotation view with that unsupported optional field omitted;
     * the persisted native annotation and its color remain untouched.
     */
    private static Object cloudCompatibleAnnotation(final Object annotation) throws Exception {
        Object extra = annotation.getClass().getMethod("Cf").invoke(annotation);
        if (extra == null || extra instanceof String) {
            return annotation;
        }
        final Class<?> annotationType = Class.forName(
            "com.amazon.ebook.booklet.reader.sdk.content.annotation.Annotation"
        );
        if (!annotationType.isInstance(annotation)) {
            throw new IllegalStateException("native cloud annotation type mismatch");
        }
        return Proxy.newProxyInstance(
            annotationType.getClassLoader(),
            new Class<?>[] { annotationType },
            new CloudAnnotationHandler(annotation)
        );
    }

    private static void syncCloudSnapshot(
        Object book,
        List<?> annotations,
        Counters counters
    ) throws Exception {
        Class<?> jsonObjectType = Class.forName("org.json.simple.JSONObject");
        Class<?> jsonArrayType = Class.forName("org.json.simple.JSONArray");
        @SuppressWarnings("unchecked")
        List<Object> allAnnotations = (List<Object>) jsonArrayType.newInstance();
        for (Object annotation : annotations) {
            int type = ((Integer) annotation.getClass().getMethod("jm").invoke(annotation)).intValue();
            if (type < 0 || type > 2) {
                continue;
            }
            @SuppressWarnings("unchecked")
            Map<Object, Object> item = (Map<Object, Object>) jsonObjectType.newInstance();
            Object start = annotation.getClass().getMethod("jh").invoke(annotation);
            Object end = annotation.getClass().getMethod("jd").invoke(annotation);
            if (type == 0) {
                item.put("type", "bookmark");
                item.put("start_position", Integer.valueOf(readShortPosition(start)));
            } else {
                item.put("type", type == 1 ? "highlight" : "note");
                item.put("start_position", Integer.valueOf(readShortPosition(start)));
                item.put("end_position", Integer.valueOf(readShortPosition(end)));
                if (type == 2) {
                    item.put("customer_text", String.valueOf(
                        annotation.getClass().getMethod("getText").invoke(annotation)));
                }
            }
            @SuppressWarnings("unchecked")
            Map<Object, Object> metadataJson = (Map<Object, Object>) jsonObjectType.newInstance();
            Object created = annotation.getClass().getMethod("L").invoke(annotation);
            Object modified = annotation.getClass().getMethod("Cd").invoke(annotation);
            if (created != null) metadataJson.put("createdTime", created);
            if (modified != null) metadataJson.put("lastModifiedTime", modified);
            item.put("json_metadata", metadataJson.toString());
            allAnnotations.add(item);
        }

        Object metadata = book.getClass().getMethod("jg").invoke(book);
        String asin = String.valueOf(metadata.getClass().getMethod("getASIN").invoke(metadata));
        String cdeType = String.valueOf(metadata.getClass().getMethod("getCdeType").invoke(metadata));
        String guid = String.valueOf(metadata.getClass().getMethod("getGUID").invoke(metadata));
        if (asin.length() == 0 || cdeType.length() == 0 || guid.length() == 0) {
            throw new IllegalStateException("native annotation snapshot metadata unavailable");
        }
        Map<String, Object> payload = new HashMap<String, Object>();
        payload.put("asin", asin);
        payload.put("cde_type", cdeType);
        payload.put("guid", guid);
        payload.put("all_annotations", allAnnotations.toString());
        Class<?> bridge = Class.forName(
            "com.amazon.ebook.booklet.reader.impl.whisperstore.WhisperStoreLipcBridge"
        );
        Object accepted = invokeStaticCompatible(bridge, "b", payload, book);
        if (!(accepted instanceof Boolean) || !((Boolean) accepted).booleanValue()) {
            throw new IllegalStateException("native cloud annotation snapshot rejected");
        }
        counters.cloudSnapshots++;
    }

    private static final class CloudAnnotationHandler implements InvocationHandler {
        private final Object annotation;

        private CloudAnnotationHandler(Object annotation) {
            this.annotation = annotation;
        }

        public Object invoke(Object proxy, Method method, Object[] arguments) throws Throwable {
            if ("Cf".equals(method.getName()) && method.getParameterTypes().length == 0) {
                return null;
            }
            try {
                return method.invoke(annotation, arguments);
            } catch (InvocationTargetException error) {
                throw error.getCause();
            }
        }
    }

    private static Object invokeStaticCompatible(Class<?> type, String name, Object... arguments)
            throws Exception {
        for (Method method : type.getMethods()) {
            if (method.getName().equals(name) && compatible(method.getParameterTypes(), arguments)) {
                return method.invoke(null, arguments);
            }
        }
        throw new NoSuchMethodException(type.getName() + "." + name);
    }

    private static Object invokeOptional(Object target, String name, Object... arguments) {
        try {
            return invokeCompatible(target, name, arguments);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean bookMatchesAsin(Object book, String asin) {
        if (book == null) {
            return false;
        }
        try {
            Object metadata = book.getClass().getMethod("jg").invoke(book);
            if (metadata == null) {
                return false;
            }
            Object cdeKey = metadata.getClass().getMethod("getCdeKey").invoke(metadata);
            return asin.equals(String.valueOf(cdeKey));
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean bookMatchesPath(Object book, String nativePath) {
        if (book == null || nativePath == null) {
            return false;
        }
        try {
            Object path = book.getClass().getMethod("getPath").invoke(book);
            return nativePath.equals(String.valueOf(path));
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static int readShortPosition(Object position) throws Exception {
        return ((Integer) position.getClass().getMethod("UF").invoke(position)).intValue();
    }

    private static boolean positionMatches(Object annotation, Record record) throws Exception {
        Object start = annotation.getClass().getMethod("jh").invoke(annotation);
        Object end = annotation.getClass().getMethod("jd").invoke(annotation);
        int startShort = readShortPosition(start);
        int endShort = readShortPosition(end);
        return (startShort == record.startShort && endShort == record.endShort)
            || (startShort == record.endShort && endShort == record.startShort);
    }

    private static void repairGenerationSixAnnotations(
        List<?> annotations,
        Object manager,
        Object readerSdk,
        Object book,
        Object kppBook,
        String nativePath,
        List<Record> desired,
        boolean notifyKpp,
        boolean ksdkEnabled,
        boolean whisperStoreEnabled,
        Counters counters
    ) throws Exception {
        for (Object annotation : new ArrayList<Object>(annotations)) {
            int type = ((Integer) annotation.getClass().getMethod("jm").invoke(annotation)).intValue();
            if (type != 1 && type != 2) {
                continue;
            }
            Object start = annotation.getClass().getMethod("jh").invoke(annotation);
            Object end = annotation.getClass().getMethod("jd").invoke(annotation);
            int startShort = readShortPosition(start);
            int endShort = readShortPosition(end);
            String startLong = String.valueOf(start.getClass().getMethod("nX").invoke(start));
            String endLong = String.valueOf(end.getClass().getMethod("nX").invoke(end));
            boolean corrupt = false;
            for (Record record : desired) {
                boolean zeroAndStart = (startShort == 0 && endShort == record.startShort)
                    || (endShort == 0 && startShort == record.startShort);
                boolean carriesStartLong = record.startLong.equals(startLong)
                    || record.startLong.equals(endLong);
                if (zeroAndStart && carriesStartLong) {
                    corrupt = true;
                    break;
                }
            }
            if (!corrupt) {
                continue;
            }
            if (!invokeBoolean(manager, "g", annotation, book)) {
                throw new IllegalStateException("generation 6 annotation cleanup rejected");
            }
            if (notifyKpp) {
                notifyNativeReader(readerSdk, annotation, kppBook, "DELETE",
                    false, counters);
            }
            syncNativeCloudEdit(readerSdk, annotation, book, nativePath, "DELETE",
                ksdkEnabled, whisperStoreEnabled, counters);
            counters.zeroEndpointRepairs++;
            if (type == 1) {
                counters.highlightsDeleted++;
            } else {
                counters.notesDeleted++;
            }
        }
    }

    /**
     * Generation 6 accidentally persisted the translated long endpoint with a
     * short endpoint of zero. WhisperStore consequently rendered the range as
     * starting at the beginning of the book. Those records may remain in the
     * cloud after their local counterparts have been removed, so reconstruct
     * their exact broken identity and explicitly journal a deletion.
     */
    private static void purgeGenerationSixCloudAnnotations(
        Object contentSdk,
        Object readerSdk,
        Object book,
        String nativePath,
        List<Record> desired,
        Map<String, Boolean> previous,
        boolean notifyKpp,
        boolean ksdkEnabled,
        boolean whisperStoreEnabled,
        Counters counters
    ) throws Exception {
        for (Record record : desired) {
            Object start = makePosition(contentSdk, book, record.startLong, record.startShort);
            Object brokenEnd = makeLegacyBrokenPosition(contentSdk, book, record.endLong);
            Object brokenHighlight = construct(
                "com.amazon.ebook.booklet.reader.impl.annotation.personal.Highlight",
                start,
                brokenEnd
            );
            syncNativeCloudEdit(readerSdk, brokenHighlight, book, nativePath, "DELETE",
                ksdkEnabled, whisperStoreEnabled, counters);
            counters.legacyCloudDeletes++;

            boolean hadNote = record.note.length() > 0
                || previousHadNote(previous, record);
            if (hadNote) {
                Object brokenNote = construct(
                    "com.amazon.ebook.booklet.reader.impl.annotation.personal.Note",
                    record.note,
                    start,
                    brokenEnd
                );
                syncNativeCloudEdit(readerSdk, brokenNote, book, nativePath, "DELETE",
                    ksdkEnabled, whisperStoreEnabled, counters);
                counters.legacyCloudDeletes++;
            }
        }
    }

    private static void verifyDesired(Map<String, Object> existing, List<Record> desired)
            throws Exception {
        for (Record record : desired) {
            Object highlight = existing.get(typedKey(1, record));
            if (highlight == null || !positionMatches(highlight, record)) {
                throw new IllegalStateException("native highlight durability check failed");
            }
            Object note = existing.get(typedKey(2, record));
            if (record.note.length() == 0) {
                if (note != null) {
                    throw new IllegalStateException("native note removal durability check failed");
                }
            } else {
                if (note == null || !positionMatches(note, record)) {
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
            RangeIdentity positions = splitRangeKey(oldRange);
            if (!positions.hasShortPositions()) {
                continue;
            }
            if (existing.containsKey(typedKey(1, positions))
                    || existing.containsKey(typedKey(2, positions))) {
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
            if (arguments[index] == null) {
                return false;
            }
            Class<?> parameter = parameters[index];
            Class<?> argument = arguments[index].getClass();
            if (parameter.isPrimitive()) {
                boolean boxed = (parameter == Boolean.TYPE && argument == Boolean.class)
                    || (parameter == Integer.TYPE && argument == Integer.class)
                    || (parameter == Long.TYPE && argument == Long.class)
                    || (parameter == Double.TYPE && argument == Double.class)
                    || (parameter == Float.TYPE && argument == Float.class)
                    || (parameter == Short.TYPE && argument == Short.class)
                    || (parameter == Byte.TYPE && argument == Byte.class)
                    || (parameter == Character.TYPE && argument == Character.class);
                if (!boxed) {
                    return false;
                }
            } else if (!parameter.isAssignableFrom(argument)) {
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

    private static int requireShortPosition(String value) {
        if (value == null || !value.matches("^[0-9]{1,10}$")) {
            throw new IllegalArgumentException("invalid KFX short position");
        }
        long parsed = Long.parseLong(value);
        if (parsed > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("KFX short position out of range");
        }
        return (int) parsed;
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

    private static String typedKey(int type, Record record) {
        return type + ":" + record.rangeKey();
    }

    private static String typedKey(int type, RangeIdentity range) {
        return type + ":" + range.key();
    }

    private static String pairKey(
        String startLong,
        int startShort,
        String endLong,
        int endShort
    ) {
        return new RangeIdentity(
            startLong, Integer.valueOf(startShort),
            endLong, Integer.valueOf(endShort)
        ).key();
    }

    private static boolean previousHadNote(
        Map<String, Boolean> previous,
        Record record
    ) {
        if (Boolean.TRUE.equals(previous.get(record.rangeKey()))) {
            return true;
        }
        RangeIdentity legacy = new RangeIdentity(
            record.startLong, null, record.endLong, null);
        return Boolean.TRUE.equals(previous.get(legacy.key()));
    }

    private static RangeIdentity splitRangeKey(String value) {
        if (value == null) throw new IllegalArgumentException("missing annotation key");
        int separator = value.indexOf(':');
        if (separator < 1 || separator != value.lastIndexOf(':')) {
            throw new IllegalArgumentException("invalid annotation key");
        }
        RangeEndpoint start = RangeEndpoint.parse(value.substring(0, separator));
        RangeEndpoint end = RangeEndpoint.parse(value.substring(separator + 1));
        if ((start.shortPosition == null) != (end.shortPosition == null)) {
            throw new IllegalArgumentException("mixed annotation key versions");
        }
        return new RangeIdentity(
            start.longPosition, start.shortPosition,
            end.longPosition, end.shortPosition);
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
        private final int startShort;
        private final String endLong;
        private final int endShort;
        private final String note;

        private Record(
            String startLong,
            int startShort,
            String endLong,
            int endShort,
            String note
        ) {
            this.startLong = startLong;
            this.startShort = startShort;
            this.endLong = endLong;
            this.endShort = endShort;
            this.note = note;
        }

        private String rangeKey() {
            return pairKey(startLong, startShort, endLong, endShort);
        }
    }

    private static final class RangeEndpoint {
        private final String longPosition;
        private final Integer shortPosition;

        private RangeEndpoint(String longPosition, Integer shortPosition) {
            this.longPosition = longPosition;
            this.shortPosition = shortPosition;
        }

        private static RangeEndpoint parse(String value) {
            int separator = value == null ? -1 : value.indexOf('@');
            if (separator < 0) {
                return new RangeEndpoint(requireLongPosition(value), null);
            }
            if (separator < 1 || separator != value.lastIndexOf('@')) {
                throw new IllegalArgumentException("invalid exact annotation key");
            }
            return new RangeEndpoint(
                requireLongPosition(value.substring(0, separator)),
                Integer.valueOf(requireShortPosition(value.substring(separator + 1))));
        }

        private String key() {
            return shortPosition == null
                ? longPosition
                : longPosition + "@" + shortPosition;
        }
    }

    private static final class RangeIdentity {
        private final String startLong;
        private final Integer startShort;
        private final String endLong;
        private final Integer endShort;

        private RangeIdentity(
            String startLong,
            Integer startShort,
            String endLong,
            Integer endShort
        ) {
            this.startLong = requireLongPosition(startLong);
            this.startShort = startShort;
            this.endLong = requireLongPosition(endLong);
            this.endShort = endShort;
            if ((startShort == null) != (endShort == null)) {
                throw new IllegalArgumentException("mixed annotation identity versions");
            }
            if (startShort != null
                    && (startShort.intValue() < 0 || endShort.intValue() < 0)) {
                throw new IllegalArgumentException("negative annotation offset");
            }
        }

        private boolean hasShortPositions() {
            return startShort != null;
        }

        private String key() {
            RangeEndpoint start = new RangeEndpoint(startLong, startShort);
            RangeEndpoint end = new RangeEndpoint(endLong, endShort);
            int order = startLong.compareTo(endLong);
            if (order == 0 && startShort != null) {
                order = Integer.compare(startShort.intValue(), endShort.intValue());
            }
            return order <= 0
                ? start.key() + ":" + end.key()
                : end.key() + ":" + start.key();
        }
    }

    private static final class Counters {
        private int highlightsCreated;
        private int highlightsDeleted;
        private int notesCreated;
        private int notesUpdated;
        private int notesDeleted;
        private int nativeNotifications;
        private int zeroEndpointRepairs;
        private int terminalEndpointRepairs;
        private int cloudEdits;
        private int legacyCloudDeletes;
        private int cloudSnapshots;
        private int ksdkWrites;
        private int nativeJournalEdits;
        private int nativeUploadRequests;

        private void write(PrintWriter out) {
            out.println("highlights_created=" + highlightsCreated);
            out.println("highlights_deleted=" + highlightsDeleted);
            out.println("notes_created=" + notesCreated);
            out.println("notes_updated=" + notesUpdated);
            out.println("notes_deleted=" + notesDeleted);
            out.println("native_notifications=" + nativeNotifications);
            out.println("zero_endpoint_repairs=" + zeroEndpointRepairs);
            out.println("terminal_endpoint_repairs=" + terminalEndpointRepairs);
            out.println("cloud_edits=" + cloudEdits);
            out.println("legacy_cloud_deletes=" + legacyCloudDeletes);
            out.println("cloud_snapshots=" + cloudSnapshots);
            out.println("ksdk_writes=" + ksdkWrites);
            out.println("native_journal_edits=" + nativeJournalEdits);
            out.println("native_upload_requests=" + nativeUploadRequests);
        }
    }
}
