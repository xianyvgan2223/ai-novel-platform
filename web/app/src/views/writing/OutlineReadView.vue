<script setup lang="ts">
/**
 * 「查看已有大纲」：只读浏览一部作品的大纲正文与事件结构。
 * 页面不提供任何写入入口，编辑请回「大纲编辑」。
 */
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { CopyDocument, Reading, Refresh } from '@element-plus/icons-vue';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import { charsOf, eventNumbers, hasContent, isMajor, loadChapters, loadOutline, splitTruncatedText, statsOf } from './novelApi';

const props = defineProps<{ id: string }>();
const router = useRouter();

const outline = ref<Row | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);
const tab = ref<'text' | 'structure' | 'major'>('text');
/** 「按大事件显示」里勾选的大事件 id；默认全选，之后保留用户的选择 */
const selectedMajorIds = ref<number[]>([]);
let majorSelectionInitialized = false;

const outlineId = computed(() => Number(props.id));
const stats = computed(() => statsOf(chapters.value));
const numbers = computed(() => eventNumbers(chapters.value));
/** 列表接口会截断长概要：这里按 id 预拆好预览正文与真实字数，模板里直接用 */
const summaries = computed(() => {
  const map = new Map<number, { text: string; length: number; truncated: boolean }>();
  for (const row of chapters.value) {
    map.set(Number(row.id), splitTruncatedText(row.event_summary));
  }
  return map;
});
const content = computed(() => String(outline.value?.content ?? ''));
const contentChars = computed(() => charsOf(content.value));
const createdDate = computed(() => String(outline.value?.created_at ?? '').trim().slice(0, 10));

const majorRows = computed(() => chapters.value.filter((row) => isMajor(row)));

interface MajorGroup {
  major: Row | null;
  minors: Row[];
}

/** 按事件顺序把每个大事件后面、下个大事件之前的小事件归到它名下 */
const majorGroups = computed<MajorGroup[]>(() => {
  const groups: MajorGroup[] = [];
  let current: MajorGroup | null = null;
  for (const row of chapters.value) {
    if (isMajor(row)) {
      current = { major: row, minors: [] };
      groups.push(current);
    } else if (current) {
      current.minors.push(row);
    }
  }
  return groups;
});

const visibleMajorGroups = computed(() =>
  majorGroups.value.filter(
    (group) => group.major && selectedMajorIds.value.includes(Number(group.major.id)),
  ),
);

const selectedMajorCount = computed(() => selectedMajorIds.value.length);
const selectedMinorCount = computed(() =>
  visibleMajorGroups.value.reduce((sum, group) => sum + group.minors.length, 0),
);

function isMajorSelected(id: number): boolean {
  return selectedMajorIds.value.includes(id);
}

function toggleMajor(id: number, checked: boolean): void {
  const next = new Set(selectedMajorIds.value);
  if (checked) next.add(id);
  else next.delete(id);
  selectedMajorIds.value = [...next];
}

function selectAllMajors(): void {
  selectedMajorIds.value = majorRows.value.map((row) => Number(row.id));
}

function clearMajors(): void {
  selectedMajorIds.value = [];
}

/** 数据刷新后：首次默认全选；之后只保留仍然存在的大事件，不覆盖用户主动清空的选择 */
function syncMajorSelection(): void {
  const available = majorRows.value.map((row) => Number(row.id));
  if (!majorSelectionInitialized) {
    selectedMajorIds.value = available;
    majorSelectionInitialized = true;
    return;
  }
  selectedMajorIds.value = selectedMajorIds.value.filter((id) => available.includes(id));
}

const headerDesc = computed(
  () => `共 ${chapters.value.length} 个事件 · ${stats.value.minor} 个小事件 · 已写 ${stats.value.written} 篇。只读查看，不会修改任何数据。`,
);

