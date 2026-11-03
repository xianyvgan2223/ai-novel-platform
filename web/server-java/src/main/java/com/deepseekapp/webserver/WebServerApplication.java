package com.deepseekapp.webserver;

import com.deepseekapp.webserver.usb.UsbTunnel;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

@SpringBootApplication
public class WebServerApplication {

    public static void main(String[] args) {
        loadDotEnv();
        if (Arrays.asList(args).contains("--usb")) {
            UsbTunnel.runFromArgs(args);
            return;
        }
        SpringApplication.run(WebServerApplication.class, args);
    }

    /**
     * Spring AI 从 application.yml 的 ${DEEPSEEK_API_KEY} 读取密钥；
     * 这里把 web/server/.env 的值补进 System property，保证 Java 端也能复用同一份配置。
     * 环境变量优先级最高，其次才是 .env。
     */
    private static void loadDotEnv() {
        String userDir = System.getProperty("user.dir");
        List<Path> candidates = List.of(
                Path.of(userDir, "..", "server", ".env"),
                Path.of(userDir, ".env"));
        for (Path candidate : candidates) {
            if (!Files.isRegularFile(candidate)) {
                continue;
            }
            try {
                for (String line : Files.readAllLines(candidate, StandardCharsets.UTF_8)) {
                    String trimmed = line.trim();
                    if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                        continue;
                    }
                    int eq = trimmed.indexOf('=');
                    if (eq <= 0) {
                        continue;
                    }
                    String key = trimmed.substring(0, eq).trim();
                    String value = trimmed.substring(eq + 1).trim();
                    if (value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
                        value = value.substring(1, value.length() - 1);
                    }
                    if (System.getenv(key) == null && System.getProperty(key) == null) {
                        System.setProperty(key, value);
                    }
                }
                return;
            } catch (IOException ignored) {
                // 读不到就继续尝试下一个位置
            }
        }
    }
}
