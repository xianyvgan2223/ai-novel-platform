package com.deepseekapp.webserver.util;

import org.springframework.stereotype.Component;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/** 本机网络地址探测（/api/net 与启动横幅共用） */
@Component
public class NetworkUtil {

    private static final Pattern VIRTUAL_HINTS = Pattern.compile(
            "(vmware|virtualbox|hyper-v|vethernet|wsl|docker|loopback|radmin|hamachi|tailscale|zerotier|npcap|tap)",
            Pattern.CASE_INSENSITIVE);

    private static final List<String> HOTSPOT_GATEWAYS = List.of(
            "192.168.43.1", "192.168.42.1", "192.168.137.1", "172.20.10.1");

    public record LanAddress(String name, String address, int rank, boolean isVirtual) {
    }

    public List<LanAddress> lanAddresses() {
        List<LanAddress> out = new ArrayList<>();
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            if (interfaces == null) {
                return out;
            }
            while (interfaces.hasMoreElements()) {
                NetworkInterface ni = interfaces.nextElement();
                String name = ni.getDisplayName() == null ? ni.getName() : ni.getDisplayName();
                Enumeration<InetAddress> addresses = ni.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress address = addresses.nextElement();
                    if (!(address instanceof Inet4Address) || address.isLoopbackAddress()
                            || address.isAnyLocalAddress()) {
                        continue;
                    }
                    String ip = address.getHostAddress();
                    boolean isVirtual = VIRTUAL_HINTS.matcher(name).find() || ip.startsWith("169.254.");
                    int rank = isVirtual ? 2 : (ip.startsWith("192.168.") || ip.startsWith("10.")) ? 0 : 1;
                    out.add(new LanAddress(name, ip, rank, isVirtual));
                }
            }
        } catch (Exception e) {
            // 网络探测失败时不阻塞服务启动
        }
        out.sort(Comparator.comparingInt(LanAddress::rank));
        return out;
    }

    public List<Map<String, Object>> connectionCandidates(int port) {
        List<LanAddress> addresses = lanAddresses();
        List<Map<String, Object>> candidates = new ArrayList<>();

        candidates.add(candidate(
                "USB 隧道（adb reverse）",
                "http://127.0.0.1:" + port,
                "usb",
                true,
                "手机插着数据线时用这条：在电脑上以 --usb 模式启动本服务即可打通，不怕防火墙。"));

        candidates.add(candidate(
                "本机（电脑自己的浏览器）",
                "http://localhost:" + port,
                "local",
                true,
                "只在电脑上打开网页时用。"));

        for (LanAddress address : addresses) {
            if (address.isVirtual()) {
                continue;
            }
            candidates.add(candidate(
                    "局域网 · " + address.name(),
                    "http://" + address.address() + ":" + port,
                    "lan",
                    true,
                    HOTSPOT_GATEWAYS.contains(address.address())
                            ? "这个地址像手机热点/USB 共享的网关，手机连它通常最稳。"
                            : "手机与电脑连同一个 Wi-Fi / 热点时用这条。"));
        }

        for (LanAddress address : addresses) {
            if (!address.isVirtual()) {
                continue;
            }
            candidates.add(candidate(
                    "虚拟网卡 · " + address.name(),
                    "http://" + address.address() + ":" + port,
                    "virtual",
                    false,
                    "手机连不上这类地址（VMware / WSL / VPN 等），忽略即可。"));
        }
        return candidates;
    }

    private Map<String, Object> candidate(String label, String url, String kind, boolean usable, String hint) {
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("label", label);
        item.put("url", url);
        item.put("kind", kind);
        item.put("usable", usable);
        item.put("hint", hint);
        return item;
    }

    public static String hotspotHint() {
        return "手机开热点 / USB 共享时，电脑这一侧的地址通常是 192.168.43.x、192.168.42.x、192.168.137.x";
    }
}
