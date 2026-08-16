package com.amazon.kindle.content.journal;

public final class JournalEntry {
    public final JournalType type;
    public final JournalAction action;
    public JournalEntry(JournalType type, JournalAction action) {
        this.type = type;
        this.action = action;
    }
}
