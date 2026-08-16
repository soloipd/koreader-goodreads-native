package com.amazon.kindle.content.journal;

public final class JournaledBook {
    public final Object book;
    public JournaledBook(Object book) { this.book = book; }
    public JournaledBook(String path, String cdeKey, String cdeType, int version,
            String guid, String format) {
        this.book = path + "|" + cdeKey + "|" + cdeType + "|" + version
            + "|" + guid + "|" + format;
    }
}
