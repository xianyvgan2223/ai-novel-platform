package com.deepseekapp.webserver.config;

import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.util.NetworkUtil;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.stereotype.Component;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** 启动横幅：告诉用户手机该填哪个地址、数据在哪、USB 隧道怎么开 */
@Component
public class StartupBanner implements ApplicationListener<ApplicationReadyEvent> {

    private final AppProperties props;
    private final ServerInfo serverInfo;
    private final SyncStore syncStore;
    private final DatabaseManager databaseManager;
    private final NetworkUtil networkUtil;

    public StartupBanner(AppProperties props, ServerInfo serverInfo, SyncStore syncStore,
                         DatabaseManager databaseManager, NetworkUtil networkUtil) {
        this.props = props;
        this.serverInfo = serverInfo;
        this.syncStore = syncStore;
        this.databaseManager = databaseManager;
        this.networkUtil = networkUtil;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        int port = serverInfo.port();
        List<NetworkUtil.LanAddress> usable = new ArrayList<>();
        for (NetworkUtil.LanAddress address : networkUtil.lanAddresses()) {
            if (!address.isVirtual()) {
                usable.add(address);
            }
        }

        List<String> lines = new ArrayList<>();
        lines.add("");
        lines.add("  deepseekapp web 同步服务已启动（Spring Boot）");
        lines.add("  ─────────────────────────────────────────────");
        lines.add("  本机访问:  http://localhost:" + port);
        if (!usable.isEmpty()) {
            lines.add("  手机请填:  http://" + usable.get(0).address() + ":" + port + "   ← 手机 App / 浏览器用这个");
            for (int i = 1; i < usable.size(); i++) {
                lines.add("             http://" + usable.get(i).address() + ":" + port +
                        "   （" + usable.get(i).name() + "）");
            }
        } else {
            lines.add("  手机请填:  未发现可用网卡地址，请检查网络连接");
        }

        lines.add("");
        lines.add("  ── 最稳的连接方式：USB 隧道（手机插着数据线即可，不看 Wi-Fi、不怕防火墙）──");
        lines.add("  另开一个窗口执行:  .\\mvnw.cmd spring-boot:run \"-Dspring-boot.run.arguments=--usb\"");
        lines.add("  或:                java -jar target/web-server-0.1.0.jar --usb");
        lines.add("  手机端服务地址填:  http://127.0.0.1:" + port);

        List<NetworkUtil.LanAddress> virtuals = new ArrayList<>();
        for (NetworkUtil.LanAddress address : networkUtil.lanAddresses()) {
            if (address.isVirtual()) {
                virtuals.add(address);
            }
        }
        if (!virtuals.isEmpty()) {
            lines.add("  以下为虚拟网卡，手机连不上，忽略即可:");
            for (NetworkUtil.LanAddress address : virtuals) {
                lines.add("             " + address.address() + "  (" + address.name() + ")");
            }
        }

        List<DatabaseManager.LegacyFile> legacy = databaseManager.legacyFiles();
        if (!legacy.isEmpty()) {
            List<String> names = legacy.stream().map(DatabaseManager.LegacyFile::file).toList();
            lines.add("");
            lines.add("  ⚠ 发现 v1 时期的共享库：" + String.join("、", names));
            lines.add("    升级后每台设备各用独立目录，这些文件不再被自动读取。");
            lines.add("    需要里面的数据：网页「同步与备份」→ 选中目标设备 → 上传该 .db 导入。");
        }

        List<Map<String, Object>> devices = syncStore.listDevices(false);
        List<String> deviceIds = devices.stream().map(d -> String.valueOf(d.get("deviceId"))).toList();
        Path webDist = props.webDistPath();
        lines.add("");
        lines.add("  数据目录:  " + props.dataDirPath());
        lines.add("  数据隔离:  每台设备一个独立槽位（" + databaseManager.devicesRootDir() + "\\<设备号>\\）");
        lines.add("  设备数量:  " + devices.size() + " 台" +
                (devices.isEmpty() ? " —— 手机同步一次后出现在这里" : "（" + String.join("、", deviceIds) + "）"));
        lines.add("  前端产物:  " + (Files.isDirectory(webDist) ? webDist : "未构建（开发模式用 npm run dev）"));
        lines.add("  App 更新:  " + props.appUpdateDirPath() + "（APK 放这里，或调用 /api/app/upload）");
        lines.add("  接口鉴权:  " + (props.getApiToken() == null || props.getApiToken().isEmpty()
                ? "未开启（仅建议在本机/可信局域网使用）"
                : "已开启（需 x-api-token 请求头）"));
        lines.add("");
        lines.add("  提示: 手机连不上时，多半是 Windows 防火墙拦了入站连接。");
        lines.add("        管理员 PowerShell 执行一次即可放行：");
        lines.add("        netsh advfirewall firewall add rule name=\"deepseekapp sync\" dir=in action=allow protocol=TCP localport=" + port);
        lines.add("");
        System.out.println(String.join("\n", lines));
    }
}
