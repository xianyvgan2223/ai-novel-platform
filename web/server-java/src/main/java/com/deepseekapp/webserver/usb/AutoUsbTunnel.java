package com.deepseekapp.webserver.usb;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.config.ServerInfo;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Web 服务启动完成后，自动在后台守护 USB 隧道。
 *
 * <p>以前必须另开窗口执行 {@code --usb}，否则手机即使插着线，
 * {@code http://127.0.0.1:3210} 也没有 adb reverse 映射，前端会显示
 * 「USB 通道还没通」。现在默认随服务自动启动，插线并授权即可。</p>
 */
@Component
public class AutoUsbTunnel {

    private static final Logger log = LoggerFactory.getLogger(AutoUsbTunnel.class);

    private final AppProperties props;
    private final ServerInfo serverInfo;
    private UsbTunnel tunnel;
    private Thread thread;

    public AutoUsbTunnel(AppProperties props, ServerInfo serverInfo) {
        this.props = props;
        this.serverInfo = serverInfo;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void start() {
        if (!props.isUsbAuto()) {
            log.info("USB 自动隧道已关闭（USB_AUTO=false），可用 --usb 模式单独启动");
            return;
        }
        int port = serverInfo.port();
        tunnel = new UsbTunnel(port, props.dataDirPath(), System.getenv("ADB"));
        thread = new Thread(tunnel::runDaemon, "usb-tunnel");
        thread.setDaemon(true);
        thread.start();
        log.info("USB 自动隧道已启动（端口 {}），手机插线并授权后即可访问 127.0.0.1", port);
    }

    @PreDestroy
    public void stop() {
        if (tunnel != null) {
            tunnel.stop();
        }
        if (thread != null) {
            thread.interrupt();
        }
    }
}
