<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import { CopyDocument, Download, Link, VideoPlay, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { BiliExtractDoneInfo, BiliSettingsInfo, BiliSubtitle, BiliVideoInfo } from '@/api';
import PageHeader from '@/components/PageHeader.vue';

/* ── 视频解析 ── */

const input = ref('');
const resolving = ref(false);
const video = ref<BiliVideoInfo | null>(null);
const pageIndex = ref(0);
const subtitles = ref<BiliSubtitle[]>([]);
const loadingSubtitles = ref(false);
const selectedLan = ref('');

const currentPage = computed(() => video.value?.pages[pageIndex.value] ?? null);
const multiPage = computed(() => (video.value?.pages.length ?? 0) > 1);

async function resolveVideo() {
  if (resolving.value) return;
  if (!input.value.trim()) {
    ElMessage.warning('先粘贴一个B站视频链接或 BV 号');
    return;
  }
  resolving.value = true;
  stopExtract();
  video.value = null;
  subtitles.value = [];
  selectedLan.value = '';
  result.value = '';
  doneInfo.value = null;
  try {
    const info = await api.bili.resolve(input.value.trim());
    video.value = info;
    pageIndex.value = 0;
    subtitles.value = info.subtitles;
    selectedLan.value = info.subtitles[0]?.lan ?? '';
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    resolving.value = false;
  }
}

/** 切换分P：重新查该P的字幕 */
async function selectPage(index: number) {
  if (loadingSubtitles.value || extracting.value) return;
  const info = video.value;
  const page = info?.pages[index];
  if (!info || !page) return;
  pageIndex.value = index;
  loadingSubtitles.value = true;
  subtitles.value = [];
  selectedLan.value = '';
  try {
    const res = await api.bili.subtitles(info.aid, page.cid);
    subtitles.value = res.subtitles;
    selectedLan.value = res.subtitles[0]?.lan ?? '';
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingSubtitles.value = false;
  }
}

/* ── 提取（SSE）── */

const extracting = ref(false);
const stageLabel = ref('');
const percent = ref<number | null>(null);
const progressText = ref('');
const result = ref('');
const doneInfo = ref<BiliExtractDoneInfo | null>(null);

let controller: AbortController | null = null;
const resultBox = ref<HTMLElement | null>(null);

const resultChars = computed(() => result.value.length);
const sourceLabel = computed(() => {
  if (doneInfo.value?.source === 'subtitle') return '官方字幕';
  if (doneInfo.value?.source === 'asr') return '本地转写';
  return '';
});
/** 没有字幕时给用户的提示：可能是 SESSDATA 未配置/过期 */
const noSubtitleHint = computed(() => {
  if (!video.value || loadingSubtitles.value || subtitles.value.length) return '';
  if (!video.value.sessdataConfigured) {
    return '未检测到字幕。B站字幕接口需要登录态（SESSDATA）：在下方「字幕登录配置」里粘贴一次即可获取 AI 字幕；也可以直接点「提取文字稿」用本地语音识别。';
  }
  return '未检测到字幕。可能是该视频确实没有字幕（直接用本地转写），或 SESSDATA 已过期（在下方重新粘贴一次）。';
});

watch(result, async () => {
  // 实时文本跟随滚动
  await nextTick();
  const box = resultBox.value;
  if (box) box.scrollTop = box.scrollHeight;
});

async function extract() {
  const info = video.value;
  const page = currentPage.value;
  if (extracting.value || !info || !page) return;

  result.value = '';
  doneInfo.value = null;
  stageLabel.value = '';
  percent.value = null;
  progressText.value = '';
  extracting.value = true;
  controller = new AbortController();

  const chosen = subtitles.value.find((item) => item.lan === selectedLan.value);
  const startedAt = Date.now();
  try {
    await api.bili.extract(
      {
        bvid: info.bvid,
        aid: info.aid,
        cid: page.cid,
        mode: 'auto',
        duration: page.duration || info.duration,
        subtitleUrl: chosen?.url,
      },
      {
        onStage: (stage) => {
          stageLabel.value = stage.label;
        },
        onProgress: (progress) => {
          if (progress.percent !== undefined) {
            percent.value = Math.max(0, Math.min(100, progress.percent));
          }
          if (progress.text) {
            progressText.value = progress.text;
          }
        },
        onDelta: (delta) => {
          result.value += delta;
        },
        onDone: (info2) => {
          doneInfo.value = {
            source: (info2.source as BiliExtractDoneInfo['source']) ?? undefined,
            chars: Number(info2.chars ?? 0),
            elapsedMs: Number(info2.elapsedMs ?? Date.now() - startedAt),
          };
        },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止，保留已提取的内容');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    extracting.value = false;
    controller = null;
  }
}

function stopExtract() {
  controller?.abort();
}

async function copyResult() {
  if (!result.value) return;
  try {
    await navigator.clipboard.writeText(result.value);
    ElMessage.success('已复制到剪贴板');
  } catch {
    ElMessage.warning('浏览器没有允许复制，请手动选中文本');
  }
}

function downloadTxt() {
  if (!result.value) return;
  const title = (video.value?.title || 'bilibili-转写').replace(/[\\/:*?"<>|]/g, '_');
  const blob = new Blob([result.value], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = title + '.txt';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

/* ── SESSDATA 设置 ── */

const settingsOpen = ref(false);
const settings = ref<BiliSettingsInfo | null>(null);
const sessdataInput = ref('');
const savingSettings = ref(false);

const settingsSummary = computed(() => {
  const info = settings.value;
  if (!info) return '加载中…';
  if (!info.configured) return '未配置';
  return info.source === 'env'
    ? '已配置（来自环境变量）'
    : '已配置 ' + (info.preview ?? '');
});

async function loadSettings() {
  try {
    settings.value = await api.bili.settings();
  } catch {
    settings.value = null;
  }
}

async function saveSessdata() {
  if (savingSettings.value) return;
  const value = sessdataInput.value.trim();
  savingSettings.value = true;
  try {
    const res = await api.bili.saveSettings(value);
    if (value && res.valid) {
      ElMessage.success('SESSDATA 已保存并校验通过' + (res.uname ? '：' + res.uname : ''));
      sessdataInput.value = '';
    } else if (!value) {
      ElMessage.success('已清除保存的 SESSDATA');
    }
    await loadSettings();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    savingSettings.value = false;
  }
}

/* ── 小工具 ── */

function formatDuration(seconds: number): string {
  if (!seconds) return '-';
  if (seconds < 3600) {
    return Math.floor(seconds / 60) + '分' + (seconds % 60) + '秒';
  }
  return Math.floor(seconds / 3600) + '时' + Math.floor((seconds % 3600) / 60) + '分';
}

onMounted(loadSettings);
</script>

<template>
  <div class="page">
    <PageHeader
      title="B站视频转文字"
      desc="粘贴B站视频链接，优先提取官方字幕（含 AI 字幕）；没有字幕时自动下载音频用本地语音识别转写。"
      back="/writing"
    />

    <div class="bili-grid">
      <!-- 左：链接 + 视频信息 + 字幕源 -->
      <section class="card card-flush">
        <div class="card-head">
          <h3>视频链接</h3>
        </div>
        <div class="card-body">
          <div class="input-row">
            <el-input
              v-model="input"
              size="large"
              placeholder="https://www.bilibili.com/video/BV… 或直接粘贴 BV 号"
              clearable
              @keyup.enter="resolveVideo"
            >
              <template #prefix><el-icon><Link /></el-icon></template>
            </el-input>
            <el-button
              type="primary"
              size="large"
              :loading="resolving"
              :disabled="extracting"
              @click="resolveVideo"
            >
              解析
            </el-button>
          </div>

          <template v-if="video">
            <div class="video-info">
              <div class="video-title" :title="video.title">{{ video.title }}</div>
              <div class="video-meta">
                <span>UP：{{ video.owner || '-' }}</span>
                <span>时长 {{ formatDuration(video.duration) }}</span>
                <span class="mono">{{ video.bvid }}</span>
              </div>
            </div>

            <!-- 分P -->
            <template v-if="multiPage">
              <div class="field-label">分P（{{ video.pages.length }} 个）</div>
              <div class="chips page-chips">
                <button
                  v-for="(page, index) in video.pages"
                  :key="page.cid"
                  type="button"
                  class="chip"
                  :class="{ on: index === pageIndex }"
                  :disabled="extracting"
                  :title="page.part"
                  @click="selectPage(index)"
                >
                  P{{ page.page }} {{ page.part || '未命名' }}
                </button>
              </div>
            </template>

            <!-- 字幕源 -->
            <div class="field-label">字幕源</div>
            <div v-if="loadingSubtitles" class="field-note">正在查询字幕…</div>
            <div v-else-if="subtitles.length" class="chips">
              <button
                v-for="item in subtitles"
                :key="item.lan"
                type="button"
                class="chip"
                :class="{ on: item.lan === selectedLan }"
                :disabled="extracting"
                @click="selectedLan = item.lan"
              >
                {{ item.lanDoc }}<span v-if="item.ai" class="ai-tag">AI</span>
              </button>
            </div>
            <el-alert v-else-if="noSubtitleHint" type="warning" :closable="false" show-icon>
              {{ noSubtitleHint }}
            </el-alert>

            <div class="run-row">
              <el-button
                v-if="!extracting"
                type="primary"
                size="large"
                :icon="VideoPlay"
                @click="extract"
              >
                提取文字稿
              </el-button>
              <el-button v-else type="danger" size="large" plain :icon="VideoPause" @click="stopExtract">
                停止
              </el-button>
              <span class="text-muted run-hint">
                {{ subtitles.length ? '秒出稿，直接读字幕' : '无字幕时本地转写，速度取决于视频时长' }}
              </span>
            </div>
          </template>
          <div v-else class="empty-hint">粘贴链接点「解析」，确认视频和字幕后开始提取。</div>
        </div>
      </section>

      <!-- 右：结果 -->
      <section class="card card-flush result-card">
        <div class="card-head">
          <h3>文字稿</h3>
          <span class="result-meta">
            <template v-if="extracting">{{ stageLabel || '准备中' }}…</template>
            <template v-else-if="doneInfo">
              {{ sourceLabel }}<template v-if="resultChars"> · {{ resultChars }} 字</template><template v-if="doneInfo.elapsedMs"> · {{ (doneInfo.elapsedMs / 1000).toFixed(1) }}s</template>
            </template>
            <template v-else>等待提取</template>
          </span>
        </div>

        <!-- 进度 -->
        <div v-if="extracting && (percent !== null || progressText)" class="progress-block">
          <el-progress
            v-if="percent !== null"
            :percentage="percent"
            :stroke-width="8"
            :show-text="false"
          />
          <div class="progress-text">{{ progressText || stageLabel }}</div>
        </div>

        <div ref="resultBox" class="result-body">
          <div v-if="!result && !extracting" class="empty-hint">
            提取结果会显示在这里，边生成边更新。
          </div>
          <div v-else class="result-text">{{ result }}<span v-if="extracting" class="caret" /></div>
        </div>

        <div v-if="result && !extracting" class="card-foot">
          <div class="row-gap">
            <el-button :icon="CopyDocument" @click="copyResult">复制全文</el-button>
            <el-button :icon="Download" @click="downloadTxt">下载 txt</el-button>
          </div>
        </div>
      </section>
    </div>

    <!-- 字幕登录配置（SESSDATA） -->
    <section class="card settings-card">
      <button type="button" class="settings-head" @click="settingsOpen = !settingsOpen">
        <span class="settings-title">字幕登录配置</span>
        <span class="settings-status" :class="{ ok: settings?.configured }">{{ settingsSummary }}</span>
        <span class="settings-arrow" :class="{ open: settingsOpen }">›</span>
      </button>

      <div v-if="settingsOpen" class="settings-body">
        <p class="field-note">
          B站的字幕（包括 AI 字幕）接口需要登录态。在电脑浏览器登录B站 → 按 F12 →
          「应用 / 存储」→ Cookie → 找到 <code>SESSDATA</code>，复制它的值粘贴到这里保存。
          服务端会先校验有效性再落盘；该值只存在你自己的服务端数据目录里。
        </p>
        <div class="input-row">
          <el-input
            v-model="sessdataInput"
            type="password"
            show-password
            placeholder="粘贴 SESSDATA 的值（留空提交 = 清除已保存的配置）"
            :disabled="savingSettings"
          />
          <el-button type="primary" :loading="savingSettings" @click="saveSessdata">
            保存并校验
          </el-button>
        </div>
        <div v-if="settings" class="env-status">
          <span :class="settings.pythonOk ? 'ok' : 'bad'">
            Python：{{ settings.pythonOk ? '正常' : '未找到' }}
          </span>
          <span :class="settings.whisperOk ? 'ok' : 'bad'">
            faster-whisper：{{ settings.whisperOk ? '已安装' : '未安装（无字幕视频将无法本地转写）' }}
          </span>
          <span class="mono text-muted">{{ settings.pythonPath }}</span>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.bili-grid {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
  gap: 18px;
  align-items: start;
  margin-bottom: 18px;
}

@media (max-width: 1100px) {
  .bili-grid { grid-template-columns: minmax(0, 1fr); }
}

.input-row {
  display: flex;
  gap: 10px;
}

.input-row .el-input { flex: 1; }

.video-info {
  margin-top: 18px;
  padding: 14px 16px;
  border-radius: 10px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
}

.video-title {
  font-size: 15px;
  font-weight: 600;
  color: var(--ink-1);
  line-height: 1.5;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.video-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 14px;
  margin-top: 8px;
  font-size: 12px;
  color: var(--ink-3);
}

.field-label {
  margin: 16px 0 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.3px;
  color: var(--ink-3);
}

.field-note {
  margin: 8px 0 0;
  font-size: 11.5px;
  color: var(--ink-4);
  line-height: 1.7;
}

.field-note code {
  padding: 1px 5px;
  border-radius: 4px;
  background: var(--bg-soft);
  font-family: var(--font-mono, monospace);
  font-size: 11px;
}

.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.chip {
  padding: 6px 13px;
  border-radius: 999px;
  border: 1px solid var(--line-strong);
  background: #fff;
  font-size: 12.5px;
  color: var(--ink-2);
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease, color 0.15s ease;
}

.chip:hover:not(:disabled) { border-color: #d4cec2; }

.chip.on {
  border-color: #d4cec2;
  background: var(--brand-soft);
  color: var(--brand);
  font-weight: 600;
}

.chip:disabled { opacity: 0.55; cursor: not-allowed; }

.page-chips .chip {
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.ai-tag {
  margin-left: 5px;
  padding: 0 5px;
  border-radius: 999px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 10px;
  font-weight: 700;
  vertical-align: 1px;
}

.run-row {
  display: flex;
  align-items: center;
  gap: 14px;
  margin-top: 22px;
  flex-wrap: wrap;
}

.run-hint { font-size: 12px; }

.empty-hint {
  padding: 26px 6px;
  font-size: 12.5px;
  color: var(--ink-4);
  text-align: center;
}

.result-card { display: flex; flex-direction: column; }

.result-meta {
  font-size: 12px;
  color: var(--ink-3);
  font-variant-numeric: tabular-nums;
}

.progress-block {
  padding: 14px 22px 0;
}

.progress-text {
  margin-top: 6px;
  font-size: 12px;
  color: var(--ink-3);
  font-variant-numeric: tabular-nums;
}

.result-body {
  padding: 20px 22px;
  flex: 1;
  min-height: 420px;
  max-height: 560px;
  overflow-y: auto;
}

.result-text {
  white-space: pre-wrap;
  word-break: break-word;
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 15px;
  line-height: 1.95;
  color: var(--ink-1);
}

.caret {
  display: inline-block;
  width: 7px;
  height: 16px;
  margin-left: 2px;
  vertical-align: -2px;
  border-radius: 1px;
  background: var(--brand);
  animation: blink 1s steps(2, start) infinite;
}

@keyframes blink { to { opacity: 0; } }

.row-gap { display: flex; gap: 10px; }

/* ── 设置卡片 ── */
.settings-card { margin-bottom: 18px; }

.settings-head {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  padding: 16px 20px;
  border: none;
  background: transparent;
  cursor: pointer;
  text-align: left;
}

.settings-title {
  font-size: 14.5px;
  font-weight: 600;
  color: var(--ink-1);
}

.settings-status {
  font-size: 12px;
  color: var(--ink-4);
}

.settings-status.ok { color: var(--brand); }

.settings-arrow {
  margin-left: auto;
  font-size: 18px;
  color: var(--ink-4);
  transform: rotate(90deg);
  transition: transform 0.15s ease;
}

.settings-arrow.open { transform: rotate(-90deg); }

.settings-body {
  padding: 0 20px 18px;
  border-top: 1px solid var(--line);
  padding-top: 14px;
}

.env-status {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  margin-top: 12px;
  font-size: 12px;
  color: var(--ink-3);
}

.env-status .ok { color: var(--brand); }

.env-status .bad { color: #e08b00; }
</style>
