<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { ElMessage } from 'element-plus';
import {
  Collection, CopyDocument, Document, MagicStick, Refresh, Search, UploadFilled,
} from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type {
  RagJob, RagJobSplitPayload, RagJobStatus, RagJobSummary, RagScene, RagSettings, RagSettingsPayload,
  RagStatus, RagWindowDetail, RagWindowStatus, RagWindowSummary,
} from '@/api';
import PageHeader from '@/components/PageHeader.vue';

const status = ref<RagStatus | null>(null);
const statusLoading = ref(false);

/* ── 导入与提炼任务 ── */
const JOB_STATUS_LABELS: Record<RagJobStatus, string> = {
  parsing: '解析中',
  waiting: '等待开始',
  extracting: '提炼中',
  merging: '合并去重',
  embedding: '向量化',
  indexing: '写入索引',
  done: '已完成',
  failed: '失败',
};
const WINDOW_STATUS_LABELS: Record<RagWindowStatus, string> = {
  pending: '等待',
  running: '提炼中',
  done: '完成',
  failed: '失败',
};
/** 还需要轮询的状态（waiting 也算：可能被别处手动开始） */
const ACTIVE_JOB_STATUSES: RagJobStatus[] = [
  'parsing', 'waiting', 'extracting', 'merging', 'embedding', 'indexing',
];
/** 真正在跑的阶段：解析/提炼期间禁用重复提交 */
const RUNNING_JOB_STATUSES: RagJobStatus[] = [
  'parsing', 'extracting', 'merging', 'embedding', 'indexing',
];

function isActiveStatus(value: RagJobStatus): boolean {
  return ACTIVE_JOB_STATUSES.includes(value);
}
function jobStatusLabel(value: RagJobStatus): string {
  return JOB_STATUS_LABELS[value] ?? value;
}
function windowStatusLabel(value: RagWindowStatus): string {
  return WINDOW_STATUS_LABELS[value] ?? value;
}

const fileInput = ref<HTMLInputElement | null>(null);
const selectedFile = ref<File | null>(null);
const bookTitle = ref('');
const analyzing = ref(false);
const jobBusy = ref(false);
const job = ref<RagJob | null>(null);
const recentJobs = ref<RagJobSummary[]>([]);
let pollTimer: number | undefined;
/** 组件已卸载：避免 await 返回后继续排定时器 */
let disposed = false;

const jobRunning = computed(() => {
  const value = job.value?.status;
  return value != null && RUNNING_JOB_STATUSES.includes(value);
});
/** waiting / failed 时都能调整分块并重新划分或开始提炼（与后端允许的状态一致） */
const jobAdjustable = computed(() => {
  const value = job.value?.status;
  return value === 'waiting' || value === 'failed';
});
const jobProgress = computed(() => {
  const raw = Number(job.value?.progress ?? 0);
  return Math.max(0, Math.min(100, Math.round(raw)));
});

/* ── 分块参数 / 提炼设置 ── */
interface RagSplitForm {
  windowChars: number;
  overlapChars: number;
  concurrency: number;
}

const DEFAULT_SPLIT: RagSplitForm = { windowChars: 12000, overlapChars: 1500, concurrency: 4 };
const DEFAULT_SETTINGS = { manualExtract: true, ...DEFAULT_SPLIT };

const settings = ref<RagSettings | null>(null);
const settingsVisible = ref(false);
const settingsSaving = ref(false);
const settingsForm = ref({ ...DEFAULT_SETTINGS });
const splitForm = ref<RagSplitForm>({ ...DEFAULT_SPLIT });

const settingsSummary = computed(() => {
  const source = settings.value;
  const manual = source ? source.manualExtract : settingsForm.value.manualExtract;
  const windowChars = source ? source.windowChars : settingsForm.value.windowChars;
  const overlapChars = source ? source.overlapChars : settingsForm.value.overlapChars;
  const concurrency = source ? source.concurrency : settingsForm.value.concurrency;
  return (manual ? '手动开始' : '自动开始')
    + ' · 窗口 ' + windowChars + ' 字 · 重叠 ' + overlapChars + ' 字 · 并行 ' + concurrency;
});

function clampNumber(value: number, fallback: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.round(value)));
}

function buildSplitPayload(): RagJobSplitPayload {
  return {
    windowChars: clampNumber(splitForm.value.windowChars, DEFAULT_SPLIT.windowChars, 4000, 30000),
    overlapChars: clampNumber(splitForm.value.overlapChars, DEFAULT_SPLIT.overlapChars, 0, 5000),
    concurrency: clampNumber(splitForm.value.concurrency, DEFAULT_SPLIT.concurrency, 1, 8),
  };
}

function syncSplitForm(source: RagSplitForm) {
  splitForm.value = {
    windowChars: source.windowChars > 0 ? source.windowChars : DEFAULT_SPLIT.windowChars,
    overlapChars: source.overlapChars >= 0 ? source.overlapChars : DEFAULT_SPLIT.overlapChars,
    concurrency: source.concurrency > 0 ? source.concurrency : DEFAULT_SPLIT.concurrency,
  };
}

function applySettingsToForm(source: RagSettings | null) {
  settingsForm.value = source
    ? {
        manualExtract: source.manualExtract,
        windowChars: source.windowChars,
        overlapChars: source.overlapChars,
        concurrency: source.concurrency,
      }
    : { ...DEFAULT_SETTINGS };
}

async function loadSettings() {
  try {
    const res = await api.rag.settings();
    settings.value = res;
    applySettingsToForm(res);
    if (!job.value) {
      syncSplitForm({ windowChars: res.windowChars, overlapChars: res.overlapChars, concurrency: res.concurrency });
    }
  } catch {
    // 设置接口未就绪时静默降级到默认值，不打扰用户
  }
}

function openSettings() {
  applySettingsToForm(settings.value);
  settingsVisible.value = true;
}

