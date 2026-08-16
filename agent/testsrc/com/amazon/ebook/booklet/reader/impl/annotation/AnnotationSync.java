package com.amazon.ebook.booklet.reader.impl.annotation;

import com.amazon.ebook.booklet.reader.sdk.content.annotation.JournalType;
import com.amazon.kindle.content.journal.JournaledBook;
import testsupport.Fakes;

public final class AnnotationSync {
    private static com.amazon.kindle.content.journal.JournalType a(JournalType type) {
        return type == JournalType.NOTE
            ? com.amazon.kindle.content.journal.JournalType.NOTE
            : com.amazon.kindle.content.journal.JournalType.HIGHLIGHT;
    }

    private static JournaledBook V(Fakes.Book book) {
        return new JournaledBook(book);
    }
}
