<script setup lang="ts">
/**
 * 「查看已有正文」：按作品只读翻看已写好的小事件正文。
 * 左侧列出事件结构，右侧显示选中一篇的正文；不改动任何数据。
 */
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { ArrowLeft, ArrowRight, CopyDocument, Document, Refresh } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import {
  charsOf, eventNumbers, hasContent, isMajor, loadChapters, loadOutline, splitTruncatedText, statsOf, trueLengthOf,
} from './novelApi';

const props = defineProps<{ id: string }>();
const route = useRoute();
const router = useRouter();

const outline = ref<Row | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);
const selectedId = ref<number | null>(null);
/** 只列已写正文（默认开）：找“已有正文”时不用在几百个待写事件里翻 */
const onlyWritten = ref(true);

/**
 * 列表接口会把长正文截成 300 字左右的预览，正文必须按 id 再取一次完整记录。
 * loadedId 标记当前正文属于哪一篇，避免切换过快时把上一篇的内容显示到下一篇上。
 */
const fullContent = ref('');
const fullSummary = ref('');
const fullUpdatedAt = ref('');
const loadedId = ref<number | null>(null);
const contentLoading = ref(false);
let contentToken = 0;

const outlineId = computed(() => Number(props.id));
const minorRows = computed(() => chapters.value.filter((row) => !isMajor(row)));
const writtenIds = computed(
  () => new Set(minorRows.value.filter((row) => hasContent(row)).map((row) => Number(row.id))),
);
/** 列表要显示的行：只看已写时保留“有已写小事件的大事件”标题，不写的不出现 */
const listedRows = computed<Row[]>(() => {
  if (!onlyWritten.value) return chapters.value;
  const rows: Row[] = [];
  let currentMajor: Row | null = null;
  let majorPushed = false;
  for (const row of chapters.value) {
    if (isMajor(row)) {
      currentMajor = row;
      majorPushed = false;
      continue;
    }
    if (!writtenIds.value.has(Number(row.id))) continue;
    if (currentMajor && !majorPushed) {
      rows.push(currentMajor);
      majorPushed = true;
    }
    rows.push(row);
  }
  return rows;
});
const visibleMinorRows = computed(() => listedRows.value.filter((row) => !isMajor(row)));
const numbers = computed(() => eventNumbers(chapters.value));
const stats = computed(() => statsOf(chapters.value));
const current = computed(
  () => minorRows.value.find((row) => Number(row.id) === selectedId.value) ?? null,
);
const currentContent = computed(
  () => (loadedId.value !== null && loadedId.value === Number(current.value?.id) ? fullContent.value : ''),
);
const hasCurrentContent = computed(() => currentContent.value.trim().length > 0);
const currentSummary = computed(() => {
  const row = current.value;
  if (!row) return '';
  if (loadedId.value !== null && loadedId.value === Number(row.id)) return fullSummary.value.trim();
  const preview = splitTruncatedText(row.event_summary);
  return preview.truncated ? preview.text.trim() + '…' : preview.text.trim();
});
const currentChars = computed(
  () => (loadedId.value !== null && loadedId.value === Number(current.value?.id)
    ? charsOf(fullContent.value)
    : trueLengthOf(current.value?.content)),
);
const currentIndex = computed(
  () => visibleMinorRows.value.findIndex((row) => Number(row.id) === selectedId.value),
);
const prevChapter = computed(
  () => (currentIndex.value > 0 ? visibleMinorRows.value[currentIndex.value - 1] : null),
);
const nextChapter = computed(
  () => (currentIndex.value >= 0 && currentIndex.value < visibleMinorRows.value.length - 1
    ? visibleMinorRows.value[currentIndex.value + 1]
    : null),
);

const currentLabel = computed(() => {
  const row = current.value;
  if (!row) return '正文';
  const number = numbers.value.get(Number(row.id))?.number;
  const prefix = number ? `小事件${number}` : '小事件';
  return `${prefix}：${String(row.event_title || '未命名')}`;
});

const headerDesc = computed(
  () => `共 ${stats.value.minor} 个小事件，已写 ${stats.value.written} 篇。只读浏览，不会修改正文。`,
);

const updatedLabel = computed(() => {
  const text = String(
    loadedId.value !== null && loadedId.value === Number(current.value?.id)
      ? fullUpdatedAt.value
      : current.value?.updated_at ?? '',
  ).trim();
  if (!text) return '';
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString('zh-CN', { hour12: false });
});

