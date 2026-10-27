package com.deepseekapp.webserver.web;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.sync.SyncStore;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;
import java.util.regex.Pattern;

/** 「这次请求看的是哪台设备的数据」解析（请求头 x-device-id，默认 web-console） */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class DeviceContextFilter extends OncePerRequestFilter {

    private static final List<Pattern> BYPASS = List.of(
            Pattern.compile("^/health$"),
            Pattern.compile("^/sync/push$"),
            Pattern.compile("^/sync/pull$"),
            Pattern.compile("^/sync/pending$"),
            Pattern.compile("^/sync/progress$"),
            Pattern.compile("^/sync/request(/.*)?$"),
            Pattern.compile("^/sync/requests$"),
            Pattern.compile("^/sync/devices(/|$)$"),
            Pattern.compile("^/sync/self$"),
            Pattern.compile("^/sync/conflicts$"),
            Pattern.compile("^/app/latest$"),
            Pattern.compile("^/app/download(/.*)?$"),
            Pattern.compile("^/app/upload$"),
            Pattern.compile("^/catalog$"));

    private final AppProperties props;
    private final SyncStore syncStore;
    private final ObjectMapper mapper;

    public DeviceContextFilter(AppProperties props, SyncStore syncStore, ObjectMapper mapper) {
        this.props = props;
        this.syncStore = syncStore;
        this.mapper = mapper;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        String uri = request.getRequestURI();
        if (!uri.startsWith("/api")) {
            chain.doFilter(request, response);
            return;
        }
        String relative = uri.substring(4).replaceAll("/+$", "");
        if (relative.isEmpty()) {
            relative = "/";
        }
        final String path = relative;

        String deviceId = RequestDevice.deviceId(request, props);
        if (!BYPASS.stream().anyMatch(p -> p.matcher(path).matches())) {
            if (!syncStore.deviceExists(deviceId)) {
                List<String> known = syncStore.knownDeviceIds();
                String message = "设备不存在：" + deviceId + "。可用设备：" +
                        (known.isEmpty() ? "（还没有任何设备，请先让手机同步一次）" : String.join("、", known));
                response.setStatus(404);
                response.setContentType("application/json");
                response.setCharacterEncoding("UTF-8");
                mapper.writeValue(response.getOutputStream(), Api.fail(message));
                return;
            }
        }
        request.setAttribute(RequestDevice.ATTRIBUTE, deviceId);
        chain.doFilter(request, response);
    }
}
