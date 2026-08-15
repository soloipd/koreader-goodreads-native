import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.time.Instant;

/**
 * Read-only probe loaded into the Kindle Java framework with the standard
 * Attach API. It verifies that the native Goodreads/Grok services are visible
 * to an agent before any progress request is attempted.
 */
public final class ProbeAgent {
    private static final String LOG_PATH = "/tmp/goodreads-agent-probe.log";

    private ProbeAgent() {}

    public static void agentmain(String arguments, Instrumentation instrumentation) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(LOG_PATH, false));
        } catch (Throwable ignored) {
            return;
        }

        try {
            out.println("loaded_at=" + Instant.now());
            out.println("agent_args=" + (arguments == null ? "" : arguments));
            out.println("instrumentation=" + (instrumentation != null));

            Class<?> frameworkClass = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework"
            );
            Class<?> grokServiceClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.GrokService"
            );
            Class<?> requestClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.PostShareProgressRequest"
            );

            Method getService = frameworkClass.getMethod("getService", Class.class);
            Object grokService = getService.invoke(null, grokServiceClass);

            out.println("framework_classloader=" + frameworkClass.getClassLoader());
            out.println("request_classloader=" + requestClass.getClassLoader());
            out.println("grok_service_present=" + (grokService != null));
            out.println(
                "grok_service_class="
                    + (grokService == null ? "" : grokService.getClass().getName())
            );

            if (grokService != null) {
                Method getState = grokServiceClass.getMethod("bAZ");
                Object state = getState.invoke(grokService);
                out.println("grok_state=" + String.valueOf(state));
            }

            out.println("probe_ok=true");
        } catch (Throwable error) {
            out.println("probe_ok=false");
            error.printStackTrace(out);
        } finally {
            out.close();
        }
    }
}
