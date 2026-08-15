package com.amazon.ebook.booklet.reader.impl.annotation.personal;

import testsupport.Fakes;

public class Highlight {
    private final Fakes.Position start;
    private final Fakes.Position end;

    public Highlight(Fakes.Position start, Fakes.Position end) {
        this.start = start;
        this.end = end;
    }

    public Integer jm() {
        return Integer.valueOf(1);
    }

    public Fakes.Position jh() {
        return start;
    }

    public Fakes.Position jd() {
        return end;
    }
}
