package com.deepseekapp.webserver.web;

import com.deepseekapp.webserver.config.AppProperties;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

@Controller
public class HomeController {

    private final AppProperties props;

    public HomeController(AppProperties props) {
        this.props = props;
    }

    /** 有前端构建产物就返回 index.html，否则给出构建提示 */
    @GetMapping("/")
    public ResponseEntity<Resource> home() {
        Path index = props.webDistPath().resolve("index.html");
        if (Files.isRegularFile(index)) {
            return ResponseEntity.ok()
                    .contentType(MediaType.TEXT_HTML)
                    .body(new FileSystemResource(index));
        }
        String html = """
                <h1>deepseekapp web 同步服务已启动（Spring Boot）</h1>
                <p>前端尚未构建：请在 <code>web/app</code> 目录执行
                <code>npm install &amp;&amp; npm run build</code>，
                或执行 <code>npm run dev</code> 使用 http://localhost:5173 访问开发版。</p>
                <p>接口文档见 <code>web/docs/同步协议.md</code>。</p>
                """;
        return ResponseEntity.ok()
                .contentType(MediaType.TEXT_HTML)
                .body(new ByteArrayResource(html.getBytes(StandardCharsets.UTF_8)));
    }
}
