package com.amazon.ebook.booklet.reader.impl.annotation.personal;

import testsupport.Fakes;

public class Note {
    private String text;
    private final Fakes.Position start;
    private final Fakes.Position end;

    public Note(String text, Fakes.Position start, Fakes.Position end) {
        this.text = text;
        this.start = start;
        this.end = end;
    }

    public Integer jm() {
        return Integer.valueOf(2);
    }

    public Fakes.Position jh() {
        return start;
    }

    public Fakes.Position jd() {
        return end;
    }

    public String getText() {
        return text;
    }

    public void setText(String value) {
        text = value;
    }
}
