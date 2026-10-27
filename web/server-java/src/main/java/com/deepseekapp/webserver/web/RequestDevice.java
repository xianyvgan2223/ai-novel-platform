package com.deepseekapp.webserver.web;

import com.deepseekapp.webserver.config.AppProperties;
import jakarta.servlet.http.HttpServletRequest;

public final class RequestDevice {

    public static final String ATTRIBUTE = "deviceId";

    private RequestDevice() {
    }

    public static String deviceId(HttpServletRequest request, AppProperties props) {
        Object attribute = request.getAttribute(ATTRIBUTE);
        if (attribute instanceof String value && !value.isEmpty()) {
            return value;
        }
        String header = request.getHeader("x-device-id");
        if (header != null && !header.isBlank()) {
            return header.trim();
        }
        return props.getWebDeviceId();
    }
}
