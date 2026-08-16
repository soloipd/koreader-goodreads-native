package testsupport;

import com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;
import com.amazon.kindle.content.journal.JournalingService;
import com.amazon.kindle.restricted.webservices.whispersync.v1.WhisperSyncV1;

public final class Fakes {
    private Fakes() {}

    public static final class Position {
        private final String encoded;
        private final int shortPosition;

        public Position(String encoded) {
            this(encoded, 0);
        }

        public Position(String encoded, int shortPosition) {
            this.encoded = encoded;
            this.shortPosition = shortPosition;
        }

        public Position(Book ignored, String encoded, int shortPosition) {
            this(encoded, shortPosition);
        }

        public String nX() {
            return encoded;
        }

        public Integer UF() {
            return Integer.valueOf(shortPosition);
        }
    }

    public static final class Book {
        public boolean closed;
        private final Metadata metadata;
        private final String path;

        public Book() {
            this("test-guid", "/mnt/us/documents/Test_B0FLB24198.kfx");
        }

        public Book(String guid) {
            this(guid, "/mnt/us/documents/Test_B0FLB24198.kfx");
        }

        public Book(String guid, String path) {
            metadata = new Metadata(guid);
            this.path = path;
        }

        public void close() {
            closed = true;
        }

        public AnnotationProvider Uc() {
            return new AnnotationProvider();
        }

        public String getPath() { return path; }
        public Integer jm() { return Integer.valueOf(4); }

        public Metadata jg() {
            return metadata;
        }
    }

    public static final class Metadata {
        private final String guid;
        public Metadata(String guid) { this.guid = guid; }
        public String getASIN() { return "B0FLB24198"; }
        public String getCdeKey() { return "B0FLB24198"; }
        public String getCdeType() { return "EBOK"; }
        public Integer getVersion() { return Integer.valueOf(0); }
        public String getGUID() { return guid; }
    }

    public static final class AnnotationProvider {
        public Map<String, Object> j(Book ignored) {
            Map<String, Object> payload = new HashMap<String, Object>();
            payload.put("all_annotations", "[]");
            return payload;
        }
    }

    public static final class PositionFactory {
        public final Map<String, Integer> shortPositions = new HashMap<String, Integer>();

        public void register(String encoded, int shortPosition) {
            shortPositions.put(encoded, Integer.valueOf(shortPosition));
        }

        public Position a(String encoded, Book ignored) {
            Integer shortPosition = shortPositions.get(encoded);
            return new Position(encoded, shortPosition == null ? 0 : shortPosition.intValue());
        }
    }

    public static final class AnnotationManager {
        public final List<Object> annotations = new ArrayList<Object>();

        public List<Object> Q(Book ignored) {
            return new ArrayList<Object>(annotations);
        }

        public boolean c(Object annotation, Book ignored) {
            throw new AssertionError("high-level create must not be used");
        }

        public boolean e(Object annotation, Book ignored) {
            throw new AssertionError("high-level update must not be used");
        }

        public boolean d(Object annotation, Book ignored) {
            throw new AssertionError("high-level delete must not be used");
        }

        public boolean f(Object annotation, Book ignored) {
            annotations.add(annotation);
            return true;
        }

        public boolean h(Object annotation, Book ignored) {
            return annotations.contains(annotation);
        }

        public boolean g(Object annotation, Book ignored) {
            return annotations.remove(annotation);
        }
    }

    public static final class ContentSDK {
        public final AnnotationManager manager = new AnnotationManager();
        public final PositionFactory positions = new PositionFactory();
        public Book lastBook;

        public ContentSDK() {
            positions.register("AAAAAAAAAAAA", 100);
            positions.register("AAAAAAAAAAAB", 200);
            positions.register("AAAAAAAAAAAC", 300);
            positions.register("AAAAAAAAAAAD", 400);
        }

        public Book dt(String ignoredPath) {
            lastBook = new Book();
            return lastBook;
        }

        public AnnotationManager xA() {
            return manager;
        }

        public PositionFactory E(Book ignored) {
            return positions;
        }
    }

    public static final class SDK {
        public final ContentSDK content = new ContentSDK();
        public final AnnotationProxy proxy = new AnnotationProxy();
        public final JournalingService journaling = new JournalingService();
        public final WhisperSyncV1 whisperSync = new WhisperSyncV1();
        public final Context context = new Context(journaling);
        public Book activeBook;

        public ContentSDK jE() {
            return content;
        }

        public Book jy() {
            return activeBook;
        }

        public AnnotationProxy xB() {
            return proxy;
        }

        public Context xn() {
            return context;
        }

        public Object getService(Class<?> type) {
            if (type.getName().equals("com.amazon.kindle.content.journal.JournalingService")) {
                return journaling;
            }
            if (type.getName().equals(
                    "com.amazon.kindle.restricted.webservices.whispersync.v1.WhisperSyncV1")) {
                return whisperSync;
            }
            return null;
        }
    }

    public static final class Context {
        private final JournalingService journaling;
        public Context(JournalingService journaling) { this.journaling = journaling; }
        public Object getService(Class<?> type) {
            if (type.getName().equals("com.amazon.kindle.content.journal.JournalingService")) {
                return journaling;
            }
            return null;
        }
    }

    public static final class AnnotationProxy {
        public final List<AnnotationWriteOperationType> operations =
            new ArrayList<AnnotationWriteOperationType>();
        public final List<AnnotationWriteOperationType> ksdkOperations =
            new ArrayList<AnnotationWriteOperationType>();

        public void a(Object record, AnnotationWriteOperationType operation) {
            if (record == null) {
                throw new AssertionError("native notification requires an annotation record");
            }
            operations.add(operation);
        }

        public void a(
            com.amazon.ebook.booklet.reader.sdk.content.annotation.Annotation annotation,
            Book book,
            AnnotationWriteOperationType operation
        ) {
            if (annotation == null || book == null) {
                throw new AssertionError("KSDK write requires annotation and book");
            }
            ksdkOperations.add(operation);
        }
    }
}