async function load() {
  loading.value = true;
  try {
    outline.value = await loadOutline(outlineId.value);
    chapters.value = await loadChapters(outlineId.value);
    syncMajorSelection();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

async function copyOutline() {
  try {
    await navigator.clipboard.writeText(content.value);
    ElMessage.success('大纲正文已复制');
  } catch {
    ElMessage.error('复制失败，请手动选择文本复制');
  }
}

function openReader() {
  router.push(`/writing/outline/${outlineId.value}/read`);
}

function openChapter(row: Row) {
  router.push(`/writing/outline/${outlineId.value}/read?chapter=${String(row.id)}`);
}

onMounted(load);
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(outline?.title || '查看已有大纲')"
      :desc="headerDesc"
      back="/writing/outlines?intent=view"
    >
      <template #actions>
        <el-button :icon="Reading" @click="openReader">查看正文</el-button>
        <el-button :icon="CopyDocument" :disabled="!content.trim()" @click="copyOutline">复制大纲</el-button>
        <el-button type="primary" :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div class="meta-row">
      <span class="meta-chip">类型：{{ outline?.genre || '未设置' }}</span>
      <span v-if="outline?.theme" class="meta-chip">主题：{{ outline.theme }}</span>
      <span v-if="createdDate" class="meta-chip">创建：{{ createdDate }}</span>
      <span class="meta-chip">大纲 {{ contentChars }} 字</span>
    </div>

    <div class="view-tabs">
      <button type="button" :class="{ on: tab === 'text' }" @click="tab = 'text'">大纲正文</button>
      <button type="button" :class="{ on: tab === 'structure' }" @click="tab = 'structure'">事件结构</button>
      <button type="button" :class="{ on: tab === 'major' }" @click="tab = 'major'">按大事件显示</button>
    </div>

    <section v-if="tab === 'text'" class="card card-flush">
      <div class="card-head">
        <h3>大纲正文</h3>
        <span class="mono text-muted">{{ contentChars }} 字</span>
      </div>
      <div class="outline-body">
        <pre v-if="content.trim()" class="outline-text">{{ content }}</pre>
        <div v-else class="empty-hint">这部作品还没有大纲正文。</div>
      </div>
    </section>

    <section v-else-if="tab === 'structure'" class="card card-flush">
      <div class="card-head">
        <h3>事件结构</h3>
        <span class="mono text-muted">{{ chapters.length }} 项</span>
      </div>
      <div class="event-body">
        <div v-if="!chapters.length" class="empty-hint">这部作品还没有事件结构。</div>
        <template v-for="item in chapters" :key="String(item.id)">
          <div v-if="isMajor(item)" class="event-major">
            <span class="event-kind major">
              大事件{{ numbers.get(Number(item.id))?.number ?? '' }}
            </span>
            <span class="event-title">{{ item.event_title || '未命名大事件' }}</span>
            <span class="event-meta">{{ summaries.get(Number(item.id))?.length ?? 0 }} 字概要</span>
          </div>
          <div v-else class="event-minor">
            <div class="event-minor-head">
              <span class="event-kind">小事件{{ numbers.get(Number(item.id))?.number ?? '' }}</span>
              <span class="event-title">{{ item.event_title || '未命名小事件' }}</span>
              <span class="event-status" :class="{ done: hasContent(item) }">
                {{ hasContent(item) ? '已写' : '待写' }}
              </span>
              <button v-if="hasContent(item)" type="button" class="link-btn" @click="openChapter(item)">
                看正文
              </button>
            </div>
            <p v-if="summaries.get(Number(item.id))?.text.trim()" class="event-summary">
              {{ summaries.get(Number(item.id))?.text }}<span
                v-if="summaries.get(Number(item.id))?.truncated"
                class="summary-more"
              >……（共 {{ summaries.get(Number(item.id))?.length }} 字，完整内容见「大纲正文」）</span>
            </p>
            <p v-else class="event-summary muted">还没有概要</p>
          </div>
        </template>
      </div>
    </section>

    <!-- 按大事件显示：勾选大事件后只列出它们及其所属小事件 -->
    <section v-else class="card card-flush">
      <div class="card-head">
        <h3>按大事件查看</h3>
        <span class="mono text-muted">
          已选 {{ selectedMajorCount }}/{{ majorRows.length }} 个大事件 · {{ selectedMinorCount }} 个小事件
        </span>
      </div>

      <div v-if="majorRows.length" class="major-toolbar">
        <div class="major-select-list">
          <el-checkbox
            v-for="major in majorRows"
            :key="String(major.id)"
            :model-value="isMajorSelected(Number(major.id))"
            @change="(value) => toggleMajor(Number(major.id), Boolean(value))"
          >
            大事件{{ numbers.get(Number(major.id))?.number ?? '' }} · {{ major.event_title || '未命名大事件' }}
          </el-checkbox>
        </div>
        <div class="major-toolbar-actions">
          <el-button text size="small" @click="selectAllMajors">全选</el-button>
          <el-button text size="small" :disabled="!selectedMajorCount" @click="clearMajors">清空</el-button>
        </div>
      </div>

      <div class="major-body">
        <div v-if="!majorRows.length" class="empty-hint">这部作品还没有大事件。</div>
        <div v-else-if="!selectedMajorCount" class="empty-hint">在上面勾选大事件，这里只显示所选大事件及其小事件。</div>
        <template v-else>
          <article
            v-for="group in visibleMajorGroups"
            :key="String(group.major?.id)"
            class="major-group"
          >
          <div class="major-group-head">
            <span class="event-kind major">大事件{{ numbers.get(Number(group.major?.id))?.number ?? '' }}</span>
            <span class="event-title">{{ group.major?.event_title || '未命名大事件' }}</span>
            <span class="event-meta">{{ group.minors.length }} 个小事件</span>
          </div>

          <p
            v-if="summaries.get(Number(group.major?.id))?.text.trim()"
            class="major-summary"
          >
            {{ summaries.get(Number(group.major?.id))?.text }}<span
              v-if="summaries.get(Number(group.major?.id))?.truncated"
              class="summary-more"
            >……（共 {{ summaries.get(Number(group.major?.id))?.length }} 字，完整内容见「大纲正文」）</span>
          </p>

          <div v-if="group.minors.length" class="minor-list">
            <div v-for="minor in group.minors" :key="String(minor.id)" class="event-minor">
              <div class="event-minor-head">
                <span class="event-kind">小事件{{ numbers.get(Number(minor.id))?.number ?? '' }}</span>
                <span class="event-title">{{ minor.event_title || '未命名小事件' }}</span>
                <span class="event-status" :class="{ done: hasContent(minor) }">
                  {{ hasContent(minor) ? '已写' : '待写' }}
                </span>
                <button v-if="hasContent(minor)" type="button" class="link-btn" @click="openChapter(minor)">
                  看正文
                </button>
              </div>
              <p v-if="summaries.get(Number(minor.id))?.text.trim()" class="event-summary">
                {{ summaries.get(Number(minor.id))?.text }}<span
                  v-if="summaries.get(Number(minor.id))?.truncated"
                  class="summary-more"
                >……（共 {{ summaries.get(Number(minor.id))?.length }} 字，完整内容见「大纲正文」）</span>
              </p>
              <p v-else class="event-summary muted">还没有概要</p>
            </div>
          </div>
          <div v-else class="major-no-minor">这个大事件下还没有小事件。</div>
          </article>
        </template>
      </div>
    </section>
  </div>
</template>

<style scoped>
.meta-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin-bottom: 16px;
}

.meta-chip {
  padding: 3px 9px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--bg-card);
  color: var(--ink-3);
  font-size: 11.5px;
}

