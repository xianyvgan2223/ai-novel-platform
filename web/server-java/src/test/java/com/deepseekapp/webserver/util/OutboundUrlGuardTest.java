package com.deepseekapp.webserver.util;

import com.deepseekapp.webserver.web.ApiException;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 出网地址守卫：下载只允许公网，模型地址只允许 https（本机代理除外）。 */
class OutboundUrlGuardTest {

    @Test
    void rejectsNonHttpSchemesAndCredentials() {
        assertThrows(ApiException.class, () -> OutboundUrlGuard.parseHttpUrl("ftp://example.com/a", "地址"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.parseHttpUrl("", "地址"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.parseHttpUrl("https://user:pass@example.com", "地址"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.parseHttpUrl("https://", "地址"));
    }

    @Test
    void modelBaseUrlRequiresHttpsForPublicHosts() {
        // 公网明文 http 会把 API Key 暴露在链路上
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requireModelBaseUrl("http://api.example.com"));
        assertEquals("https://api.example.com/", OutboundUrlGuard.requireModelBaseUrl("https://api.example.com/").toString());
        // 本机/内网代理允许 http
        assertEquals("http://127.0.0.1:8080", OutboundUrlGuard.requireModelBaseUrl("http://127.0.0.1:8080").toString());
        assertEquals("http://192.168.1.8:8000", OutboundUrlGuard.requireModelBaseUrl("http://192.168.1.8:8000").toString());
    }

    @Test
    void downloadRejectsPrivateHosts() {
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requirePublicHost("127.0.0.1"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requirePublicHost("localhost"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requirePublicHost("10.0.0.5"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requirePublicHost("192.168.1.1"));
        assertThrows(ApiException.class, () -> OutboundUrlGuard.requirePublicHost("169.254.169.254"));
        // 公网字面量不需要 DNS
        OutboundUrlGuard.requirePublicHost("1.1.1.1");
    }

    @Test
    void privateHostDetection() {
        assertTrue(OutboundUrlGuard.isPrivateHost("127.0.0.1"));
        assertTrue(OutboundUrlGuard.isPrivateHost("192.168.0.2"));
        assertFalse(OutboundUrlGuard.isPrivateHost("8.8.8.8"));
    }
}
