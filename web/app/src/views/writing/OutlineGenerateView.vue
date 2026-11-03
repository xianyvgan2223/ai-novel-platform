<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Check, MagicStick, Setting, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { GeneratedOutline } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { loadAiSettings, outlineRequestSettings } from './novelSettings';

const router = useRouter();

const form = ref({
  genre: '都市',
  theme: '',
  protagonist: '',
  worldview: '',
  majorCount: 6,
  minorCount: 3,
  extra: '',
});

const running = ref(false);
const saving = ref(false);
const saved = ref(0);
const stage = ref({ index: 0, total: 4, label: '' });
const log = ref('');
const result = ref<GeneratedOutline | null>(null);
const settingsVisible = ref(false);
let controller: AbortController | null = null;

onMounted(loadAiSettings);

async function start() {
  if (running.value) return;
  if (!form.value.genre.trim()) {
    ElMessage.warning('先填一个题材');
    return;
  }
  running.value = true;
  result.value = null;
  log.value = '';
  saved.value = 0;
  controller = new AbortController();
  try {
    await api.writing.novel.generateOutline(
      {
        genre: form.value.genre.trim(),
        theme: form.value.theme.trim(),
        protagonist: form.value.protagonist.trim(),
        worldview: form.value.worldview.trim(),
        majorCount: form.value.majorCount,
        minorCount: form.value.minorCount,
        extra: form.value.extra.trim() || undefined,
        settings: outlineRequestSettings(),
      },
      {
        onStage: (value) => { stage.value = value; },
        onDelta: (text) => {
          log.value += text;
          if (log.value.length > 8000) log.value = log.value.slice(-8000);
        },
        onResult: (data) => { result.value = data as unknown as GeneratedOutline; },
      },
      controller.signal,
    );
    if (result.value) ElMessage.success('大纲生成完成，可以保存为作品了');
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成');
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

async function save() {
  const data = result.value;
  if (!data || saving.value) return;
  saving.value = true;
  saved.value = 0;
  try {
    const now = new Date().toISOString();
    const created = await api.createRow('deepseek', 'outline_records', {
      title: data.title,
      genre: data.genre,
      theme: data.theme,
      protagonist: data.protagonist,
      worldview: data.worldview,
      content: data.outlineText,
      skeleton: data.skeletonJson,
      characters: data.charactersJson,
      created_at: now,
    });
    const outlineId = Number(created.pk);
    for (const row of data.chapters) {
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
      saved.value += 1;
    }
    ElMessage.success('已保存为作品：' + data.title);
    router.push('/writing/outlines?intent=edit');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="page">
    <PageHeader
      title="一键生成大纲"
      desc="填写设定，AI 会分阶段生成书名、三幕结构、大事件和小事件。"
      back="/writing"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
      </template>
    </PageHeader>

    <div class="gen-grid">
      <section class="card">
        <h3 class="block-title">小说设定</h3>
        <el-form label-position="top">
          <el-form-item label="题材">
            <el-input v-model="form.genre" placeholder="都市 / 玄幻 / 悬疑…" />
          </el-form-item>
          <el-form-item label="主题（可选）">
            <el-input v-model="form.theme" placeholder="例如：职场逆袭、身份错位" />
          </el-form-item>
          <el-form-item label="主角（可选）">
            <el-input v-model="form.protagonist" placeholder="例如：林舟，28 岁产品经理，被裁后重生" />
          </el-form-item>
          <el-form-item label="世界观（可选）">
            <el-input v-model="form.worldview" type="textarea" :rows="2" placeholder="例如：现代都市，一家垄断 AI 的大公司" />
          </el-form-item>
          <div class="count-row">
            <el-form-item label="主事件数（3~12）">
              <el-input-number v-model="form.majorCount" :min="3" :max="12" controls-position="right" class="full" />
            </el-form-item>
            <el-form-item label="每个主事件的小事件数（1~5）">
              <el-input-number v-model="form.minorCount" :min="1" :max="5" controls-position="right" class="full" />
            </el-form-item>
          </div>
          <el-form-item label="额外要求（可选）">
            <el-input v-model="form.extra" type="textarea" :rows="2" placeholder="例如：不要系统流，感情线克制" />
          </el-form-item>
        </el-form>

        <div class="run-row">
          <el-button v-if="!running" type="primary" :icon="MagicStick" @click="start">开始生成</el-button>
          <el-button v-else type="danger" plain :icon="VideoPause" @click="stop">停止</el-button>
          <span class="hint">生成约 1~3 分钟，可随时停止</span>
        </div>
      </section>

      <section class="card">
        <h3 class="block-title">生成进度</h3>
        <div v-if="!running && !result && !log" class="empty-hint">左边填好设定，点「开始生成」。</div>
        <template v-else>
          <div class="stage-row">
            <span class="stage-index">{{ stage.index || 1 }}/{{ stage.total || 4 }}</span>
            <span class="stage-label">{{ stage.label || '正在生成…' }}</span>
          </div>
          <div v-if="running" class="gen-log">{{ log }}</div>

          <div v-if="result" class="result-box">
            <div class="result-title">《{{ result.title }}》</div>
            <div class="result-meta">
              {{ result.majorCount }} 个大事件 ·
              {{ result.chapters.filter((item) => item.type === 'minor').length }} 个小事件
            </div>
            <p class="result-desc">{{ result.concept }}</p>
            <p class="result-outline">{{ result.outlineText }}</p>
            <div class="run-row">
              <el-button type="primary" :icon="Check" :loading="saving" @click="save">
                {{ saving ? `保存中 ${saved}/${result.chapters.length}` : '保存为作品' }}
              </el-button>
              <el-button text :disabled="running" @click="start">重新生成</el-button>
            </div>
          </div>
        </template>
      </section>
    </div>

    <AiSettingsDrawer v-model="settingsVisible" kind="outline" />
  </div>
</template>

<style scoped>
.gen-grid {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .gen-grid { grid-template-columns: minmax(0, 1fr); }
}

.block-title {
  margin: 0 0 14px;
  font-size: 14.5px;
  font-weight: 620;
  color: var(--ink-1);
}

.count-row {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 14px;
}

.full { width: 100%; }

.run-row { display: flex; align-items: center; gap: 12px; margin-top: 8px; }
.hint { font-size: 12px; color: var(--ink-4); }

.stage-row { display: flex; align-items: center; gap: 10px; }

.stage-index {
  padding: 2px 8px;
  border-radius: 6px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 11px;
  font-weight: 600;
}

.stage-label { font-size: 13px; color: var(--ink-2); }

.gen-log {
  max-height: 260px;
  overflow: auto;
  margin-top: 12px;
  padding: 10px 12px;
  border-radius: 9px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 11px;
  line-height: 1.6;
  color: var(--ink-3);
  white-space: pre-wrap;
  word-break: break-word;
}

.result-box {
  margin-top: 16px;
  padding-top: 16px;
  border-top: 1px solid var(--line);
}

.result-title { font-size: 17px; font-weight: 650; color: var(--ink-1); }
.result-meta { margin-top: 4px; font-size: 12.5px; color: var(--ink-3); }

.result-desc {
  margin: 10px 0 0;
  font-size: 13px;
  line-height: 1.7;
  color: var(--ink-2);
}

.result-outline {
  max-height: 260px;
  overflow: auto;
  margin: 12px 0 0;
  padding: 12px 14px;
  border-radius: 9px;
  background: var(--bg-soft);
  font-family: 'Source Han Serif SC', 'Songti SC', serif;
  font-size: 13px;
  line-height: 1.8;
  color: var(--ink-1);
  white-space: pre-wrap;
}
</style>
