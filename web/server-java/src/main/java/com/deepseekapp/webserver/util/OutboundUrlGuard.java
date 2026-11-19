package com.deepseekapp.webserver.util;

import com.deepseekapp.webserver.web.ApiException;

import java.net.InetAddress;
import java.net.URI;
import java.util.Locale;

/**
 * 出网地址守卫：Agent 下载与模型 baseUrl 共用。
 *
 * <p>这里只做「地址是否允许出网」的判断，不负责发请求：
 * 下载侧要求每一跳都是公网地址（防止内网探测），模型 baseUrl 允许
 * 本机/内网 + http（本地代理场景），其余必须是 https。</p>
 */
public final class OutboundUrlGuard {

    private static final int MAX_URL = 1000;

    private OutboundUrlGuard() {
    }

    /** 解析并校验基本形态：http/https、有主机名、不含账号密码。 */
    public static URI parseHttpUrl(String raw, String label) {
        String value = raw == null ? "" : raw.trim();
        if (value.isEmpty()) {
            throw new ApiException(400, label + "不能为空");
        }
        if (value.length() > MAX_URL) {
            throw new ApiException(400, label + "过长");
        }
        URI uri;
        try {
            uri = URI.create(value);
        } catch (IllegalArgumentException e) {
            throw new ApiException(400, label + "格式不正确");
        }
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            throw new ApiException(400, label + "只支持 http/https");
        }
        if (uri.getHost() == null || uri.getHost().isBlank()) {
            throw new ApiException(400, label + "缺少主机名");
        }
        if (uri.getUserInfo() != null) {
            throw new ApiException(400, label + "不能包含账号密码");
        }
        return uri;
    }

    /** 下载用：主机必须是公网地址，解析失败直接拒绝。 */
    public static void requirePublicHost(String host) {
        if (host == null || host.isBlank()) {
            throw new ApiException(400, "下载地址缺少主机名");
        }
        InetAddress[] addresses;
        try {
            addresses = InetAddress.getAllByName(host);
        } catch (Exception e) {
            throw new ApiException(400, "无法解析下载地址的主机名");
        }
        for (InetAddress address : addresses) {
            if (isBlocked(address)) {
                throw new ApiException(400, "不允许下载本机或内网地址");
            }
        }
    }

    /** 模型 baseUrl 用：https，或「本机/内网 + http」的本地代理。 */
    public static URI requireModelBaseUrl(String raw) {
        URI uri = parseHttpUrl(raw, "模型地址");
        if ("https".equalsIgnoreCase(uri.getScheme())) {
            return uri;
        }
        if (!isPrivateHost(uri.getHost())) {
            throw new ApiException(400, "模型地址必须使用 https（本机或内网代理除外）");
        }
        return uri;
    }

    public static boolean isPrivateHost(String host) {
        if (host == null || host.isBlank()) {
            return false;
        }
        try {
            for (InetAddress address : InetAddress.getAllByName(host)) {
                if (isBlocked(address)) {
                    return true;
                }
            }
        } catch (Exception e) {
            return false;
        }
        return false;
    }

    private static boolean isBlocked(InetAddress address) {
        if (address.isLoopbackAddress() || address.isSiteLocalAddress() || address.isLinkLocalAddress()
                || address.isAnyLocalAddress() || address.isMulticastAddress()) {
            return true;
        }
        byte[] bytes = address.getAddress();
        if (bytes.length == 16) {
            // IPv6 唯一本地地址 fc00::/7
            return (bytes[0] & 0xfe) == 0xfc;
        }
        // IPv4 运营商级 NAT 100.64.0.0/10
        return bytes.length == 4 && (bytes[0] & 0xff) == 100 && (bytes[1] & 0xc0) == 64;
    }
}
