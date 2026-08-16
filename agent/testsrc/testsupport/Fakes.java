package testsupport;

import com.amazon.ebook.booklet.reader.impl.annotation.AnnotationWriteOperationType;
import java.util.ArrayList;
import java.util.List;
import java.util.HashMap;
import java.util.Map;

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

        public void close() {
            closed = true;
        }

        public AnnotationProvider Uc() {
            return new AnnotationProvider();
        }

        public Metadata jg() {
            return new Metadata();
        }
    }

    public static final class Metadata {
        public String getASIN() { return "B0FLB24198"; }
        public String getCdeType() { return "EBOK"; }
        public String getGUID() { return "test-guid"; }
    }

    public static final class AnnotationProvider {
        public Map<String, Object> j(Book ignored) {
            Map<String, Object> payload = new HashMap<String, Object>();
            payload.put("all_annotations", "[]");
            return payload;
        }
    }

    public static final class PositionFactory {
        public Position a(String encoded, Book ignored) {
            return new Position(encoded);
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
        public Book lastBook;

        public Book dt(String ignoredPath) {
            lastBook = new Book();
            return lastBook;
        }

        public AnnotationManager xA() {
            return manager;
        }

        public PositionFactory E(Book ignored) {
            return new PositionFactory();
        }
    }

    public static final class SDK {
        public final ContentSDK content = new ContentSDK();
        public final AnnotationProxy proxy = new AnnotationProxy();

        public ContentSDK jE() {
            return content;
        }

        public AnnotationProxy xB() {
            return proxy;
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