.view-tabs {
  display: inline-flex;
  gap: 4px;
  padding: 4px;
  margin-bottom: 16px;
  border-radius: 10px;
  background: var(--bg-card);
  border: 1px solid var(--line);
}

.view-tabs button {
  padding: 7px 18px;
  border: none;
  border-radius: 8px;
  background: transparent;
  font-size: 13px;
  color: var(--ink-2);
  cursor: pointer;
}

.view-tabs button.on {
  background: var(--brand-soft);
  color: var(--brand);
  font-weight: 600;
}

.outline-body { padding: 22px 26px 28px; }

.outline-text {
  margin: 0;
  font-family: var(--font-serif);
  font-size: 14.5px;
  line-height: 1.95;
  color: var(--ink-1);
  white-space: pre-wrap;
  word-break: break-word;
  max-width: 980px;
}

.event-body { padding: 6px 16px 20px; }

.event-major {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 18px;
  padding: 14px 14px 8px;
  border-bottom: 1px solid var(--line);
}

.event-major:first-child { margin-top: 6px; }

.event-kind {
  padding: 1px 7px;
  border-radius: 5px;
  border: 1px solid var(--line);
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 10.5px;
  white-space: nowrap;
}

.event-kind.major {
  color: var(--brand);
  border-color: var(--line-strong);
  background: var(--brand-soft);
}

