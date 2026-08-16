import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;

/** Read-only capability probe. It never creates or mutates annotations. */
public final class BackgroundAnnotationCapabilityProbeV1 {
    private static final String LOG_PATH =
        "/tmp/goodreads-background-capabilities.log";

    private BackgroundAnnotationCapabilityProbeV1() {}

    public static void agentmain(String ignored, Instrumentation instrumentation) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(LOG_PATH, false));
        } catch (Throwable error) {
            return;
        }

        try {
            Class<?> framework = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework");
            Method getService = framework.getMethod("getService", Class.class);
            Class<?> readerType = Class.forName(
                "com.amazon.ebook.booklet.reader.sdk.ReaderSDK");
            Class<?> journalType = Class.forName(
                "com.amazon.kindle.content.journal.JournalingService");
            Class<?> whisperType = Class.forName(
                "com.amazon.kindle.restricted.webservices.whispersync.v1.WhisperSyncV1");

            Object reader = getService.invoke(null, readerType);
            Object journal = getService.invoke(null, journalType);
            Object whisper = getService.invoke(null, whisperType);

            out.println("probe_version=1");
            out.println("instrumentation_present=" + (instrumentation != null));
            out.println("reader_sdk_present=" + (reader != null));
            out.println("journaling_service_present=" + (journal != null));
            out.println("whispersync_service_present=" + (whisper != null));
            out.println("journal_book_factory_present="
                + hasMethodArity(journalType, "a", 6));
            out.println("journal_entry_factory_present="
                + hasMethodArity(journalType, "a", 11));
            out.println("reader_active_book_method_present="
                + hasMethodArity(readerType, "jy", 0));
            out.println("native_book_active=" + hasActiveBook(reader, readerType));
            out.println("ksdk_enabled=" + invokeStaticBoolean(
                "com.amazon.ebook.booklet.reader.impl.annotation.proxy.ksdkannotations.KSDKAnnotationsConfig",
                "Em"));
            out.println("whisperstore_enabled=" + invokeStaticBoolean(
                "com.amazon.ebook.booklet.reader.impl.whisperstore.WhisperStoreKwisUtils",
                "Ls"));
            out.println("mutation_attempted=false");
            out.println("probe_ok=true");
        } catch (Throwable error) {
            out.println("mutation_attempted=false");
            out.println("probe_ok=false");
            out.println("error_class=" + error.getClass().getName());
        } finally {
            out.close();
        }
    }

    private static boolean hasMethodArity(Class<?> type, String name, int arity) {
        for (Method method : type.getMethods()) {
            if (method.getName().equals(name)
                    && method.getParameterTypes().length == arity) {
                return true;
            }
        }
        for (Method method : type.getDeclaredMethods()) {
            if (method.getName().equals(name)
                    && method.getParameterTypes().length == arity) {
                return true;
            }
        }
        return false;
    }

    private static boolean hasActiveBook(Object reader, Class<?> readerType) {
        if (reader == null) {
            return false;
        }
        try {
            return readerType.getMethod("jy").invoke(reader) != null;
        } catch (Throwable error) {
            return false;
        }
    }

    private static boolean invokeStaticBoolean(String className, String methodName) {
        try {
            Object value = Class.forName(className).getMethod(methodName).invoke(null);
            return Boolean.TRUE.equals(value);
        } catch (Throwable error) {
            return false;
        }
    }
}
