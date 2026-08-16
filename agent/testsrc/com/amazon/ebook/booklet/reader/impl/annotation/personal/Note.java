package com.amazon.ebook.booklet.reader.impl.annotation.personal;

import testsupport.Fakes;
import com.amazon.ebook.booklet.reader.sdk.content.annotation.Annotation;
import com.amazon.ebook.booklet.reader.sdk.content.annotation.AnnotationExport;
import com.amazon.ebook.booklet.reader.sdk.content.annotation.JournalType;

public class Note implements Annotation {
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

    public Object Cf() { return text; }

    public Object L() { return null; }

    public Object Cd() { return null; }

    public AnnotationExport Ci() {
        AnnotationExport value = new AnnotationExport();
        value.czc = start.UF().intValue();
        value.czd = end.UF().intValue();
        value.czf = text;
        return value;
    }

    public JournalType CS() { return JournalType.NOTE; }
}
