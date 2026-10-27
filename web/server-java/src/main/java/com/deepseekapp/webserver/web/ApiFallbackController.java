package com.deepseekapp.webserver.web;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/** /api 下没有匹配到任何接口时，保持与其他接口一致的 JSON 错误格式 */
@RestController
public class ApiFallbackController {

    @RequestMapping({"/api", "/api/**"})
    public ResponseEntity<Map<String, Object>> notFound(HttpServletRequest request) {
        return ResponseEntity.status(404)
                .body(Api.fail("接口不存在：" + request.getMethod() + " " + request.getRequestURI()));
    }
}
