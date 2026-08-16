package com.amazon.ebook.booklet.reader.impl.annotation.personal;

import testsupport.Fakes;
import com.amazon.ebook.booklet.reader.sdk.content.annotation.Annotation;
import java.util.HashMap;

public class Highlight implements Annotation {
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

    public Object Cf() {
        return new HashMap<String, String>();
    }

    public Object L() { return null; }

    public Object Cd() { return null; }
}
