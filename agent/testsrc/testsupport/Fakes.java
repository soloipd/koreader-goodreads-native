package testsupport;

import java.util.ArrayList;
import java.util.List;

public final class Fakes {
    private Fakes() {}

    public static final class Position {
        private final String encoded;

        public Position(String encoded) {
            this.encoded = encoded;
        }

        public String nX() {
            return encoded;
        }
    }

    public static final class Book {
        public boolean closed;

        public void close() {
            closed = true;
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
            annotations.add(annotation);
            return true;
        }

        public boolean e(Object annotation, Book ignored) {
            return annotations.contains(annotation);
        }

        public boolean d(Object annotation, Book ignored) {
            return annotations.remove(annotation);
        }

        public boolean f(Object annotation, Book ignored) {
            throw new AssertionError("low-level create must not be used");
        }

        public boolean h(Object annotation, Book ignored) {
            throw new AssertionError("low-level update must not be used");
        }

        public boolean g(Object annotation, Book ignored) {
            throw new AssertionError("low-level delete must not be used");
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

        public ContentSDK jE() {
            return content;
        }
    }
}
