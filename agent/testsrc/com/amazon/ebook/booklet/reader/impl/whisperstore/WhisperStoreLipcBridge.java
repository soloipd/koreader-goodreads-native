package com.amazon.ebook.booklet.reader.impl.whisperstore;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import com.amazon.ebook.booklet.reader.sdk.content.annotation.Annotation;

public final class WhisperStoreLipcBridge {
    public static final List<String> operations = new ArrayList<String>();

    private WhisperStoreLipcBridge() {}

    public static void reset() {
        operations.clear();
    }

    public static boolean a(Annotation annotation, Object book, boolean create) {
        if (annotation.Cf() != null) {
            String ignored = (String) annotation.Cf();
        }
        operations.add(create ? "CREATE" : "UPDATE");
        return annotation != null && book != null;
    }

    public static boolean d(Annotation annotation, Object book) {
        operations.add("DELETE");
        return annotation != null && book != null;
    }

    public static boolean b(Map<String, Object> payload, Object book) {
        operations.add("SNAPSHOT");
        return payload != null && payload.get("all_annotations") != null && book != null;
    }
}
