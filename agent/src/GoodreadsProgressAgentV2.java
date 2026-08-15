import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.time.Instant;
import java.util.Locale;

/**
 * Sends one Goodreads percentage through the Kindle framework's existing,
 * authenticated Grok service. No account credentials are accepted or stored.
 */
public final class GoodreadsProgressAgentV2 {
    private static final String RESULT_PATH = "/tmp/goodreads-progress-result.log";
    private static final String COMPONENT = "SHARE_PROGRESS_FROM_CHROME";
    private static final String NETWORK = "goodreads";

    private GoodreadsProgressAgentV2() {}

    public static void agentmain(String arguments, Instrumentation instrumentation) {
        PrintWriter out;
        try {
            out = new PrintWriter(new FileWriter(RESULT_PATH, false));
        } catch (Throwable ignored) {
            return;
        }

        String stage = "parse_arguments";
        try {
            RequestArguments parsed = RequestArguments.parse(arguments);
            out.println("started_at=" + Instant.now());
            out.println("asin=" + parsed.asin);
            out.println("percent=" + parsed.percent);
            out.println("application=" + parsed.application);

            stage = "load_native_classes";
            Class<?> frameworkClass = Class.forName(
                "com.amazon.kindle.restricted.runtime.Framework"
            );
            Class<?> grokServiceClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.GrokService"
            );
            Class<?> grokRequestClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.GrokServiceRequest"
            );
            Class<?> grokTrackerClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.GrokRequestTracker"
            );
            Class<?> grokResponseClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.GrokServiceResponse"
            );
            Class<?> requestClass = Class.forName(
                "com.amazon.kindle.restricted.webservices.grok.PostShareProgressRequest"
            );
            Class<?> sharingServiceClass = Class.forName(
                "com.amazon.ebook.readersharing.service.ReaderSharingService"
            );

            Method getService = frameworkClass.getMethod("getService", Class.class);

            stage = "resolve_native_services";
            Object grokService = getService.invoke(null, grokServiceClass);
            Object sharingService = getService.invoke(null, sharingServiceClass);
            if (grokService == null) {
                throw new IllegalStateException("GrokService unavailable");
            }
            if (sharingService == null) {
                throw new IllegalStateException("ReaderSharingService unavailable");
            }

            stage = "construct_request";
            Object request = requestClass.getConstructor().newInstance();
            requestClass.getMethod("ha", String.class).invoke(request, parsed.asin);
            requestClass.getMethod("MQ", String.class).invoke(request, "Percent");
            requestClass.getMethod("iW", Integer.TYPE).invoke(
                request,
                Integer.valueOf(parsed.percent)
            );
            requestClass.getMethod("cF", String.class).invoke(
                request,
                Locale.getDefault().getLanguage()
            );
            requestClass.getMethod("B", String[].class).invoke(
                request,
                new Object[] { new String[] { NETWORK } }
            );

            stage = "set_native_headers";
            Object tracker = requestClass.getMethod("bBh").invoke(request);
            Method setHeader = grokTrackerClass.getMethod(
                "cU",
                String.class,
                String.class
            );
            setHeader.invoke(
                tracker,
                "x-gr-application-component",
                COMPONENT
            );
            setHeader.invoke(tracker, "x-gr-application", parsed.application);
            String sharingVersion = String.valueOf(
                sharingServiceClass.getMethod("aqB").invoke(sharingService)
            );
            setHeader.invoke(
                tracker,
                "x-gr-application-version",
                sharingVersion
            );

            stage = "send_request";
            Object response = grokServiceClass.getMethod("b", grokRequestClass).invoke(
                grokService,
                request
            );
            if (response == null) {
                throw new IllegalStateException("null Grok response");
            }

            stage = "read_response";
            int status = ((Integer) grokResponseClass.getMethod("EX").invoke(response))
                .intValue();
            boolean valid = ((Boolean) grokResponseClass.getMethod("isValid").invoke(response))
                .booleanValue();
            Object bodyValue = grokResponseClass.getMethod("bBj").invoke(response);
            String body = bodyValue == null ? "" : String.valueOf(bodyValue);
            boolean errorEnvelope = body.toLowerCase(Locale.ROOT).indexOf("<error") >= 0;
            boolean success = valid
                && (status == 200 || status == 202)
                && !errorEnvelope;

            out.println("http_status=" + status);
            out.println("response_valid=" + valid);
            out.println("error_envelope=" + errorEnvelope);
            out.println("success=" + success);
            out.println("finished_at=" + Instant.now());
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            out.println("success=false");
            out.println("failed_stage=" + stage);
            out.println("error_class=" + cause.getClass().getName());
        } finally {
            out.close();
        }
    }

    private static Throwable unwrap(Throwable error) {
        Throwable current = error;
        while (current instanceof InvocationTargetException) {
            Throwable cause = ((InvocationTargetException) current).getCause();
            if (cause == null) {
                break;
            }
            current = cause;
        }
        return current;
    }

    private static final class RequestArguments {
        private final String asin;
        private final int percent;
        private final String application;

        private RequestArguments(String asin, int percent, String application) {
            this.asin = asin;
            this.percent = percent;
            this.application = application;
        }

        private static RequestArguments parse(String value) {
            if (value == null) {
                throw new IllegalArgumentException("missing arguments");
            }
            String[] pieces = value.split(",", -1);
            if (pieces.length != 3) {
                throw new IllegalArgumentException("expected asin,percent,application");
            }
            if (!isSafeAsin(pieces[0])) {
                throw new IllegalArgumentException("invalid ASIN");
            }
            int parsedPercent = Integer.parseInt(pieces[1]);
            if (parsedPercent < 1 || parsedPercent > 100) {
                throw new IllegalArgumentException("invalid percentage");
            }
            if (!"reader.eink".equals(pieces[2])) {
                throw new IllegalArgumentException("invalid application");
            }
            return new RequestArguments(pieces[0], parsedPercent, pieces[2]);
        }

        private static boolean isSafeAsin(String value) {
            if (value == null || value.length() != 10 || value.charAt(0) != 'B') {
                return false;
            }
            for (int index = 1; index < value.length(); index++) {
                char character = value.charAt(index);
                boolean upper = character >= 'A' && character <= 'Z';
                boolean digit = character >= '0' && character <= '9';
                if (!upper && !digit) {
                    return false;
                }
            }
            return true;
        }

    }
}
