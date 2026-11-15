package com.deepseekapp.webserver.feature.bili.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Service;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayDeque;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 本地 faster-whisper 转写（Python 子进程）。
 *
 * <p>脚本随服务打包在 resources/bili/whisper_transcribe.py，
 * 运行前按 MD5 比对解压到数据目录（jar 内资源无法直接执行，数据目录也便于手工调试）。
 * stdout 按行输出 JSON（info/segment/done），逐段回调给上层推 SSE。
 * 本地转写是 CPU 密集任务，用 Semaphore(1) 串行化；
 * 取消（SSE 断开）时 destroyForcibly 收尸，另有 10 分钟无输出看门狗防进程挂死。</p>
 */
@Service
public class WhisperAsrService {

    /** stdout 无任何输出的看门狗阈值 */
    private static final long WATCHDOG_MS = 10 * 60 * 1000L;

    private final AppProperties props;
    private final Semaphore slots = new Semaphore(1);

    /** import faster_whisper 探测结果缓存（null = 未探测） */
    private volatile Boolean whisperReady;

    public WhisperAsrService(AppProperties props) {
        this.props = props;
    }

    public record Segment(double start, double end, String text) {
    }

    /** 转写回调：onInfo 拿音频总时长（进度分母），onSegment 逐段收文本 */
    public interface Listener {
        void onInfo(double durationSeconds) throws IOException;

        void onSegment(Segment segment) throws IOException;
    }

    /** Python 解释器存在性前置检查（SSE 开始前抛 JSON 错误） */
    public void requirePython() {
        String python = props.getBiliPython();
        if (python == null || python.isBlank() || !Files.isRegularFile(Path.of(python))) {
            throw new ApiException(503, "找不到 Python 解释器（" + python
                    + "）：请在 application.yml 的 app.bili-python 配置正确路径");
        }
    }

    public boolean whisperReady() {
        Boolean cached = whisperReady;
        if (cached != null) {
            return cached;
        }
        boolean ready = probe();
        whisperReady = ready;
        return ready;
    }

    /** 未安装时的提示（含可直接复制的修复命令） */
    public String whisperHint() {
        return "未安装 faster-whisper：请在终端执行  \""
                + props.getBiliPython() + "\" -m pip install faster-whisper  后重试";
    }

    /** 主入口：逐段回调 listener，正常结束返回段总数 */
    public int transcribe(Path audioFile, Listener listener) throws IOException {
        if (!slots.tryAcquire()) {
            throw new ApiException(429, "已有转写任务进行中，请等它完成后再试");
        }
        try {
            return run(audioFile, listener);
        } finally {
            slots.release();
        }
    }

    /* ── 内部 ── */

