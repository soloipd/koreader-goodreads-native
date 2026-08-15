package com.amazon.kindle.restricted.runtime;

public final class Framework {
    private static Object service;

    private Framework() {}

    public static Object getService(Class<?> ignored) {
        return service;
    }

    public static void setService(Object value) {
        service = value;
    }
}
