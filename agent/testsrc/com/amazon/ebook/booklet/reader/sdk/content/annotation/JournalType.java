package com.amazon.ebook.booklet.reader.sdk.content.annotation;

public final class JournalType {
    public static final JournalType HIGHLIGHT = new JournalType("highlight");
    public static final JournalType NOTE = new JournalType("note");
    private final String name;

    private JournalType(String name) { this.name = name; }
    public String toString() { return name; }
}
