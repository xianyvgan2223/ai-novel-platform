package com.deepseekapp.webserver.usb;

import com.deepseekapp.webserver.util.Json;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * USB 隧道守护：每 2 秒巡一遍已授权设备，确保
 * {@code adb reverse tcp:&lt;port&gt; tcp:&lt;port&gt;} 存在。
 */
public class UsbTunnel {

    private static final Pattern DEVICE_LINE = Pattern.compile("^(\\S+)\\s+device$");
    private static final long INTERVAL_MS = 2000;

    private final int port;
    private final Path dataDir;
    private final Path stateFile;
    private String adbPath;

    private volatile boolean running = true;
    private boolean staleChecked;
    private Set<String> known = new LinkedHashSet<>();

    private UsbTunnel(int port, Path dataDir, String adbPath) {
        this.port = port;
        this.dataDir = dataDir;
        this.stateFile = dataDir.resolve("usb-tunnel-state.json");
        this.adbPath = adbPath == null || adbPath.isBlank() ? "adb" : adbPath;
    }

    public static void runFromArgs(String[] args) {
        int port = parsePort(System.getenv("PORT"), 3210);
        String dataDirEnv = System.getenv("DATA_DIR");
        Path dataDir = resolve(dataDirEnv == null || dataDirEnv.isBlank() ? "../server/data" : dataDirEnv);
        String adb = System.getenv("ADB");

        for (String arg : args) {
            if (arg.startsWith("--port=")) {
                port = parsePort(arg.substring("--port=".length()), port);
            } else if (arg.startsWith("--data-dir=")) {
                dataDir = resolve(arg.substring("--data-dir=".length()));
            } else if (arg.startsWith("--adb=")) {
                adb = arg.substring("--adb=".length());
            }
        }

        new UsbTunnel(port, dataDir, adb).run();
    }