async function load() {
  loading.value = true;
  try {
    const keepId = selectedId.value;
    outline.value = await loadOutline(outlineId.value);
    chapters.value = await loadChapters(outlineId.value);
    pickInitial();
    syncSelectionToFilter();
    // 刷新后选中项没变时 watch 不会触发，这里补一次完整正文（首次进入交给 watch）
    if (keepId !== null && selectedId.value === keepId) void loadFull(current.value);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

/** 列表行里的正文是截断过的预览，选中后按 id 取完整记录（含完整概要与更新时间） */
async function loadFull(row: Row | null) {
  const id = row ? Number(row.id) : NaN;
  const token = ++contentToken;
  loadedId.value = null;
  fullContent.value = '';
  fullSummary.value = '';
  fullUpdatedAt.value = '';
  if (!Number.isFinite(id)) {
    contentLoading.value = false;
    return;
  }
  contentLoading.value = true;
  try {
    const detail = await api.getRow('deepseek', 'outline_chapters', id);
    if (token !== contentToken) return;
    loadedId.value = id;
    fullContent.value = String(detail.content ?? '');
    fullSummary.value = String(detail.event_summary ?? '');
    fullUpdatedAt.value = String(detail.updated_at ?? '');
  } catch (err) {
    if (token === contentToken) ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    if (token === contentToken) contentLoading.value = false;
  }
}

/** 优先打开链接里指定的一篇；否则打开第一篇已写的；没有已写且只看已写时留空 */
function pickInitial() {
  if (selectedId.value !== null && minorRows.value.some((row) => Number(row.id) === selectedId.value)) {
    return;
  }
  const fromQuery = Number(route.query.chapter);
  if (Number.isFinite(fromQuery)) {
    const target = minorRows.value.find((row) => Number(row.id) === fromQuery);
    if (target) {
      selectedId.value = Number(target.id);
      return;
    }
  }
  const written = minorRows.value.find((row) => hasContent(row));
  const target = written ?? (onlyWritten.value ? null : minorRows.value[0]);
  selectedId.value = target ? Number(target.id) : null;
}

/** 切换「只看已写」后，保证当前选中项仍在列表里，否则落到第一篇已写 */
function syncSelectionToFilter() {
  if (!onlyWritten.value) return;
  if (selectedId.value !== null && visibleMinorRows.value.some((row) => Number(row.id) === selectedId.value)) {
    return;
  }
  const first = visibleMinorRows.value[0];
  selectedId.value = first ? Number(first.id) : null;
}

function select(row: Row) {
  selectedId.value = Number(row.id);
}

function step(direction: -1 | 1) {
  const target = direction < 0 ? prevChapter.value : nextChapter.value;
  if (target) select(target);
}

function goOutline() {
  router.push(`/writing/outline/${outlineId.value}/view`);
}

async function copyCurrent() {
  try {
    await navigator.clipboard.writeText(currentContent.value);
    ElMessage.success('正文已复制');
  } catch {
    ElMessage.error('复制失败，请手动选择文本复制');
  }
}

// 切换「只看已写」后，若当前选中的是待写篇，自动落到第一篇已写
watch(onlyWritten, () => syncSelectionToFilter());

// 选中的一篇变化时取完整正文（列表里的正文是截断的）
watch(
  () => selectedId.value,
  () => {
    void loadFull(current.value);
  },
);

// 同一页面内由「大纲」的「看正文」链接切换小事件时不重新挂载，跟着 query 换选中项
watch(
  () => route.query.chapter,
  (value) => {
    const id = Number(value);
    if (Number.isFinite(id) && minorRows.value.some((row) => Number(row.id) === id)) {
      selectedId.value = id;
    }
  },
);

onMounted(load);
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(outline?.title || '查看已有正文')"
      :desc="headerDesc"
      back="/writing/outlines?intent=read"
    >
      <template #actions>
        <el-button :icon="Document" @click="goOutline">查看大纲</el-button>
        <el-button :icon="CopyDocument" :disabled="!hasCurrentContent || contentLoading" @click="copyCurrent">复制正文</el-button>
        <el-button type="primary" :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div v-if="!minorRows.length && !loading" class="card empty-hint">
      这部作品还没有小事件，先去「小事件详写」拆出小事件结构。
    </div>

    <div v-else class="read-grid">
      <aside class="card card-flush read-list">
        <div class="card-head">
          <h3>小事件</h3>
          <div class="list-tools">
            <span class="mono text-muted">已写 {{ stats.written }}/{{ stats.minor }}</span>
            <el-checkbox v-model="onlyWritten" size="small">只看已写</el-checkbox>
          </div>
        </div>
        <div class="read-list-body">
          <div v-if="!listedRows.length && !loading" class="list-empty">
            还没有已写的正文，可以关掉「只看已写」查看全部小事件。
          </div>
          <template v-for="item in listedRows" :key="String(item.id)">
            <div v-if="isMajor(item)" class="list-major">
              <span class="list-major-title">
                大事件{{ numbers.get(Number(item.id))?.number ?? '' }} · {{ item.event_title || '未命名' }}
              </span>
            </div>
            <button
              v-else
              type="button"
              class="list-row"
              :class="{ on: selectedId === Number(item.id), pending: !hasContent(item) }"
              @click="select(item)"
            >
              <span class="lr-index">{{ numbers.get(Number(item.id))?.number ?? '·' }}</span>
              <span class="lr-main">
                <span class="lr-title">{{ item.event_title || '未命名小事件' }}</span>
                <span class="lr-meta">
                  {{ hasContent(item) ? `已写 · ${trueLengthOf(item.content)} 字` : '待写' }}
                </span>
              </span>
            </button>
          </template>
        </div>
      </aside>

      <section class="card card-flush read-main" v-loading="contentLoading">
        <div class="card-head">
          <div class="rm-head">
            <h3>{{ currentLabel }}</h3>
            <span v-if="current && !hasContent(current)" class="status-tag pending">待写</span>
            <span v-else-if="current" class="status-tag done">已写</span>
          </div>
          <div class="head-right">
            <span class="mono text-muted">{{ currentChars }} 字</span>
            <el-button size="small" :icon="ArrowLeft" :disabled="!prevChapter" @click="step(-1)">上一篇</el-button>
            <el-button size="small" :disabled="!nextChapter" @click="step(1)">
              下一篇
              <el-icon class="el-icon--right"><ArrowRight /></el-icon>
            </el-button>
          </div>
        </div>

        <div class="read-body">
          <template v-if="current">
            <div v-if="currentSummary" class="summary-box">
              <span class="summary-label">概要</span>
              <span class="summary-text">{{ currentSummary }}</span>
            </div>
            <article v-if="hasCurrentContent" class="prose">{{ currentContent }}</article>
            <div v-else-if="contentLoading" class="empty-hint">正在读取正文…</div>
            <div v-else class="empty-hint">这一篇还没有写正文。</div>
          </template>
          <div v-else class="empty-hint">
            {{ onlyWritten ? '这部作品还没有写好的正文，可在左侧关掉「只看已写」查看全部小事件。' : '从左侧选一篇小事件查看正文。' }}
          </div>
        </div>

        <div v-if="updatedLabel" class="card-foot">
          <span class="text-muted">最后更新：{{ updatedLabel }}</span>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.read-grid {
  display: grid;
  grid-template-columns: 300px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

.read-list {
  max-height: calc(100vh - 220px);
  display: flex;
  flex-direction: column;
}

.read-list-body { overflow: auto; padding: 6px 8px 10px; flex: 1; }

.list-tools { display: flex; align-items: center; gap: 10px; }
.list-tools :deep(.el-checkbox) { margin-right: 0; }

.list-empty {
  padding: 28px 10px;
  font-size: 12px;
  line-height: 1.7;
  color: var(--ink-4);
  text-align: center;
}

.list-major { padding: 14px 8px 6px; }

.list-major-title {
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.2px;
  color: var(--ink-3);
}

.list-row {
  display: flex;
  align-items: center;
  gap: 9px;
  width: 100%;
  padding: 9px 9px;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}

.list-row:hover { background: var(--bg-soft); }
.list-row.on { background: var(--brand-soft); border-color: var(--line-strong); }
.list-row.pending .lr-title { color: var(--ink-3); }

.lr-index {
  width: 22px;
  height: 22px;
  flex: 0 0 22px;
  display: grid;
  place-items: center;
  border-radius: 6px;
  background: var(--bg-card);
  border: 1px solid var(--line-strong);
  color: var(--ink-3);
  font-size: 10.5px;
}

.lr-main { display: flex; flex-direction: column; gap: 1px; min-width: 0; }

.lr-title {
  font-size: 12.5px;
  color: var(--ink-2);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.lr-meta { font-size: 10px; color: var(--ink-4); }

.read-main { min-height: 520px; display: flex; flex-direction: column; }

.rm-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
.rm-head h3 { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.head-right { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }

.status-tag {
  padding: 1px 6px;
  border-radius: 5px;
  border: 1px solid var(--line);
  background: var(--bg-soft);
  color: var(--ink-4);
  font-size: 10px;
  white-space: nowrap;
}

.status-tag.done { border-color: transparent; background: var(--ok-soft); color: var(--ok); }

.read-body { padding: 22px 26px 30px; flex: 1; }

.summary-box {
  max-width: 820px;
  margin-bottom: 20px;
  padding: 11px 14px;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--bg-soft);
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--ink-2);
}

.summary-label {
  display: inline-block;
  margin-right: 8px;
  font-size: 10.5px;
  font-weight: 600;
  color: var(--ink-3);
}

.summary-text { white-space: pre-wrap; word-break: break-word; }

.prose {
  max-width: 820px;
  font-family: var(--font-serif);
  font-size: 15px;
  line-height: 2;
  color: var(--ink-1);
  white-space: pre-wrap;
  word-break: break-word;
}

@media (max-width: 960px) {
  .read-grid { grid-template-columns: minmax(0, 1fr); }
  .read-list { max-height: 360px; }
  .read-body { padding: 18px 18px 24px; }
  .rm-head h3 { max-width: 46vw; }
}
</style>