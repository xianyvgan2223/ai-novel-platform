<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import {
  Check, EditPen, MagicStick, Refresh, Setting, VideoPause,
} from '@element-plus/icons-vue';
import { api } from '@/api';
import type { ChapterGeneratePayload, Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import {
  isMajor, isMinor, loadChapters, loadOutline, saveChapterContent, statsOf,
} from './novelApi';
import { chapterRequestSettings, chapterSettings, loadAiSettings } from './novelSettings';

const props = defineProps<{ id: string }>();
const router = useRouter();

const outline = ref<Row | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);
const splitting = ref(false);
const generatingId = ref<number | null>(null);

const batchRunning = ref(false);
const batchTotal = ref(0);
const batchDone = ref(0);
const batchTitle = ref('');
const preview = ref('');
const stopped = ref(false);
const settingsVisible = ref(false);
let controller: AbortController | null = null;

const outlineId = computed(() => Number(props.id));
const stats = computed(() => statsOf(chapters.value));
const contentCache = new Map<number, string>();

async function load() {
  loading.value = true;
  try {
    outline.value = await loadOutline(outlineId.value);
    chapters.value = await loadChapters(outlineId.value);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

async function split() {
  if (!outline.value || splitting.value) return;
  if (!String(outline.value.content ?? '').trim()) {
    ElMessage.warning('这部作品还没有大纲正文，先去「大纲编辑」补上');
    return;
  }
  splitting.value = true;
  try {
    const result = await api.writing.novel.splitOutline({
      title: String(outline.value.title ?? ''),
      genre: String(outline.value.genre ?? ''),
      theme: String(outline.value.theme ?? ''),
      protagonist: String(outline.value.protagonist ?? ''),
      worldview: String(outline.value.worldview ?? ''),
      outlineText: String(outline.value.content ?? ''),
      settings: chapterRequestSettings(),
    });
    const now = new Date().toISOString();
    for (const row of result.chapters) {
      await api.createRow('deepseek', 'outline_chapters', {
        outline_id: outlineId.value,
        event_index: row.index,
        event_type: row.type,
        event_title: row.title,
        event_summary: row.summary ?? '',
        content: '',
        status: 'pending',
        created_at: now,
        updated_at: now,
      });
    }
    await api.updateRow('deepseek', 'outline_records', outlineId.value, {
      skeleton: result.actsJson,
    });
    await load();
    ElMessage.success('已拆成 ' + result.chapters.length + ' 个事件/小事件');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    splitting.value = false;
  }
}

async function prevContext(index: number): Promise<{ title: string; content: string }> {
  for (let i = index - 1; i >= 0; i--) {
    const row = chapters.value[i];
    if (!isMinor(row)) continue;
    const id = Number(row.id);
    let content = contentCache.get(id) ?? '';
    if (!content) {
      try {
        const full = await api.getRow('deepseek', 'outline_chapters', id);
        content = String(full.ai_summary ?? '').trim() || String(full.content ?? '');
      } catch {
        content = String(row.content ?? '');
      }
    }
    return { title: String(row.event_title ?? ''), content };
  }
  return { title: '', content: '' };
}

function nextTitle(index: number): string {
  for (let i = index + 1; i < chapters.value.length; i++) {
    if (isMinor(chapters.value[i])) return String(chapters.value[i].event_title ?? '');
  }
  return '';
}

async function buildPayload(row: Row): Promise<ChapterGeneratePayload> {
  const work = outline.value!;
  const index = chapters.value.findIndex((item) => Number(item.id) === Number(row.id));
  const prev = await prevContext(index);
  return {
    title: String(work.title ?? ''),
    genre: String(work.genre ?? ''),
    theme: String(work.theme ?? ''),
    protagonist: String(work.protagonist ?? ''),
    worldview: String(work.worldview ?? ''),
    outlineContent: String(work.content ?? ''),
    chapterTitle: String(row.event_title ?? ''),
    chapterSummary: String(row.event_summary ?? ''),
    prevChapterTitle: prev.title || undefined,
    prevChapterContent: prev.content ? prev.content.slice(-1200) : undefined,
    nextChapterTitle: nextTitle(index) || undefined,
    characters: String(work.characters ?? '') || undefined,
    foreshadows: String(work.foreshadows ?? '') || undefined,
    storyState: String(work.story_state ?? '') || undefined,
    minWords: chapterSettings.chapterMinWords,
    maxWords: chapterSettings.chapterMaxWords,
    settings: chapterRequestSettings(),
  };
}

async function generateOne(row: Row, withPreview: boolean): Promise<void> {
  const payload = await buildPayload(row);
  let text = '';
  controller = new AbortController();
  try {
    await api.writing.novel.generateChapter(
      payload,
      {
        onDelta: (delta) => {
          text += delta;
          if (withPreview) preview.value = text;
        },
      },
      controller.signal,
    );
  } finally {
    controller = null;
  }
  await saveChapterContent(Number(row.id), text);
  contentCache.set(Number(row.id), text);
  row.content = text;
  row.status = 'completed';
}

async function generateSingle(row: Row) {
  if (generatingId.value !== null || batchRunning.value) return;
  generatingId.value = Number(row.id);
  preview.value = '';
  batchTitle.value = String(row.event_title ?? '');
  try {
    await generateOne(row, true);
    ElMessage.success('正文已生成并保存');
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    generatingId.value = null;
  }
}

async function batchGenerate() {
  if (batchRunning.value) return;
  const pending = chapters.value.filter(
    (row) => isMinor(row) && (String(row.status) !== 'completed' || !String(row.content ?? '').trim()),
  );
  if (!pending.length) {
    ElMessage.info('所有小事件都已经生成过了');
    return;
  }

  batchRunning.value = true;
  stopped.value = false;
  batchTotal.value = pending.length;
  batchDone.value = 0;

  for (const row of pending) {
    if (stopped.value) break;
    batchTitle.value = String(row.event_title ?? '');
    preview.value = '';
    try {
      await generateOne(row, true);
      batchDone.value += 1;
    } catch (err) {
      if ((err as Error).name === 'AbortError') break;
      ElMessage.error(err instanceof Error ? err.message : String(err));
      break;
    }
  }

  batchRunning.value = false;
  if (!stopped.value && batchDone.value === batchTotal.value) {
    ElMessage.success('全部小事件生成完成');
  }
}

function stopBatch() {
  stopped.value = true;
  controller?.abort();
}

onMounted(async () => {
  await loadAiSettings();
  await load();
});
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(outline?.title || '小事件详写') + ' · 小事件详写'"
      :desc="`${stats.minor} 个小事件，已生成 ${stats.written} 个。按大纲逐个写正文，结果直接保存回库。`"
      back="/writing/outlines?intent=convert"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
        <el-button :icon="EditPen" @click="router.push(`/writing/outline/${id}/edit`)">编辑大纲</el-button>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <div v-if="!chapters.length" class="card split-card">
      <div>
        <div class="split-title">这部作品还没有小事件结构</div>
        <div class="split-desc">让 AI 按现有大纲拆出「大事件 → 小事件」，之后就可以逐个生成正文。</div>
      </div>
      <el-button type="primary" :icon="MagicStick" :loading="splitting" @click="split">
        {{ splitting ? '正在拆分小事件…' : 'AI 按大纲拆分小事件' }}
      </el-button>
    </div>

    <template v-else>
      <div class="card batch-card">
        <div class="batch-info">
          <div class="batch-title">
            {{ batchRunning ? `正在生成 ${batchDone}/${batchTotal}：${batchTitle}` : `共 ${stats.minor} 个小事件，已生成 ${stats.written} 个` }}
          </div>
          <div class="batch-desc">批量生成会从第一个未完成小事件开始，逐个生成并自动保存。</div>
        </div>
        <div class="row-gap">
          <el-button
            v-if="!batchRunning"
            type="primary"
            :icon="MagicStick"
            @click="batchGenerate"
          >
            逐个小事件生成未完成项
          </el-button>
          <el-button v-else type="danger" plain :icon="VideoPause" @click="stopBatch">停止</el-button>
        </div>
      </div>

      <div v-if="batchRunning || preview" class="card preview-card">
        <div class="preview-head">
          <span>生成预览 · {{ batchTitle }}</span>
          <span class="mono text-muted">{{ preview.length }} 字</span>
        </div>
        <div class="preview-text">{{ preview }}<span v-if="batchRunning" class="caret" /></div>
      </div>

      <div class="chapter-list">
        <template v-for="item in chapters" :key="String(item.id)">
          <div v-if="isMajor(item)" class="major-row">
            <span class="major-title">{{ item.event_title || '未命名大事件' }}</span>
            <span class="major-tag">大事件</span>
          </div>
          <div v-else class="chapter-row card">
            <div class="cr-main">
              <div class="cr-title">{{ item.event_title || '未命名小事件' }}</div>
              <div class="cr-meta">
                {{ String(item.status) === 'completed' ? '已生成' : '待生成' }}
                <template v-if="String(item.content ?? '').trim()"> · {{ String(item.content).length }} 字</template>
              </div>
            </div>
            <div class="cr-actions">
              <el-button
                size="small"
                :type="String(item.status) === 'completed' ? 'default' : 'primary'"
                :icon="Check"
                :loading="generatingId === Number(item.id)"
                :disabled="batchRunning"
                @click="generateSingle(item)"
              >
                {{ String(item.status) === 'completed' ? '重新生成' : '生成正文' }}
              </el-button>
              <el-button size="small" text @click="router.push('/writing/chapter/' + item.id)">去写作</el-button>
            </div>
          </div>
        </template>
      </div>
    </template>

    <AiSettingsDrawer v-model="settingsVisible" kind="chapter" />
  </div>
</template>

<style scoped>
.split-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
}

.split-title { font-size: 15px; font-weight: 620; color: var(--ink-1); }
.split-desc { margin-top: 5px; font-size: 12.5px; color: var(--ink-3); }

.batch-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 18px;
}