    private void run() {
        if (!locateAdb()) {
            System.err.println("""

                    [usb] 找不到 adb。
                          adb 来自 Android SDK 的 platform-tools（scrcpy 目录里也常带一个）。
                          装好后重试，或指定路径：
                            $env:ADB="D:\\Android\\platform-tools\\adb.exe"; java -jar ... --usb
                          不想用 USB 隧道也可以走局域网：手机端服务地址填启动横幅里的「手机请填」那一行。
                    """);
            System.exit(1);
        }

        System.out.println("""

                  USB 隧道守护已启动（端口 %d）
                  ─────────────────────────────────────────────
                  手机保持插着数据线、并且已授权本电脑的 USB 调试即可。
                  手机 App →「设置 → 数据同步 → 服务地址」填:  http://127.0.0.1:%d
                  然后点「测试连接」，看到「连接成功」就通了。
                  这个窗口可以最小化，按 Ctrl+C 退出。
                """.formatted(port, port));

        staleChecked = readState().isEmpty();
        if (staleChecked) {
            writeState(List.of());
        }

        Runtime.getRuntime().addShutdownHook(new Thread(this::shutdown));
        boolean firstRun = true;
        while (running) {
            firstRun = tick(firstRun);
            try {
                Thread.sleep(INTERVAL_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    private boolean tick(boolean firstRun) {
        List<String> devices = connectedDevices();
        if (devices.isEmpty()) {
            if (firstRun) {
                System.out.println("[usb] 还没有已授权的设备：请在手机上确认「允许 USB 调试」，然后重试。");
            } else if (!known.isEmpty()) {
                System.out.println("[usb] 没有可用设备了（手机拔了？），等它回来…");
            }
            if (!known.isEmpty()) {
                writeState(List.of());
            }
            known = new LinkedHashSet<>();
            return false;
        }

        if (!staleChecked) {
            cleanupStale();
            staleChecked = true;
        }

        for (String serial : devices) {
            boolean created = ensureTunnel(serial);
            if (!known.contains(serial)) {
                System.out.println("[usb] 设备 " + serial + "：隧道" + (created ? "已建立" : "已存在") +
                        " → 手机可访问 http://127.0.0.1:" + port);
            } else if (created) {
                System.out.println("[usb] 设备 " + serial + "：隧道掉了，已自动重建");
            }
        }

        for (String serial : known) {
            if (!devices.contains(serial)) {
                removeTunnel(serial);
            }
        }

        if (!String.join(",", devices).equals(String.join(",", known))) {
            writeState(devices);
        }
        known = new LinkedHashSet<>(devices);
        return false;
    }

    private void shutdown() {
        running = false;
        for (String serial : known) {
            removeTunnel(serial);
        }
        writeState(List.of());
        System.out.println("\n[usb] 已退出，隧道已清理。");
    }

    // ───────────────────────────── adb ─────────────────────────────

    private record Result(boolean ok, String stdout, String stderr) {
    }

    private Result adbRun(String... args) {
        List<String> command = new ArrayList<>();
        command.add(adbPath);
        command.addAll(Arrays.asList(args));
        try {
            Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
            String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            boolean finished = process.waitFor(15, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                return new Result(false, output, "adb 执行超时");
            }
            return new Result(process.exitValue() == 0, output, output);
        } catch (Exception e) {
            return new Result(false, "", e.getMessage() == null ? "执行 adb 失败" : e.getMessage());
        }
    }

    private boolean locateAdb() {
        if (adbRun("version").ok()) {
            return true;
        }
        for (String candidate : adbCandidates()) {
            if (candidate == null || !Files.exists(Path.of(candidate))) {
                continue;
            }
            adbPath = candidate;
            if (adbRun("version").ok()) {
                return true;
            }
        }
        return false;
    }

    private List<String> adbCandidates() {
        List<String> out = new ArrayList<>();
        String localAppData = System.getenv("LOCALAPPDATA");
        if (localAppData != null) {
            out.add(localAppData + "\\Android\\Sdk\\platform-tools\\adb.exe");
        }
        out.add("E:\\tools2\\scrcpy\\adb.exe");
        out.add("C:\\Android\\platform-tools\\adb.exe");
        out.add("D:\\Android\\platform-tools\\adb.exe");
        out.add("E:\\Android\\platform-tools\\adb.exe");
        return out;
    }

    private List<String> connectedDevices() {
        Result result = adbRun("devices");
        List<String> serials = new ArrayList<>();
        String[] lines = result.stdout().split("\\r?\\n");
        for (int i = 1; i < lines.length; i++) {
            Matcher matcher = DEVICE_LINE.matcher(lines[i].trim());
            if (matcher.matches()) {
                serials.add(matcher.group(1));
            }
        }
        return serials;
    }

    private List<String> reverseRules(String serial) {
        Result result = adbRun("-s", serial, "reverse", "--list");
        List<String> rules = new ArrayList<>();
        for (String line : result.stdout().split("\\r?\\n")) {
            String trimmed = line.trim();
            if (!trimmed.isEmpty()) {
                rules.add(trimmed);
            }
        }
        return rules;
    }

    private boolean ensureTunnel(String serial) {
        List<String> rules = reverseRules(serial);
        String wanted = "tcp:" + port + " tcp:" + port;
        if (rules.stream().anyMatch(rule -> rule.endsWith(wanted))) {
            return false;
        }
        if (rules.stream().anyMatch(rule -> rule.endsWith("tcp:" + port))) {
            adbRun("-s", serial, "reverse", "--remove", "tcp:" + port);
        }
        Result result = adbRun("-s", serial, "reverse", "tcp:" + port, "tcp:" + port);
        if (!result.ok()) {
            System.err.println("[usb] " + serial + " 建立隧道失败：" +
                    (result.stderr().isBlank() ? "未知错误" : result.stderr().trim()));
            return false;
        }
        return true;
    }

    private void removeTunnel(String serial) {
        adbRun("-s", serial, "reverse", "--remove", "tcp:" + port);
    }

    // ───────────────────────────── 状态文件 ─────────────────────────────

    private List<String> readState() {
        try {
            if (!Files.exists(stateFile)) {
                return List.of();
            }
            Object parsed = Json.parse(Files.readString(stateFile, StandardCharsets.UTF_8));
            Map<String, Object> map = Json.asMap(parsed);
            if (map == null || !(map.get("serials") instanceof List<?> list)) {
                return List.of();
            }
            List<String> serials = new ArrayList<>();
            for (Object item : list) {
                serials.add(String.valueOf(item));
            }
            return serials;
        } catch (Exception e) {
            return List.of();
        }
    }

    private void writeState(List<String> serials) {
        try {
            Files.createDirectories(dataDir);
            Map<String, Object> state = new java.util.LinkedHashMap<>();
            state.put("pid", ProcessHandle.current().pid());
            state.put("port", port);
            state.put("serials", serials);
            state.put("at", System.currentTimeMillis());
            Files.writeString(stateFile, Json.write(state), StandardCharsets.UTF_8);
        } catch (Exception ignore) {
            // 写不进去也不影响隧道本身
        }
    }

    private void cleanupStale() {
        List<String> previous = readState();
        if (previous.isEmpty()) {
            return;
        }
        Set<String> alive = new LinkedHashSet<>(connectedDevices());
        for (String serial : previous) {
            if (!alive.contains(serial)) {
                continue;
            }
            List<String> rules = reverseRules(serial);
            if (rules.stream().noneMatch(rule -> rule.endsWith("tcp:" + port))) {
                continue;
            }
            removeTunnel(serial);
            System.out.println("[usb] 已清理上次残留的隧道（" + serial + "），马上重建");
        }
        writeState(List.of());
    }

    // ───────────────────────────── 工具 ─────────────────────────────

    private static int parsePort(String value, int fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            int port = Integer.parseInt(value.trim());
            return port <= 0 ? fallback : port;
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static Path resolve(String value) {
        Path path = Path.of(value);
        if (path.isAbsolute()) {
            return path.normalize();
        }
        return Path.of(System.getProperty("user.dir")).resolve(path).normalize();
    }
}