.event-title { font-size: 13px; font-weight: 600; color: var(--ink-1); }

.event-meta { margin-left: auto; font-size: 11px; color: var(--ink-4); }

.event-minor {
  padding: 12px 14px 13px;
  border-bottom: 1px solid var(--line);
}

.event-minor:last-child { border-bottom: none; }
.event-minor:hover { background: var(--bg-soft); }

.event-minor-head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.event-minor-head .event-title { font-weight: 500; font-size: 12.5px; color: var(--ink-2); }

.event-status {
  padding: 1px 6px;
  border-radius: 5px;
  border: 1px solid var(--line);
  background: var(--bg-soft);
  color: var(--ink-4);
  font-size: 10px;
}

.event-status.done {
  border-color: transparent;
  background: var(--ok-soft);
  color: var(--ok);
}

.link-btn {
  margin-left: auto;
  padding: 2px 6px;
  border: none;
  background: transparent;
  color: var(--ink-2);
  font-size: 11.5px;
  cursor: pointer;
  text-decoration: underline;
  text-underline-offset: 3px;
}

.link-btn:hover { color: var(--ink-1); }

.event-summary {
  margin: 7px 0 0;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-word;
}

.event-summary.muted { color: var(--ink-4); }

.summary-more { color: var(--ink-4); }

/* ── 按大事件显示 ── */
.major-toolbar {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--line);
  background: var(--bg-soft);
}

.major-select-list {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-wrap: wrap;
  gap: 2px 16px;
  max-height: 156px;
  overflow-y: auto;
  padding-right: 6px;
}

.major-select-list :deep(.el-checkbox) {
  margin-right: 0;
  height: 24px;
  max-width: 100%;
}

.major-select-list :deep(.el-checkbox__label) {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  color: var(--ink-2);
}

.major-toolbar-actions { display: flex; align-items: center; gap: 2px; flex: 0 0 auto; }

.major-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
}

.major-group {
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--bg-card);
  overflow: hidden;
}

.major-group-head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  padding: 11px 14px;
  border-bottom: 1px solid var(--line);
  background: var(--bg-soft);
}

.major-summary {
  margin: 0;
  padding: 10px 14px 2px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-word;
}

.minor-list { padding: 2px 14px 6px; }

.major-no-minor {
  padding: 12px 14px;
  font-size: 11.5px;
  color: var(--ink-4);
}

@media (max-width: 880px) {
  .outline-body { padding: 16px 16px 20px; }
  .major-toolbar { flex-direction: column; }
  .major-toolbar-actions { align-self: flex-end; }
  .major-body { padding: 12px; }
}
</style>