package com.amazon.ebook.booklet.reader.impl.annotation.proxy;

import java.util.Optional;
import testsupport.Fakes;

public final class BookData {
    private BookData() {}

    public static Optional<BookData> ah(Fakes.Book book) {
        return book == null ? Optional.<BookData>empty() : Optional.of(new BookData());
    }
}
