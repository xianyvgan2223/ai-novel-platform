package com.deepseekapp.webserver.web;

import java.util.Map;

public class ApiException extends RuntimeException {

    private final int status;
    private final Map<String, Object> extra;

    public ApiException(int status, String message) {
        this(status, message, null);
    }

    public ApiException(int status, String message, Map<String, Object> extra) {
        super(message);
        this.status = status;
        this.extra = extra;
    }

    public int getStatus() {
        return status;
    }

    public Map<String, Object> getExtra() {
        return extra;
    }
}
