package com.deepseekapp.webserver.web;

import java.util.LinkedHashMap;
import java.util.Map;

public final class Api {

    private Api() {
    }

    public static Map<String, Object> ok(Object data) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", true);
        body.put("data", data);
        return body;
    }

    public static Map<String, Object> ok(Object data, Object meta) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", true);
        body.put("data", data);
        body.put("meta", meta);
        return body;
    }

    public static Map<String, Object> fail(String error) {
        return fail(error, null);
    }

    public static Map<String, Object> fail(String error, Map<String, Object> extra) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", false);
        body.put("error", error);
        if (extra != null) {
            body.putAll(extra);
        }
        return body;
    }
}
