package com.deepseekapp.webserver.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.context.ServletWebServerApplicationContext;
import org.springframework.context.ApplicationContext;
import org.springframework.stereotype.Component;
import org.springframework.boot.web.server.WebServer;

@Component
public class ServerInfo {

    private final ApplicationContext context;
    private final int configuredPort;
    private final String host;

    public ServerInfo(ApplicationContext context,
                      @Value("${server.port:3210}") int configuredPort,
                      @Value("${server.address:0.0.0.0}") String host) {
        this.context = context;
        this.configuredPort = configuredPort;
        this.host = host;
    }

    public int port() {
        if (context instanceof ServletWebServerApplicationContext servletContext) {
            WebServer server = servletContext.getWebServer();
            if (server != null) {
                return server.getPort();
            }
        }
        return configuredPort;
    }

    public String host() {
        return host;
    }
}
