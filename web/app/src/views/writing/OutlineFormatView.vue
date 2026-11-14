<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Check, DocumentCopy, MagicStick, Refresh, Setting, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { GeneratedChapterRow } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { chapterRequestSettings, loadAiSettings, outlineRequestSettings } from './novelSettings';

const router = useRouter();

const raw = ref('');
const result = ref('');
const running = ref(false);
const elapsed = ref<number | null>(null);
const settingsVisible = ref(false);
const saving = ref(false);
const splitAfterSave = ref(true);
let controller: AbortController | null = null;

/** AI 输出第一行的书名：《xxx》 */
const detectedTitle = computed(() => {
  const match = /书名[:：]\s*《([^》]+)》/.exec(result.value);
  return match ? match[1].trim() : '';
});

async function runFormat() {
  if (running.value) return;
  if (!raw.value.trim()) {
    ElMessage.warning('先把要格式化的大纲内容粘贴到左侧');
    return;
  }
  result.value = '';
  elapsed.value = null;
  running.value = true;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.novel.formatOutline(
      { input: raw.value, settings: outlineRequestSettings() },
      {
        onDelta: (delta) => { result.value += delta; },
        onDone: (info) => { elapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    running.value = false;
    controller = null;
  }
}

function stop() {
  controller?.abort();
}

async function saveWork() {
  const content = result.value.trim();
  if (!content) {
    ElMessage.warning('还没有可保存的格式化结果');
    return;
  }
  const title = detectedTitle.value || '未命名作品';
  saving.value = true;
  try {
    const now = new Date().toISOString();
    const created = await api.createRow('deepseek', 'outline_records', {
      title,
      content,
      created_at: now,
    });
    const id = Number(created.pk);
    if (splitAfterSave.value) {
      const split = await api.writing.novel.splitOutline({
        title,
        outlineText: content,
        settings: chapterRequestSettings(),
      });
      await insertChapters(id, split.chapters, now);
      ElMessage.success(`已保存《${title}》，并拆出 ${split.chapters.length} 个事件/小事件`);
    } else {
      ElMessage.success(`已保存《${title}》`);
    }
    router.push(`/writing/outline/${id}/edit`);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function insertChapters(outlineId: number, chapters: GeneratedChapterRow[], now: string) {
  for (const row of chapters) {
    await api.createRow('deepseek', 'outline_chapters', {
      outline_id: outlineId,
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
}

onMounted(() => {
  void loadAiSettings();
});
</script>

<template>
  <div class="page">
    <PageHeader
      title="匹配大纲格式"
      desc="把网上找来的、手机里存的任意大纲文本粘贴进来，AI 会重排成 App 的三幕 / 大事件 / 小事件格式，并可直接保存成新作品。"
      back="/writing"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
      </template>
    </PageHeader>

    <div class="format-grid">
      <section class="card card-flush">
        <div class="card-head">
          <h3>原始大纲</h3>
          <span class="mono text-muted">{{ raw.length }} 字</span>
        </div>
        <div class="pad">
          <textarea
            v-model="raw"
            class="raw-textarea"
            rows="20"
            placeholder="粘贴任意格式的大纲：分卷大纲、小事件列表、剧情梗概都可以…"
          />
          <div class="run-row">
            <el-button v-if="!running" type="primary" :icon="MagicStick" @click="runFormat">
              AI 格式化
            </el-button>
            <el-button v-else type="danger" plain :icon="VideoPause" @click="stop">停止</el-button>
            <span class="hint">只做格式重排，不增删情节；结果可再手动修改。</span>
          </div>
        </div>
      </section>

      <section class="card card-flush">
        <div class="card-head">
          <h3>格式化结果</h3>
          <span class="mono text-muted">
            {{ running ? '生成中…' : `${result.length} 字` }}
            <template v-if="!running && elapsed"> · {{ (elapsed / 1000).toFixed(1) }}s</template>
          </span>
        </div>
        <div class="pad">
          <div v-if="!result && !running" class="empty-hint">
            格式化结果会显示在这里，可以直接编辑后再保存。
          </div>
          <textarea
            v-model="result"
            class="raw-textarea result-textarea"
            rows="20"
            placeholder="AI 输出会出现在这里"
          />
          <div class="foot-row">
            <div class="title-line">
              识别书名：
              <strong>{{ detectedTitle || '未识别' }}</strong>
            </div>
            <div class="actions">
              <el-checkbox v-model="splitAfterSave">保存后立即拆成小事件</el-checkbox>
              <el-button :icon="Refresh" :disabled="running" @click="runFormat">重新格式化</el-button>
              <el-button type="primary" :icon="DocumentCopy" :loading="saving" :disabled="running || !result.trim()" @click="saveWork">
                保存为新作品
              </el-button>
            </div>
          </div>
          <div v-if="result" class="done-hint">
            <el-icon><Check /></el-icon>
            保存后可在「大纲编辑」里继续修改。
          </div>
        </div>
      </section>
    </div>

    <AiSettingsDrawer v-model="settingsVisible" kind="outline" />
  </div>
</template>

<style scoped>
.format-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .format-grid { grid-template-columns: minmax(0, 1fr); }
}

.pad { padding: 16px 18px 18px; }

.raw-textarea {
  display: block;
  width: 100%;
  min-height: 380px;
  padding: 14px 16px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--bg-soft);
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 13.5px;
  line-height: 1.85;
  color: var(--ink-1);
  resize: vertical;
  outline: none;
}

.raw-textarea:focus { border-color: var(--line-strong); background: var(--bg-card); }

.result-textarea { min-height: 420px; }

.run-row { display: flex; align-items: center; gap: 12px; margin-top: 12px; }
.hint { font-size: 11.5px; color: var(--ink-4); }

.foot-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-top: 12px;
  flex-wrap: wrap;
}

.title-line { font-size: 12.5px; color: var(--ink-3); }
.title-line strong { color: var(--ink-1); }

.actions { display: flex; align-items: center; gap: 10px; }

.done-hint {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 10px;
  font-size: 11.5px;
  color: var(--ink-4);
}
</style>
