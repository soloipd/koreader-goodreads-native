package com.amazon.kindle.content.journal;

public final class JournalAction {
    public static final JournalAction gbb = new JournalAction("create");
    public static final JournalAction gbc = new JournalAction("delete");
    public static final JournalAction gbd = new JournalAction("update");
    private final String name;

    private JournalAction(String name) { this.name = name; }
    public String toString() { return name; }
}