    private int run(Path audioFile, Listener listener) throws IOException {
        requirePython();
        if (!whisperReady()) {
            throw new ApiException(503, whisperHint());
        }
        ensureScript();
        Path script = props.dataDirPath().resolve("bili").resolve("whisper_transcribe.py");

        Process process;
        try {
            process = new ProcessBuilder(
                    props.getBiliPython(), script.toString(),
                    "--audio", audioFile.toString(),
                    "--model", props.getBiliWhisperModel())
                    .start();
        } catch (IOException e) {
            throw new ApiException(503, "无法启动 Python 转写进程：" + e.getMessage());
        }

        // stderr 只留尾部 30 行，供失败时拼错误上下文（模型下载进度也走这里）
        ArrayDeque<String> stderrTail = new ArrayDeque<>();
        Thread stderrThread = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(process.getErrorStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    synchronized (stderrTail) {
                        stderrTail.addLast(line);
                        while (stderrTail.size() > 30) {
                            stderrTail.pollFirst();
                        }
                    }
                }
            } catch (IOException ignored) {
                // 进程被杀时流会断，忽略
            }
        });
        stderrThread.setDaemon(true);

        // 看门狗：长时间没有任何 stdout 输出则强杀（模型下载中断/进程挂死）
        AtomicLong lastOutput = new AtomicLong(System.currentTimeMillis());
        Thread watchdog = new Thread(() -> {
            while (process.isAlive()) {
                try {
                    Thread.sleep(30_000);
                } catch (InterruptedException e) {
                    return;
                }
                if (System.currentTimeMillis() - lastOutput.get() > WATCHDOG_MS) {
                    process.destroyForcibly();
                    return;
                }
            }
        });
        watchdog.setDaemon(true);

        stderrThread.start();
        watchdog.start();

        int segments = 0;
        IOException listenerError = null;
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                lastOutput.set(System.currentTimeMillis());
                line = line.trim();
                if (line.isEmpty()) {
                    continue;
                }
                JsonNode event;
                try {
                    event = Json.MAPPER.readTree(line);
                } catch (Exception ignored) {
                    continue;
                }
                String type = event.path("type").asText("");
                try {
                    if ("info".equals(type)) {
                        listener.onInfo(event.path("duration").asDouble(0));
                    } else if ("segment".equals(type)) {
                        listener.onSegment(new Segment(
                                event.path("start").asDouble(0),
                                event.path("end").asDouble(0),
                                event.path("text").asText("")));
                        segments++;
                    }
                } catch (IOException e) {
                    // SSE 断开等写流失败：停止读取并中止子进程
                    listenerError = e;
                    break;
                } catch (UncheckedIOException e) {
                    // 上层把写流失败包装成 RuntimeException 抛出，解包统一处理
                    listenerError = e.getCause();
                    break;
                }
            }
        } finally {
            if (listenerError != null) {
                // SSE 断开：立即终止子进程，不再浪费 CPU
                process.destroyForcibly();
            }
            try {
                if (!process.waitFor(10, TimeUnit.SECONDS)) {
                    process.destroyForcibly();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                process.destroyForcibly();
            }
        }

        if (listenerError != null) {
            throw listenerError;
        }
        int exit = process.exitValue();
        if (exit != 0) {
            throw new ApiException(503, "转写失败：" + firstErrorLine(stderrTail, exit));
        }
        return segments;
    }

    private static String firstErrorLine(ArrayDeque<String> stderrTail, int exit) {
        synchronized (stderrTail) {
            for (String line : stderrTail) {
                if (line.contains("Error") || line.contains("Traceback")
                        || line.contains("Exception") || line.contains("error")) {
                    return line.trim();
                }
            }
            if (stderrTail.isEmpty()) {
                return "子进程异常退出（code " + exit + "）";
            }
            return String.join(" / ", stderrTail).trim();
        }
    }

    /** python -c "import faster_whisper" 探测（结果缓存） */
    private boolean probe() {
        try {
            String python = props.getBiliPython();
            if (python == null || python.isBlank() || !Files.isRegularFile(Path.of(python))) {
                return false;
            }
            Process process = new ProcessBuilder(python, "-c", "import faster_whisper").start();
            process.getInputStream().readAllBytes();
            process.getErrorStream().readAllBytes();
            return process.waitFor(30, TimeUnit.SECONDS) && process.exitValue() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    /** classpath 脚本 → 数据目录（MD5 一致则跳过） */
    private void ensureScript() throws IOException {
        byte[] bytes;
        try (var in = new ClassPathResource("bili/whisper_transcribe.py").getInputStream()) {
            bytes = in.readAllBytes();
        } catch (IOException e) {
            throw new ApiException(500, "转写脚本缺失（打包异常）");
        }
        Path target = props.dataDirPath().resolve("bili").resolve("whisper_transcribe.py");
        Files.createDirectories(target.getParent());
        if (Files.isRegularFile(target)) {
            try {
                if (MessageDigest.isEqual(md5(bytes), md5(Files.readAllBytes(target)))) {
                    return;
                }
            } catch (IOException ignored) {
                // 读旧文件失败就覆盖重写
            }
        }
        Files.write(target, bytes);
    }

    private static byte[] md5(byte[] input) {
        try {
            return MessageDigest.getInstance("MD5").digest(input);
        } catch (Exception e) {
            throw new IllegalStateException("MD5 不可用", e);
        }
    }
}
