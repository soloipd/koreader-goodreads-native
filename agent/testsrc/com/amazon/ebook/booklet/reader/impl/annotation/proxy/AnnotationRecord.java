package com.amazon.ebook.booklet.reader.impl.annotation.proxy;

public final class AnnotationRecord {
    private final Object annotation;

    private AnnotationRecord(Object annotation) {
        this.annotation = annotation;
    }

    public static AnnotationRecord a(BookData book, Object annotation) {
        if (book == null || annotation == null) {
            throw new IllegalArgumentException("book and annotation are required");
        }
        return new AnnotationRecord(annotation);
    }

    public Object annotation() {
        return annotation;
    }
}
