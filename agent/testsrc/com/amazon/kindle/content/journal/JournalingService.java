package com.amazon.kindle.content.journal;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public class JournalingService {
    public final List<JournalEntry> entries = new ArrayList<JournalEntry>();
    public final List<JournaledBook> books = new ArrayList<JournaledBook>();

    public JournaledBook a(String path, String cdeKey, String cdeType, int version,
            String guid, String format) {
        return new JournaledBook(path, cdeKey, cdeType, version, guid, format);
    }

    public JournalEntry a(
        JournalType type,
        JournalAction action,
        int start,
        int end,
        String text,
        Map<?, ?> metadata,
        int position,
        long readTime,
        long readingPosition,
        byte[] state,
        long timestamp
    ) {
        return new JournalEntry(type, action);
    }

    public void a(JournaledBook book, JournalEntry entry) {
        books.add(book);
        entries.add(entry);
    }
}