async function saveSettings() {
  if (settingsSaving.value) return;
  settingsSaving.value = true;
  try {
    const payload: RagSettingsPayload = {
      manualExtract: settingsForm.value.manualExtract,
      windowChars: settingsForm.value.windowChars,
      overlapChars: settingsForm.value.overlapChars,
      concurrency: settingsForm.value.concurrency,
    };
    const res = await api.rag.saveSettings(payload);
    settings.value = res;
    applySettingsToForm(res);
    settingsVisible.value = false;
    ElMessage.success('提炼设置已保存');
    if (!job.value || job.value.status === 'waiting') {
      syncSplitForm({ windowChars: res.windowChars, overlapChars: res.overlapChars, concurrency: res.concurrency });
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    settingsSaving.value = false;
  }
}

/* ── 窗口列表与窗口详情 ── */
const expandedWindows = ref<number[]>([]);
const windowDetails = ref<Record<number, RagWindowDetail | undefined>>({});
const windowLoading = ref<Record<number, boolean>>({});
const windowTextOpen = ref<Record<number, boolean>>({});
const windowStatusSnapshot = ref<Record<number, RagWindowStatus>>({});

const EMPTY_WINDOW_DETAIL: RagWindowDetail = {
  index: -1,
  title: '',
  chapterRange: '',
  chars: 0,
  status: 'pending',
  sceneCount: 0,
  error: '',
  elapsedMs: 0,
  textPreview: '',
  text: '',
  rawOutput: '',
  scenes: [],
};

function resetWindowState() {
  expandedWindows.value = [];
  windowDetails.value = {};
  windowLoading.value = {};
  windowTextOpen.value = {};
  windowStatusSnapshot.value = {};
}

function isWindowExpanded(index: number): boolean {
  return expandedWindows.value.includes(index);
}

function hasWindowDetail(index: number): boolean {
  return windowDetails.value[index] != null;
}

function windowDetailOf(index: number): RagWindowDetail {
  return windowDetails.value[index] ?? EMPTY_WINDOW_DETAIL;
}

function isWindowTextOpen(index: number): boolean {
  // 默认展开窗口原文，点「收起原文」后记住收起状态
  return windowTextOpen.value[index] !== false;
}

function toggleWindowText(index: number) {
  windowTextOpen.value = { ...windowTextOpen.value, [index]: !isWindowTextOpen(index) };
}

async function loadWindowDetail(index: number) {
  const current = job.value;
  if (!current) return;
  windowLoading.value = { ...windowLoading.value, [index]: true };
  try {
    const res = await api.rag.window(current.id, index);
    if (job.value?.id !== current.id) return;
    // 后端字段缺失时兜底，避免模板里 .length / .toLocaleString 崩掉
    const detail: RagWindowDetail = {
      ...res,
      text: res.text ?? '',
      rawOutput: res.rawOutput ?? '',
      scenes: Array.isArray(res.scenes) ? res.scenes : [],
    };
    windowDetails.value = { ...windowDetails.value, [index]: detail };
    windowStatusSnapshot.value = { ...windowStatusSnapshot.value, [index]: detail.status };
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    windowLoading.value = { ...windowLoading.value, [index]: false };
  }
}

async function toggleWindow(win: RagWindowSummary) {
  if (isWindowExpanded(win.index)) {
    expandedWindows.value = expandedWindows.value.filter((item) => item !== win.index);
    return;
  }
  expandedWindows.value = [...expandedWindows.value, win.index];
  windowStatusSnapshot.value = { ...windowStatusSnapshot.value, [win.index]: win.status };
  if (!hasWindowDetail(win.index)) await loadWindowDetail(win.index);
}

function applyJob(next: RagJob) {
  const previous = job.value;
  // analyze 的返回如果省略了窗口列表，兜底成空数组，避免轮询崩溃
  const windows = Array.isArray(next.windows) ? next.windows : [];
  job.value = windows === next.windows ? next : { ...next, windows };
  if (!previous || previous.id !== next.id || previous.chunksTotal !== next.chunksTotal) {
    resetWindowState();
  }
  const snapshot: Record<number, RagWindowStatus> = {};
  windows.forEach((win) => {
    snapshot[win.index] = win.status;
  });
  windowStatusSnapshot.value = snapshot;
}

const query = ref('');
const tagInput = ref('');
const style = ref('');
const extra = ref('');
const searching = ref(false);
const hits = ref<RagScene[]>([]);
const imitating = ref(false);
const draft = ref('');
const references = ref<RagScene[]>([]);

const scenes = ref<RagScene[]>([]);
const scenesLoading = ref(false);
const sceneQuery = ref('');
const page = ref(1);
const pageSize = ref(9);
const total = ref(0);
/** 当前正在查看的作品；为空时显示作品选择列表（两层：选书 → 看情节） */
const selectedBook = ref('');

const hasStatus = computed(() => status.value != null);
const ragReady = computed(() => status.value?.esOnline && status.value?.embeddingConfigured);
const tagOptions = computed(() => status.value?.tags ?? []);

function handleFile(event: Event) {
  const input = event.target as HTMLInputElement;
  selectedFile.value = input.files?.[0] ?? null;
  if (!selectedFile.value) return;
  const name = selectedFile.value.name.replace(/\.txt$/i, '');
  if (!bookTitle.value.trim()) bookTitle.value = name;
}

function pickFile() {
  fileInput.value?.click();
}

function clearFile() {
  selectedFile.value = null;
  if (fileInput.value) fileInput.value.value = '';
}

async function loadStatus() {
  statusLoading.value = true;
  try {
    status.value = await api.rag.status();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    statusLoading.value = false;
  }
}

async function loadScenes() {
  // 第一层是作品列表，没选作品时不请求情节
  if (!selectedBook.value) {
    scenes.value = [];
    total.value = 0;
    return;
  }
  scenesLoading.value = true;
  try {
    const res = await api.rag.scenes({
      page: page.value,
      pageSize: pageSize.value,
      q: sceneQuery.value.trim(),
      book: selectedBook.value,
    });
    scenes.value = res.data;
    total.value = Number(res.meta.total ?? 0);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    scenesLoading.value = false;
  }
}

/** 进入某一部作品 */
function openBook(book: string) {
  selectedBook.value = book;
  sceneQuery.value = '';
  page.value = 1;
  void loadScenes();
}

/** 回到作品列表 */
function backToBooks() {
  selectedBook.value = '';
  sceneQuery.value = '';
  page.value = 1;
  scenes.value = [];
  total.value = 0;
  void loadStatus();
}

/* ── 任务轮询 / 最近任务 ── */
function stopPolling() {
  if (pollTimer !== undefined) {
    window.clearTimeout(pollTimer);
    pollTimer = undefined;
  }
}

function schedulePoll(id: string, delay: number) {
  stopPolling();
  if (disposed) return;
  pollTimer = window.setTimeout(() => {
    void pollJob(id);
  }, delay);
}

async function refreshRecentJobs() {
  try {
    recentJobs.value = await api.rag.jobs();
  } catch {
    // 旧后端可能没有该接口，静默降级，不弹错误
  }
}

async function afterJobFinished() {
  page.value = 1;
  await Promise.all([loadStatus(), loadScenes(), refreshRecentJobs()]);
}

async function pollJob(id: string) {
  pollTimer = undefined;
  if (disposed || !job.value || job.value.id !== id) return;
  try {
    const next = await api.rag.job(id);
    // 展开中的窗口状态有变化 → 重新拉详情（running → done 后能看到 rawOutput）
    const changed = expandedWindows.value.filter((index) => {
      const win = next.windows.find((item) => item.index === index);
      return win != null && windowStatusSnapshot.value[index] !== win.status;
    });
    applyJob(next);
    if (changed.length) {
      await Promise.all(changed.map((index) => loadWindowDetail(index)));
    }
    if (next.status === 'done') {
      ElMessage.success(next.message || `提炼完成，已入库 ${next.sceneCount} 个情节`);
      await afterJobFinished();
      return;
    }
    if (next.status === 'failed') {
      ElMessage.error(next.error || '提炼失败');
      await afterJobFinished();
      return;
    }
    if (disposed) return;
    pollTimer = window.setTimeout(() => {
      void pollJob(id);
    }, 1500);
  } catch (err) {
    stopPolling();
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

/** 打开某个任务（最近任务 / 刷新当前任务）：进行中的继续轮询，已完成的只展示结果概览 */
async function openJob(id: string) {
  if (!id) return;
  stopPolling();
  try {
    const full = await api.rag.job(id);
    applyJob(full);
    syncSplitForm(full);
    if (disposed) return;
    if (isActiveStatus(full.status)) {
      pollTimer = window.setTimeout(() => {
        void pollJob(full.id);
      }, 1000);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function refreshCurrentJob() {
  const current = job.value;
  if (!current) return;
  await openJob(current.id);
}

/** 切页回来：恢复最近一个仍在进行的任务并继续轮询 */
async function resumeActiveJob() {
  const active = recentJobs.value
    .filter((item) => isActiveStatus(item.status))
    .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  const latest = active[0];
  if (!latest) return;
  await openJob(latest.id);
}

async function onRecentChange(value: string) {
  const id = String(value ?? '').trim();
  if (!id) return;
  await openJob(id);
}

function recentJobLabel(item: RagJobSummary): string {
  return '《' + (item.book || '未命名') + '》 · ' + jobStatusLabel(item.status) + ' · ' + formatTime(item.createdAt);
}

/* ── 解析 / 重新划分 / 开始提炼 ── */

/** 上传 txt：解析并预览分块（manualExtract=false 时会直接开始提炼） */
async function analyzeFile() {
  const file = selectedFile.value;
  if (!file) {
    ElMessage.warning('先选择一部小说 .txt 文件');
    return;
  }
  if (analyzing.value || jobBusy.value || jobRunning.value) return;
  analyzing.value = true;
  stopPolling();
  try {
    const res = await api.rag.analyze(file, bookTitle.value.trim());
    applyJob(res);
    syncSplitForm(res);
    await refreshRecentJobs();
    if (res.status === 'waiting') {
      ElMessage.success(`《${res.book}》已解析，共 ${res.chunksTotal} 个窗口，预览后开始提炼`);
      schedulePoll(res.id, 1500);
    } else if (res.status === 'done') {
      ElMessage.success(res.message || '提炼完成');
      await afterJobFinished();
    } else if (res.status === 'failed') {
      ElMessage.error(res.error || '解析失败');
      await afterJobFinished();
    } else {
      ElMessage.success(`《${res.book}》已开始提炼，共 ${res.chunksTotal} 个窗口`);
      schedulePoll(res.id, 1000);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    analyzing.value = false;
  }
}

/** 按输入框的窗口字数 / 重叠 / 并行数重新分块 */
async function resplitJob() {
  const current = job.value;
  if (!current || jobBusy.value) return;
  jobBusy.value = true;
  try {
    const next = await api.rag.resplit(current.id, buildSplitPayload());
    resetWindowState();
    applyJob(next);
    syncSplitForm(next);
    await refreshRecentJobs();
    ElMessage.success(`已重新划分为 ${next.chunksTotal} 个窗口`);
    if (isActiveStatus(next.status)) {
      schedulePoll(next.id, 1200);
    } else if (next.status === 'failed') {
      ElMessage.error(next.error || '重新划分失败');
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    jobBusy.value = false;
  }
}

/** 手动开始提炼（同样带上输入框的分块参数） */
async function startExtract() {
  const current = job.value;
  if (!current || jobBusy.value) return;
  jobBusy.value = true;
  try {
    const next = await api.rag.startJob(current.id, buildSplitPayload());
    applyJob(next);
    syncSplitForm(next);
    await refreshRecentJobs();
    if (next.status === 'done') {
      ElMessage.success(next.message || '提炼完成');
      await afterJobFinished();
    } else if (next.status === 'failed') {
      ElMessage.error(next.error || '提炼失败');
      await afterJobFinished();
    } else {
      ElMessage.success(`已开始提炼，共 ${next.chunksTotal} 个窗口`);
      schedulePoll(next.id, 800);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    jobBusy.value = false;
  }
}

function parseTags(raw: string): string[] {
  return raw
    .split(/[,，、\s]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

async function search() {
  if (!query.value.trim()) {
    ElMessage.warning('请输入想找的情节描述');
    return;
  }
  searching.value = true;
  try {
    const res = await api.rag.search({
      query: query.value.trim(),
      size: 8,
      tags: parseTags(tagInput.value),
    });
    hits.value = res.hits;
    if (!hits.value.length) ElMessage.warning('没有检索到匹配情节');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    searching.value = false;
  }
}

async function imitate() {
  if (!query.value.trim()) {
    ElMessage.warning('请先写一句想写的剧情方向');
    return;
  }
  imitating.value = true;
  draft.value = '';
  references.value = [];
  try {
    const res = await api.rag.imitate({
      query: query.value.trim(),
      size: 4,
      tags: parseTags(tagInput.value),
      style: style.value.trim(),
      extra: extra.value.trim(),
    });
    draft.value = res.draft;
    references.value = res.references;
    ElMessage.success('仿写完成');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    imitating.value = false;
  }
}

async function copyDraft() {
  if (!draft.value) return;
  try {
    await navigator.clipboard.writeText(draft.value);
    ElMessage.success('已复制');
  } catch {
    ElMessage.warning('复制失败，请手动选择文本');
  }
}

function useTag(tag: string) {
  tagInput.value = tag;
  void search();
}

function searchScenes() {
  page.value = 1;
  void loadScenes();
}

function resetDraft() {
  draft.value = '';
  references.value = [];
}

let searchTimer: number | undefined;
function onSceneSearchInput() {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    page.value = 1;
    void loadScenes();
  }, 350);
}

onMounted(async () => {
  // 并行加载状态 / 设置 / 最近任务，再恢复进行中的任务（切页回来进度不丢）
  // 情节列表按「先选作品、再看情节」两层展示，进入页面时只加载作品列表（来自 status）
  await Promise.all([loadStatus(), loadSettings(), refreshRecentJobs()]);
  await resumeActiveJob();
});
onUnmounted(() => {
  disposed = true;
  stopPolling();
  window.clearTimeout(searchTimer);
});
</script>

<template>
  <div class="page rag-page">
    <PageHeader title="情节素材库" desc="导入小说 txt，用 DeepSeek 拆出可复用情节，向量检索后仿写新桥段。">
      <template #actions>
        <el-button :icon="Refresh" :loading="statusLoading" @click="loadStatus">刷新状态</el-button>
      </template>
    </PageHeader>

    <div class="rag-stats">
      <div class="rag-stat">
        <span class="rag-stat-label">已入库情节</span>
        <strong>{{ status?.totalScenes ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">来源作品</span>
        <strong>{{ status?.totalBooks ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">情节标签</span>
        <strong>{{ status?.tags?.length ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">向量库</span>
        <span class="rag-conn" :class="status?.esOnline ? 'on' : 'off'">
          <i />{{ status?.esOnline ? 'Elasticsearch 在线' : 'Elasticsearch 未连接' }}
        </span>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">Embedding</span>
        <span class="rag-conn" :class="status?.embeddingConfigured ? 'on' : 'off'">
          <i />{{ status?.embeddingConfigured ? status?.embeddingModel : '未配置百炼 Key' }}
        </span>
      </div>
    </div>

    <el-alert
      v-if="hasStatus && !ragReady"
      type="warning"
      :closable="false"
      show-icon
      class="rag-alert"
      title="RAG 还没有完全就绪"
      :description="status?.error || '请检查 Elasticsearch 与 DASHSCOPE_API_KEY 配置。'"
    />

    <div class="rag-grid">
      <section class="card rag-panel">
        <div class="panel-head">
          <div>
            <h3>导入小说</h3>
            <p>格式检测 → 情节弧分窗 → 并行提炼 → 合并去重，再写入向量库。</p>
          </div>
          <div class="panel-head-actions">
            <el-button class="settings-btn" text @click="openSettings">设置</el-button>
            <el-icon class="panel-icon"><UploadFilled /></el-icon>
          </div>
        </div>

        <input ref="fileInput" type="file" accept=".txt,text/plain" hidden @change="handleFile" />
        <button class="drop-zone" type="button" :class="{ filled: selectedFile }" @click="pickFile">
          <el-icon><Document /></el-icon>
          <template v-if="selectedFile">
            <span class="drop-title">{{ selectedFile.name }}</span>
            <span class="drop-hint">{{ (selectedFile.size / 1024 / 1024).toFixed(2) }} MB · 点击更换</span>
          </template>
          <template v-else>
            <span class="drop-title">选择小说 txt</span>
            <span class="drop-hint">支持 UTF-8 / GB18030，单次最多 200 万字</span>
          </template>
        </button>

        <div class="import-row">
          <el-input v-model="bookTitle" placeholder="作品名（留空取文件名）" clearable />
          <el-button v-if="selectedFile" text @click="clearFile">清除</el-button>
        </div>

        <div class="settings-line">{{ settingsSummary }}</div>

        <div class="panel-actions">
          <el-button
            type="primary"
            :icon="MagicStick"
            :loading="analyzing"
            :disabled="!selectedFile || !ragReady || analyzing || jobBusy || jobRunning"
            @click="analyzeFile"
          >
            解析并预览分块
          </el-button>
          <span class="panel-hint">会覆盖同名作品的旧素材</span>
        </div>

        <div v-if="recentJobs.length" class="recent-row">
          <span class="recent-label">最近任务</span>
          <el-select
            class="recent-select"
            :model-value="job?.id ?? ''"
            size="small"
            placeholder="查看最近任务"
            @change="onRecentChange"
          >
            <el-option
              v-for="item in recentJobs.slice(0, 5)"
              :key="item.id"
              :label="recentJobLabel(item)"
              :value="item.id"
            />
          </el-select>
        </div>

        <div v-if="job" class="job-panel">
          <div class="job-head">
            <div class="job-title">
              <span class="job-book">《{{ job.book || '未命名作品' }}》</span>
              <span class="job-status" :class="job.status">{{ jobStatusLabel(job.status) }}</span>
            </div>
            <div class="job-head-actions">
              <span class="job-num">{{ jobProgress }}%</span>
              <el-button text size="small" @click="refreshCurrentJob">刷新</el-button>
            </div>
          </div>

          <el-progress :percentage="jobProgress" :show-text="false" :stroke-width="5" color="var(--ink-1)" />
          <div class="job-message">{{ job.message || job.phase || '等待服务端返回进度…' }}</div>

          <div v-if="job.warnings && job.warnings.length" class="job-warnings">
            <div v-for="(warning, index) in job.warnings" :key="index">· {{ warning }}</div>
          </div>

          <div class="job-meta">
            <span v-if="job.phase">阶段：{{ job.phase }}</span>
            <span>窗口 {{ job.chunksDone }}/{{ job.chunksTotal }}</span>
            <span>情节 {{ job.sceneCount }}</span>
            <span v-if="job.mergedCount">合并重复 {{ job.mergedCount }}</span>
          </div>

          <div v-if="job.status !== 'parsing'" class="job-structure">
            <div class="structure-item">
              <span>格式</span><strong>{{ job.format || '未识别' }}</strong>
            </div>
            <div class="structure-item">
              <span>章节数</span><strong>{{ job.chapters }}</strong>
            </div>
            <div class="structure-item">
              <span>段落数</span><strong>{{ job.paragraphs }}</strong>
            </div>
            <div class="structure-item">
              <span>窗口数</span><strong>{{ job.chunksTotal }}</strong>
            </div>
            <div class="structure-item">
              <span>总字数</span><strong>{{ (job.totalChars || 0).toLocaleString() }}</strong>
            </div>
          </div>

          <div v-if="jobAdjustable" class="split-box">
            <div class="split-title">分块参数 · 调整后可重新划分，或直接开始提炼</div>
            <div class="split-inputs">
              <label class="split-field">
                <span>单窗口字数</span>
                <el-input-number
                  v-model="splitForm.windowChars"
                  :min="4000"
                  :max="30000"
                  :step="500"
                  size="small"
                  controls-position="right"
                  class="split-number"
                />
              </label>
              <label class="split-field">
                <span>重叠字数</span>
                <el-input-number
                  v-model="splitForm.overlapChars"
                  :min="0"
                  :max="5000"
                  :step="100"
                  size="small"
                  controls-position="right"
                  class="split-number"
                />
              </label>
              <label class="split-field">
                <span>并行提炼数</span>
                <el-input-number
                  v-model="splitForm.concurrency"
                  :min="1"
                  :max="8"
                  :step="1"
                  size="small"
                  controls-position="right"
                  class="split-number"
                />
              </label>
            </div>
            <div class="split-actions">
              <el-button :loading="jobBusy" :disabled="jobBusy || analyzing" @click="resplitJob">重新划分</el-button>
              <el-button
                type="primary"
                :icon="MagicStick"
                :loading="jobBusy"
                :disabled="jobBusy || analyzing"
                @click="startExtract"
              >
                开始提炼
              </el-button>
              <span class="panel-hint">开始后按 {{ job.chunksTotal }} 个窗口并行提炼</span>
            </div>
          </div>

          <div v-if="job.status === 'done'" class="job-done">
            已入库 {{ job.sceneCount }} 个情节<span v-if="job.mergedCount">（合并重复 {{ job.mergedCount }} 条）</span>，页面下方可直接查看。
          </div>
          <div v-else-if="job.status === 'failed'" class="job-failed">
            {{ job.error || '提炼失败，可调整分块参数重新划分后重试。' }}
          </div>

          <div v-if="job.windows.length" class="window-list">
            <div class="window-list-head">
              <span>分块窗口</span>
              <span>{{ job.windows.length }} 个 · 点击展开查看原文 / DeepSeek 原始返回</span>
            </div>
            <div
              v-for="win in job.windows"
              :key="win.index"
              class="window-item"
              :class="[win.status, { open: isWindowExpanded(win.index) }]"
            >
              <button type="button" class="window-row" @click="toggleWindow(win)">
                <span class="window-index">{{ String(win.index + 1).padStart(2, '0') }}</span>
                <span class="window-main">
                  <span class="window-title">{{ win.title || '窗口 ' + (win.index + 1) }}</span>
                  <span class="window-sub">
                    <span v-if="win.chapterRange">{{ win.chapterRange }} · </span>
                    <span>{{ (win.chars || 0).toLocaleString() }} 字</span>
                    <span v-if="win.textPreview" class="window-preview"> · {{ win.textPreview }}</span>
                  </span>
                </span>
                <span class="window-side">
                  <span v-if="win.status === 'done'" class="window-scene-count">{{ win.sceneCount }} 个情节</span>
                  <span v-if="win.elapsedMs > 0" class="window-elapsed">{{ (win.elapsedMs / 1000).toFixed(1) }}s</span>
                  <span class="window-status" :class="win.status">{{ windowStatusLabel(win.status) }}</span>
                </span>
              </button>

              <div v-if="isWindowExpanded(win.index)" class="window-body">
                <div v-if="windowLoading[win.index]" class="window-loading">正在加载窗口详情…</div>
                <template v-else-if="hasWindowDetail(win.index)">
                  <div class="window-block">
                    <div class="window-block-head">
                      <span>窗口原文 · {{ windowDetailOf(win.index).text.length.toLocaleString() }} 字</span>
                      <el-button text size="small" @click="toggleWindowText(win.index)">
                        {{ isWindowTextOpen(win.index) ? '收起原文' : '展开原文' }}
                      </el-button>
                    </div>
                    <pre v-if="isWindowTextOpen(win.index)" class="window-text">{{ windowDetailOf(win.index).text }}</pre>
                  </div>

                  <div class="window-block">
                    <div class="window-block-head">
                      <span>DeepSeek 原始返回</span>
                      <span class="window-block-meta">
                        {{ windowDetailOf(win.index).rawOutput.length.toLocaleString() }} 字符
                      </span>
                    </div>
                    <pre v-if="windowDetailOf(win.index).rawOutput" class="window-raw">{{ windowDetailOf(win.index).rawOutput }}</pre>
                    <div v-else class="window-empty">该窗口还没有模型原始返回（等待提炼或解析结果为空）。</div>
                  </div>

                  <div class="window-block">
                    <div class="window-block-head">
                      <span>解析出的情节 · {{ windowDetailOf(win.index).scenes.length }} 个</span>
                    </div>
                    <div v-if="windowDetailOf(win.index).scenes.length" class="window-scenes">
                      <div
                        v-for="(scene, sceneIndex) in windowDetailOf(win.index).scenes"
                        :key="sceneIndex"
                        class="window-scene"
                      >
                        <span class="window-scene-index">{{ String(sceneIndex + 1).padStart(2, '0') }}</span>
                        <div class="window-scene-main">
                          <div class="window-scene-title">{{ scene.title || '未命名情节' }}</div>
                          <div class="window-scene-tags">
                            <span v-if="scene.sceneType" class="tag-chip mini">{{ scene.sceneType }}</span>
                            <span v-for="tag in (scene.tags ?? []).slice(0, 4)" :key="tag" class="tag-chip mini">
                              {{ tag }}
                            </span>
                          </div>
                        </div>
                      </div>
                    </div>
                    <div v-else class="window-empty">暂无解析结果。</div>
                  </div>
                </template>
                <div v-else class="window-empty">窗口详情暂不可用。</div>
              </div>
            </div>
          </div>
        </div>

        <div class="steps">
          <div><b>01</b><span>格式检测与章节 / 段落结构化</span></div>
          <div><b>02</b><span>按情节弧切窗口，DeepSeek 并行提炼</span></div>
          <div><b>03</b><span>合并去重 → embedding → 写入 Elasticsearch</span></div>
        </div>
      </section>

      <section class="card rag-panel">
        <div class="panel-head">
          <div>
            <h3>检索与仿写</h3>
            <p>从素材库找结构相近的情节，再生成一段全新的正文。</p>
          </div>
          <el-icon class="panel-icon"><Search /></el-icon>
        </div>

        <el-input
          v-model="query"
          type="textarea"
          :rows="4"
          resize="none"
          placeholder="例如：雨夜，主角独自在废弃小屋，一个陌生人敲门求助，但他怀疑对方另有所图"
        />
        <div class="search-options">
          <el-input v-model="tagInput" placeholder="标签过滤（可选），用逗号分隔" clearable />
          <el-input v-model="style" placeholder="仿写风格（可选）" clearable />
        </div>
        <el-input v-model="extra" placeholder="额外要求（可选），例如：第一人称、结尾留悬念" clearable />

        <div class="panel-actions">
          <el-button :icon="Search" :loading="searching" :disabled="!ragReady" @click="search">检索相关情节</el-button>
          <el-button
            type="primary"
            :icon="MagicStick"
            :loading="imitating"
            :disabled="!ragReady"
            @click="imitate"
          >
            检索并仿写
          </el-button>
        </div>

        <div v-if="tagOptions.length" class="tag-cloud">
          <button v-for="tag in tagOptions.slice(0, 10)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
            {{ tag }}
          </button>
        </div>
      </section>
    </div>

    <section v-if="draft" class="card draft-panel">
      <div class="panel-head">
        <div>
          <h3>仿写结果</h3>
          <p>参考了 {{ references.length }} 条已有情节的结构与情绪曲线。</p>
        </div>
        <div class="draft-actions">
          <el-button text :icon="CopyDocument" @click="copyDraft">复制</el-button>
          <el-button text @click="resetDraft">关闭</el-button>
        </div>
      </div>
      <div class="draft-text">{{ draft }}</div>
      <div class="ref-list">
        <div v-for="(ref, index) in references" :key="ref.id" class="ref-item">
          <span class="ref-index">{{ String(index + 1).padStart(2, '0') }}</span>
          <div class="ref-main">
            <div class="ref-title">{{ ref.title }}</div>
            <div class="ref-tags">
              <span class="tag-chip mini">{{ ref.sceneType || '情节' }}</span>
              <span v-for="tag in ref.tags.slice(0, 3)" :key="tag" class="tag-chip mini">{{ tag }}</span>
            </div>
          </div>
          <span class="ref-score" v-if="ref.score">相似度 {{ (ref.score * 100).toFixed(0) }}</span>
        </div>
      </div>
    </section>

    <section v-if="hits.length" class="card hits-panel">
      <div class="panel-head">
        <div>
          <h3>检索到的情节</h3>
          <p>按语义相似度排序，可作为仿写的结构参考。</p>
        </div>
      </div>
      <div class="scene-grid">
        <article v-for="scene in hits" :key="scene.id" class="scene-card">
          <div class="scene-top">
            <span class="scene-type">{{ scene.sceneType || '情节' }}</span>
            <span class="scene-score" v-if="scene.score">相似度 {{ (scene.score * 100).toFixed(0) }}</span>
          </div>
          <h4>{{ scene.title }}</h4>
          <div class="scene-book">{{ scene.book }}</div>
          <p>{{ scene.plot }}</p>
          <div class="scene-tags">
            <button v-for="tag in scene.tags.slice(0, 4)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
              {{ tag }}
            </button>
          </div>
        </article>
      </div>
    </section>

    <section class="card library-panel">
      <!-- 第一层：选作品 -->
      <template v-if="!selectedBook">
        <div class="panel-head">
          <div>
            <h3>素材库作品</h3>
            <p>先选一部作品，再查看 / 搜索这部作品里的情节。</p>
          </div>
          <el-button text :icon="Refresh" :loading="statusLoading" @click="loadStatus">刷新</el-button>
        </div>

        <div v-loading="statusLoading" class="book-grid">
          <button
            v-for="book in status?.books ?? []"
            :key="book.book"
            type="button"
            class="book-card"
            @click="openBook(book.book)"
          >
            <span class="book-mark">书</span>
            <span class="book-main">
              <span class="book-title">《{{ book.book }}》</span>
              <span class="book-meta">{{ book.count }} 条情节素材</span>
            </span>
            <span class="book-arrow">›</span>
          </button>
        </div>

        <div v-if="!statusLoading && !(status?.books?.length)" class="empty-hint">
          <el-icon class="empty-icon"><Collection /></el-icon>
          <div>还没有入库情节。先导入一部小说 txt 建立素材库。</div>
        </div>
      </template>

      <!-- 第二层：选中作品里的情节 -->
      <template v-else>
        <div class="panel-head">
          <div class="book-detail-head">
            <button type="button" class="back-link" @click="backToBooks">‹ 作品列表</button>
            <h3>《{{ selectedBook }}》</h3>
            <p>共 {{ total }} 条情节素材。</p>
          </div>
          <el-input
            v-model="sceneQuery"
            class="library-search"
            placeholder="搜索本作品的情节 / 标签"
            clearable
            :prefix-icon="Search"
            @input="onSceneSearchInput"
            @clear="searchScenes"
          />
        </div>

        <div v-loading="scenesLoading" class="scene-grid">
          <article v-for="scene in scenes" :key="scene.id" class="scene-card">
            <div class="scene-top">
              <span class="scene-type">{{ scene.sceneType || '情节' }}</span>
              <span class="scene-book inline">{{ scene.book }}</span>
            </div>
            <h4>{{ scene.title }}</h4>
            <p>{{ scene.plot }}</p>
            <div class="scene-tags">
              <button v-for="tag in scene.tags.slice(0, 4)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
                {{ tag }}
              </button>
            </div>
            <div class="scene-foot">
              <span>{{ formatTime(scene.createdAt) }}</span>
              <span>{{ scene.characters.join('、') || '—' }}</span>
            </div>
          </article>
        </div>

        <div v-if="!scenesLoading && !scenes.length" class="empty-hint">
          <el-icon class="empty-icon"><Collection /></el-icon>
          <div>这部作品还没有匹配的情节。</div>
        </div>

        <div v-if="total > pageSize" class="library-foot">
          <el-pagination
            v-model:current-page="page"
            v-model:page-size="pageSize"
            :total="total"
            :page-sizes="[9, 18, 36]"
            layout="sizes, prev, pager, next"
            @current-change="loadScenes"
            @size-change="searchScenes"
          />
        </div>
      </template>
    </section>

    <!-- 提炼设置 -->
    <el-dialog v-model="settingsVisible" title="提炼设置" width="520px" :close-on-click-modal="false">
      <el-form label-position="top" class="settings-form">
        <el-form-item label="分块完成后手动开始提炼">
          <el-switch v-model="settingsForm.manualExtract" />
          <div class="field-hint">
            开启：解析完先预览分块，确认后手动点「开始提炼」；关闭：解析完直接自动提炼。
          </div>
        </el-form-item>

        <el-form-item label="单窗口目标字数">
          <el-input-number
            v-model="settingsForm.windowChars"
            :min="4000"
            :max="30000"
            :step="500"
            class="full"
            controls-position="right"
          />
          <div class="field-hint">每个情节弧窗口的目标字数，越大窗口越少、单次上下文越长。</div>
        </el-form-item>

        <el-form-item label="重叠字数">
          <el-input-number
            v-model="settingsForm.overlapChars"
            :min="0"
            :max="5000"
            :step="100"
            class="full"
            controls-position="right"
          />
          <div class="field-hint">相邻窗口之间保留的重叠字数，避免情节被从中间切断。</div>
        </el-form-item>

        <el-form-item label="并行提炼数">
          <el-input-number
            v-model="settingsForm.concurrency"
            :min="1"
            :max="8"
            :step="1"
            class="full"
            controls-position="right"
          />
          <div class="field-hint">同时请求 DeepSeek 的窗口数量，越大越快，但更容易触发限流。</div>
        </el-form-item>
      </el-form>

      <template #footer>
        <el-button @click="settingsVisible = false">取消</el-button>
        <el-button type="primary" :loading="settingsSaving" @click="saveSettings">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.rag-page { max-width: 1480px; }

.rag-stats {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 1px;
  margin-bottom: 18px;
  border: 1px solid var(--line);
  border-radius: var(--r-lg);
  overflow: hidden;
  background: var(--line);
}

.rag-stat {
  min-height: 86px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 8px;
  padding: 16px 18px;
  background: var(--bg-card);
}

.rag-stat-label {
  font-size: 11.5px;
  color: var(--ink-3);
  letter-spacing: 0.2px;
}

.rag-stat strong {
  font-size: 25px;
  line-height: 1;
  font-weight: 560;
  letter-spacing: -0.8px;
  color: var(--ink-1);
}

.rag-conn {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  font-size: 12px;
  color: var(--ink-2);
  line-height: 1.4;
}
.rag-conn i { width: 6px; height: 6px; border-radius: 50%; background: var(--ink-4); }
.rag-conn.on i { background: var(--ok); }
.rag-conn.off i { background: var(--danger); }

.rag-alert { margin-bottom: 18px; }

.rag-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 18px;
  margin-bottom: 18px;
}

.rag-panel { margin-bottom: 0; }
.panel-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; margin-bottom: 16px; }
.panel-head h3 { margin: 0; font-size: 16px; font-weight: 600; letter-spacing: 0.1px; }
.panel-head p { margin: 6px 0 0; font-size: 12.5px; line-height: 1.6; color: var(--ink-3); }
.panel-icon { font-size: 20px; color: var(--ink-4); }
.panel-head-actions { display: flex; align-items: center; gap: 6px; }

.drop-zone {
  width: 100%;
  min-height: 118px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  border: 1px dashed var(--line-strong);
  border-radius: var(--r-md);
  background: var(--bg-soft);
  color: var(--ink-2);
  cursor: pointer;
  transition: border-color 0.16s ease, background 0.16s ease;
}
.drop-zone:hover, .drop-zone.filled { border-color: var(--ink-3); background: var(--bg-card); }
.drop-zone .el-icon { font-size: 24px; color: var(--ink-3); margin-bottom: 2px; }
.drop-title { font-size: 13px; font-weight: 550; color: var(--ink-1); }
.drop-hint { font-size: 11.5px; color: var(--ink-3); }

.import-row { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
.import-row .el-input { flex: 1; }
.panel-actions { display: flex; align-items: center; gap: 12px; margin-top: 14px; flex-wrap: wrap; }
.panel-hint { font-size: 11.5px; color: var(--ink-3); }

.settings-line { margin-top: 10px; font-size: 11.5px; color: var(--ink-3); line-height: 1.6; }

.recent-row { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
.recent-label { font-size: 11.5px; color: var(--ink-3); white-space: nowrap; }
.recent-select { flex: 1; max-width: 380px; }

.job-panel {
  margin-top: 16px;
  padding: 14px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-soft);
}
.job-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
.job-title { display: flex; align-items: center; gap: 8px; min-width: 0; }
.job-book {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13.5px;
  font-weight: 560;
  color: var(--ink-1);
}
.job-status {
  flex-shrink: 0;
  padding: 1px 7px;
  border: 1px solid var(--line-strong);
  border-radius: 10px;
  font-size: 10.5px;
  line-height: 1.6;
  color: var(--ink-3);
}
.job-status.parsing,
.job-status.extracting,
.job-status.merging,
.job-status.embedding,
.job-status.indexing { color: var(--ink-1); border-color: var(--ink-3); background: var(--bg-card); }
.job-status.waiting { color: var(--ink-2); }
.job-status.done { color: var(--ok); border-color: var(--ok); }
.job-status.failed { color: var(--danger); border-color: var(--danger); }
.job-head-actions { display: flex; align-items: center; gap: 4px; flex-shrink: 0; }
.job-num { font-size: 12px; color: var(--ink-3); font-variant-numeric: tabular-nums; }
.job-message { margin-top: 8px; font-size: 12px; color: var(--ink-3); line-height: 1.6; }
.job-warnings {
  margin-top: 6px;
  font-size: 12px;
  color: var(--warn);
  line-height: 1.6;
  word-break: break-word;
}
.job-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 14px;
  margin-top: 8px;
  font-size: 11.5px;
  color: var(--ink-3);
  font-variant-numeric: tabular-nums;
}
.job-done { margin-top: 10px; font-size: 12px; color: var(--ok); line-height: 1.6; }
.job-failed { margin-top: 10px; font-size: 12px; color: var(--danger); line-height: 1.6; }

.job-structure {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 1px;
  margin-top: 12px;
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
  overflow: hidden;
  background: var(--line);
}
.structure-item { display: flex; flex-direction: column; gap: 5px; padding: 9px 10px; background: var(--bg-card); }
.structure-item span { font-size: 10.5px; color: var(--ink-3); }
.structure-item strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
  font-weight: 560;
  color: var(--ink-1);
  font-variant-numeric: tabular-nums;
}

.split-box { margin-top: 12px; padding-top: 12px; border-top: 1px dashed var(--line-strong); }
.split-title { margin-bottom: 10px; font-size: 11.5px; color: var(--ink-3); }
.split-inputs { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
.split-field { display: flex; flex-direction: column; gap: 5px; min-width: 0; font-size: 11px; color: var(--ink-3); }
.split-number { width: 100%; }
.split-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 12px; }

.window-list { margin-top: 14px; display: flex; flex-direction: column; gap: 6px; }
.window-list-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 2px;
  font-size: 11.5px;
  color: var(--ink-3);
}
.window-item { border: 1px solid var(--line); border-radius: var(--r-md); background: var(--bg-card); overflow: hidden; }
.window-item.running { border-color: var(--ink-3); }
.window-item.failed { border-color: var(--danger); }
.window-row {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 12px;
  border: none;
  background: transparent;
  color: var(--ink-2);
  text-align: left;
  cursor: pointer;
}
.window-row:hover { background: var(--bg-soft); }
.window-item.open .window-row { background: var(--bg-soft); }
.window-index { flex-shrink: 0; font-family: var(--font-serif); font-size: 12px; color: var(--ink-4); }
.window-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.window-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12.5px;
  font-weight: 550;
  color: var(--ink-1);
}
.window-sub {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 11px;
  color: var(--ink-3);
}
.window-preview { color: var(--ink-4); }
.window-side { flex-shrink: 0; display: flex; align-items: center; gap: 8px; }
.window-status {
  padding: 1px 7px;
  border: 1px solid var(--line-strong);
  border-radius: 10px;
  font-size: 10.5px;
  line-height: 1.6;
  color: var(--ink-3);
}
.window-status.pending { color: var(--ink-4); }
.window-status.running { color: var(--ink-1); border-color: var(--ink-3); background: var(--bg-soft); }
.window-status.done { color: var(--ok); border-color: var(--ok); }
.window-status.failed { color: var(--danger); border-color: var(--danger); }
.window-scene-count,
.window-elapsed { font-size: 10.5px; color: var(--ink-3); font-variant-numeric: tabular-nums; }

.window-body { padding: 2px 12px 12px; border-top: 1px solid var(--line); background: var(--bg-soft); }
.window-loading,
.window-empty { padding: 10px 0; font-size: 11.5px; color: var(--ink-3); }
.window-block { margin-top: 10px; }
.window-block-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
  font-size: 11.5px;
  color: var(--ink-2);
}
.window-block-meta { font-size: 10.5px; color: var(--ink-4); }
.window-text {
  margin: 0;
  max-height: 220px;
  overflow: auto;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
  background: var(--bg-card);
  font-family: var(--font-serif);
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-word;
}
.window-raw {
  margin: 0;
  max-height: 360px;
  overflow: auto;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
  background: var(--bg-card);
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 11.5px;
  line-height: 1.65;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-word;
}
.window-scenes { display: flex; flex-direction: column; gap: 6px; }
.window-scene {
  display: flex;
  gap: 9px;
  padding: 7px 9px;
  border: 1px solid var(--line);
  border-radius: var(--r-sm);
  background: var(--bg-card);
}
.window-scene-index { flex-shrink: 0; padding-top: 1px; font-family: var(--font-serif); font-size: 11px; color: var(--ink-4); }
.window-scene-main { flex: 1; min-width: 0; }
.window-scene-title { font-size: 12px; font-weight: 550; color: var(--ink-1); }
.window-scene-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 4px; }

.settings-form :deep(.el-form-item) { margin-bottom: 16px; }
.settings-form :deep(.el-form-item__content) { display: block; }
.field-hint { margin-top: 4px; font-size: 11.5px; color: var(--ink-4); line-height: 1.6; }
.full { width: 100%; }

.steps { display: flex; flex-direction: column; gap: 9px; margin-top: 20px; padding-top: 15px; border-top: 1px solid var(--line); }
.steps div { display: flex; gap: 10px; align-items: baseline; font-size: 12px; color: var(--ink-3); }
.steps b { font-family: var(--font-serif); font-size: 13px; color: var(--ink-4); font-weight: 500; }

.search-options { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin: 10px 0; }
.tag-cloud { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 16px; }
.tag-chip {
  border: 1px solid var(--line-strong);
  border-radius: 5px;
  background: transparent;
  color: var(--ink-2);
  padding: 3px 8px;
  font-size: 11px;
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.tag-chip:hover { border-color: var(--ink-3); background: var(--bg-soft); }
.tag-chip.mini { padding: 2px 6px; font-size: 10.5px; }

.draft-panel, .hits-panel, .library-panel { margin-bottom: 18px; }
.draft-actions { display: flex; align-items: center; gap: 4px; }
.draft-text {
  padding: 20px 22px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-soft);
  font-family: var(--font-serif);
  font-size: 14.5px;
  line-height: 1.95;
  color: var(--ink-1);
  white-space: pre-wrap;
}
.ref-list { margin-top: 14px; display: flex; flex-direction: column; gap: 0; }
.ref-item { display: flex; align-items: flex-start; gap: 12px; padding: 11px 2px; border-bottom: 1px solid var(--line); }
.ref-item:last-child { border-bottom: none; }
.ref-index { font-family: var(--font-serif); font-size: 13px; color: var(--ink-4); padding-top: 1px; }
.ref-main { flex: 1; min-width: 0; }
.ref-title { font-size: 13px; font-weight: 550; color: var(--ink-1); }
.ref-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 5px; }
.ref-score { font-size: 11px; color: var(--ink-3); white-space: nowrap; }

.scene-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.scene-card {
  display: flex;
  flex-direction: column;
  min-height: 190px;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-card);
}
.scene-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.scene-type { font-size: 10.5px; letter-spacing: 0.4px; color: var(--ink-3); }
.scene-score { font-size: 10.5px; color: var(--ink-3); font-variant-numeric: tabular-nums; }
.scene-book { margin-top: 3px; font-size: 11px; color: var(--ink-3); }
.scene-book.inline { margin-top: 0; max-width: 60%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.scene-card h4 { margin: 7px 0 5px; font-size: 13.5px; font-weight: 600; line-height: 1.5; color: var(--ink-1); }
.scene-card p {
  flex: 1;
  margin: 0;
  display: -webkit-box;
  -webkit-line-clamp: 4;
  line-clamp: 4;
  -webkit-box-orient: vertical;
  overflow: hidden;
  font-size: 12px;
  line-height: 1.75;
  color: var(--ink-2);
}
.scene-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 12px; }
.scene-foot { display: flex; justify-content: space-between; gap: 8px; margin-top: 10px; padding-top: 9px; border-top: 1px solid var(--line); font-size: 10.5px; color: var(--ink-3); }

.library-search { width: 260px; }
.library-foot { display: flex; justify-content: flex-end; margin-top: 16px; }

/* ── 两层素材库：作品卡片 → 作品内情节 ── */
.book-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}

.book-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 15px 16px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-card);
  text-align: left;
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease, transform 0.15s ease;
}

.book-card:hover {
  border-color: var(--line-strong);
  background: var(--bg-soft);
  transform: translateY(-1px);
}

.book-mark {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  display: grid;
  place-items: center;
  border: 1px solid var(--line-strong);
  border-radius: 8px;
  background: var(--bg-soft);
  color: var(--ink-2);
  font-family: var(--font-serif);
  font-size: 14px;
}

.book-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }

.book-title {
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.book-meta { font-size: 11.5px; color: var(--ink-3); }
.book-arrow { flex: 0 0 auto; font-size: 18px; line-height: 1; color: var(--ink-4); }
.book-card:hover .book-arrow { color: var(--ink-1); }

.book-detail-head { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; }
.book-detail-head h3 { margin: 3px 0 0; }

.back-link {
  padding: 0;
  border: none;
  background: transparent;
  color: var(--ink-3);
  font-size: 11.5px;
  cursor: pointer;
}

.back-link:hover { color: var(--ink-1); }
.empty-hint { display: flex; flex-direction: column; align-items: center; gap: 10px; }
.empty-icon { font-size: 24px; color: var(--ink-4); }

@media (max-width: 1200px) {
  .rag-stats { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .scene-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .book-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .job-structure { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
@media (max-width: 900px) {
  .rag-grid { grid-template-columns: minmax(0, 1fr); }
  .rag-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .scene-grid { grid-template-columns: minmax(0, 1fr); }
  .book-grid { grid-template-columns: minmax(0, 1fr); }
  .library-search { width: 180px; }
  .search-options { grid-template-columns: minmax(0, 1fr); }
  .split-inputs { grid-template-columns: minmax(0, 1fr); }
  .job-structure { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .window-list-head { flex-wrap: wrap; }
}
</style>
