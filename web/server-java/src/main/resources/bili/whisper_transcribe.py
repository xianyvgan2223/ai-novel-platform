#!/usr/bin/env python3
"""faster-whisper 转写脚本（由 Java WhisperAsrService 调用）。

协议：stdout 每行一个 JSON 对象，UTF-8 编码：
  {"type": "info",    "duration": 612.4}                     # 音频总时长（秒）
  {"type": "segment", "start": 12.3, "end": 15.6, "text": "转写文本"}
  {"type": "done",    "segments": 87}                         # 正常结束
stderr 输出模型下载/加载日志（人类可读，Java 侧收集尾部作错误上下文）。
"""
import argparse
import json
import sys

# Windows 控制台默认 GBK，强制 UTF-8 防乱码
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, help="音频文件路径（m4s/m4a/mp3 等）")
    parser.add_argument("--model", default="small", help="faster-whisper 模型名")
    args = parser.parse_args()

    from faster_whisper import WhisperModel

    print("[whisper] loading model: %s" % args.model, file=sys.stderr)
    model = WhisperModel(args.model, device="cpu", compute_type="int8")

    print("[whisper] transcribing: %s" % args.audio, file=sys.stderr)
    # transcribe() 立即返回，segments 是生成器，实际转写发生在迭代期间
    segments, info = model.transcribe(
        args.audio,
        language="zh",
        vad_filter=True,
    )

    emit({"type": "info", "duration": round(info.duration, 3)})

    count = 0
    for segment in segments:
        text = segment.text.strip()
        if text:
            emit({
                "type": "segment",
                "start": round(segment.start, 3),
                "end": round(segment.end, 3),
                "text": text,
            })
            count += 1

    emit({"type": "done", "segments": count})


if __name__ == "__main__":
    main()
