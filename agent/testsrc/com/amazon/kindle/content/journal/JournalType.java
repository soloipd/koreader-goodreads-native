package com.amazon.kindle.content.journal;

public final class JournalType {
    public static final JournalType HIGHLIGHT = new JournalType("highlight");
    public static final JournalType NOTE = new JournalType("note");
    private final String name;

    public JournalType(String name) { this.name = name; }
    public String toString() { return name; }
}