.batch-title { font-size: 14px; font-weight: 600; color: var(--ink-1); }
.batch-desc { margin-top: 4px; font-size: 12px; color: var(--ink-3); }

.preview-card { padding: 16px 20px; }
.preview-head { display: flex; justify-content: space-between; font-size: 12px; color: var(--ink-2); font-weight: 600; }

.preview-text {
  max-height: 200px;
  overflow: auto;
  margin-top: 8px;
  font-family: 'Source Han Serif SC', 'Songti SC', serif;
  font-size: 13.5px;
  line-height: 1.85;
  white-space: pre-wrap;
  color: var(--ink-1);
}

.chapter-list { display: flex; flex-direction: column; gap: 10px; }

.major-row { display: flex; align-items: center; gap: 8px; padding: 10px 4px 2px; }
.major-title { font-size: 12px; font-weight: 600; color: var(--ink-3); }
.major-tag {
  padding: 1px 6px;
  border-radius: 5px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  color: var(--ink-4);
  font-size: 10px;
}

.chapter-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 14px 18px;
  margin-bottom: 0;
}

.cr-title { font-size: 14px; font-weight: 500; color: var(--ink-1); }
.cr-meta { margin-top: 3px; font-size: 11.5px; color: var(--ink-4); }
.cr-actions { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; }

.caret {
  display: inline-block;
  width: 7px;
  height: 15px;
  margin-left: 2px;
  vertical-align: -2px;
  background: var(--brand);
  animation: blink 1s steps(2, start) infinite;
}

@keyframes blink { to { opacity: 0; } }

.row-gap { display: flex; align-items: center; gap: 8px; }
</style>
