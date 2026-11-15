<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Check, MagicStick, Setting, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type {
  GeneratedChapterRow,
  GeneratedOutline,
  OutlineAct,
  OutlineConceptResult,
  OutlineEventsResult,
  OutlineMinorResult,
  OutlineSkeletonResult,
  OutlineStagePayload,
} from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { loadAiSettings, outlineRequestSettings, outlineSettings } from './novelSettings';
import { countEvents, parseActs, parseChapters, renderActs } from './outlineStages';

const router = useRouter();

type StageName = 'idle' | 'concept' | 'skeleton' | 'events' | 'minor' | 'done';
type CheckpointKind = 'skeleton' | 'events' | 'minor' | null;

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
const phase = ref<StageName>('idle');
const checkpoint = ref<CheckpointKind>(null);
const stage = ref({ index: 0, total: 4, label: '' });
const log = ref('');
const checkpointText = ref('');
const finalText = ref('');
const chapters = ref<GeneratedChapterRow[]>([]);
const result = ref<GeneratedOutline | null>(null);
const settingsVisible = ref(false);

const conceptResult = ref<OutlineConceptResult | null>(null);
const skeletonResult = ref<OutlineSkeletonResult | null>(null);
const eventsResult = ref<OutlineEventsResult | null>(null);
const minorResult = ref<OutlineMinorResult | null>(null);

const coarseActs = ref<OutlineAct[]>([]);
const currentActs = ref<OutlineAct[]>([]);
const ledgerText = ref('');
let controller: AbortController | null = null;

const canContinue = computed(() => !running.value && checkpoint.value != null);
const checkpointLabel = computed(() => {
  if (checkpoint.value === 'skeleton') return '粗骨架检查点';
  if (checkpoint.value === 'events') return '大事件检查点';
  if (checkpoint.value === 'minor') return '小事件检查点';
  return '';
});
const checkpointDesc = computed(() => {
  if (checkpoint.value === 'skeleton') {
    return '粗骨架已生成。可以直接编辑每幕的大事件标题与定位，确认后继续生成大事件。';
  }
  if (checkpoint.value === 'events') {
    return '大事件概述已精写完成。可以编辑标题与概述；修改后继续会据此生成小事件。';
  }
  if (checkpoint.value === 'minor') {
    return '全部小事件已展开。可以编辑全文，确认后完成；也可以返回上一步修改大事件。';
  }
  return '';
});
const phaseLabel = computed(() => {
  if (phase.value === 'concept') return '生成书名与核心概念';
  if (phase.value === 'skeleton') return '规划三幕粗骨架';
  if (phase.value === 'events') return '精写大事件';
  if (phase.value === 'minor') return '展开小事件';
  if (phase.value === 'done') return '大纲已生成';
  return '等待开始';
});

onMounted(loadAiSettings);

function basePayload() {
  return {
    genre: form.value.genre.trim(),
    theme: form.value.theme.trim(),
    protagonist: form.value.protagonist.trim(),
    worldview: form.value.worldview.trim(),
    extra: form.value.extra.trim() || undefined,
    majorCount: form.value.majorCount,
    minorCount: form.value.minorCount,
    settings: outlineRequestSettings(),
  };
}

function resetState() {
  checkpoint.value = null;
  phase.value = 'idle';
  stage.value = { index: 0, total: 4, label: '' };
  log.value = '';
  checkpointText.value = '';
  finalText.value = '';
  chapters.value = [];
  result.value = null;
  saved.value = 0;
  conceptResult.value = null;
  skeletonResult.value = null;
  eventsResult.value = null;
  minorResult.value = null;
  coarseActs.value = [];
  currentActs.value = [];
  ledgerText.value = '';
}

function resetLog() {
  log.value = '';
}

function setStage(index: number, total: number, label: string) {
  stage.value = { index, total, label };
}

function appendDelta(text: string) {
  log.value += text;
  if (log.value.length > 12000) log.value = log.value.slice(-12000);
}

async function streamStage(
  kind: 'concept' | 'skeleton' | 'events' | 'minor',
  payload: OutlineStagePayload,
  onResult: (data: Record<string, unknown>) => void,
) {
  const method = api.writing.novel.outlineStages[kind];
  await method(payload, {
    onStage: (value) => setStage(value.index, value.total, value.label),
    onDelta: appendDelta,
    onResult,
  }, controller?.signal);
}

function ensureNotAborted() {
  return !controller?.signal.aborted;
}

async function generateConcept() {
  phase.value = 'concept';
  setStage(1, 4, '生成书名与核心概念');
  resetLog();
  let data: OutlineConceptResult | null = null;
  await streamStage('concept', { ...basePayload() }, (payload) => {
    data = payload as unknown as OutlineConceptResult;
  });
  const concept = data as OutlineConceptResult | null;
  if (!concept) throw new Error('书名和核心概念生成失败');
  conceptResult.value = concept;
  if (!ensureNotAborted()) return;
}

async function generateSkeleton() {
  phase.value = 'skeleton';
  setStage(2, 4, '规划三幕粗骨架');
  resetLog();
  const concept = conceptResult.value;
  if (!concept) throw new Error('缺少定调结果');
  let data: OutlineSkeletonResult | null = null;
  await streamStage('skeleton', {
    ...basePayload(),
    title: concept.title,
    concept: concept.concept,
    conceptText: concept.conceptText,
  }, (payload) => {
    data = payload as unknown as OutlineSkeletonResult;
  });
  const skeleton = data as OutlineSkeletonResult | null;
  if (!skeleton) throw new Error('粗骨架生成失败');
  skeletonResult.value = skeleton;
  coarseActs.value = skeleton.acts;
  currentActs.value = skeleton.acts;
  checkpointText.value = skeleton.coarseText;
  if (!ensureNotAborted()) return;
}

async function generateEvents(acts: OutlineAct[]) {
  phase.value = 'events';
  setStage(3, 4, '分批精写大事件');
  resetLog();
  const concept = conceptResult.value;
  if (!concept) throw new Error('缺少定调结果');
  let data: OutlineEventsResult | null = null;
  await streamStage('events', {
    ...basePayload(),
    title: concept.title,
    concept: concept.concept,
    acts,
  }, (payload) => {
    data = payload as unknown as OutlineEventsResult;
  });
  const events = data as OutlineEventsResult | null;
  if (!events) throw new Error('大事件精写失败');
  eventsResult.value = events;
  currentActs.value = events.acts;
  ledgerText.value = events.ledgerText;
  checkpointText.value = events.eventsText;
  if (!ensureNotAborted()) return;
}

async function generateMinor(acts: OutlineAct[]) {
  phase.value = 'minor';
  setStage(4, 4, '展开小事件');
  resetLog();
  const concept = conceptResult.value;
  if (!concept) throw new Error('缺少定调结果');
  let data: OutlineMinorResult | null = null;
  await streamStage('minor', {
    ...basePayload(),
    title: concept.title,
    concept: concept.concept,
    acts,
    ledgerText: ledgerText.value,
  }, (payload) => {
    data = payload as unknown as OutlineMinorResult;
  });
  const minor = data as OutlineMinorResult | null;
  if (!minor) throw new Error('小事件展开失败');
  minorResult.value = minor;
  finalText.value = minor.outlineText;
  chapters.value = minor.chapters;
  checkpointText.value = minor.outlineText;
  if (!ensureNotAborted()) return;
}

function showCheckpoint(kind: Exclude<CheckpointKind, null>) {
  checkpoint.value = kind;
  running.value = false;
  if (kind === 'skeleton') {
    phase.value = 'skeleton';
    checkpointText.value = skeletonResult.value?.coarseText || renderActs(coarseActs.value);
  } else if (kind === 'events') {
    phase.value = 'events';
    checkpointText.value = eventsResult.value?.eventsText || renderActs(currentActs.value);
  } else {
    phase.value = 'done';
    checkpointText.value = finalText.value;
  }
  ElMessage.info(checkpointLabel.value + '：检查内容后点击继续');
}

function parseCheckpointActs(): OutlineAct[] {
  const acts = parseActs(checkpointText.value);
  if (!acts.length) {
    throw new Error('检查点内容无法解析，请保留「══ 第X幕：… ══」和「══ 大事件N：标题 ══」格式');
  }
  return acts;
}

function makeResult(outlineText: string, rows: GeneratedChapterRow[]): GeneratedOutline {
  const concept = conceptResult.value;
  return {
    title: concept?.title || '未命名作品',
    concept: concept?.concept || '',
    genre: form.value.genre.trim(),
    theme: form.value.theme.trim(),
    protagonist: form.value.protagonist.trim(),
    worldview: form.value.worldview.trim(),
    charactersJson: '[]',
    skeletonJson: JSON.stringify({ acts: currentActs.value, coarse: coarseActs.value }),
    outlineText,
    chapters: rows,
    majorCount: countEvents(currentActs.value),
    minorCount: form.value.minorCount,
  };
}

function finishGeneration() {
  checkpoint.value = null;
  phase.value = 'done';
  running.value = false;
  finalText.value = finalText.value || checkpointText.value;
  const originalText = minorResult.value?.outlineText ?? '';
  const edited = originalText.trim() !== '' && finalText.value.trim() !== originalText.trim();
  if (edited) {
    const parsedRows = parseChapters(finalText.value);
    if (parsedRows.length) chapters.value = parsedRows;
  } else if (minorResult.value?.chapters.length) {
    chapters.value = minorResult.value.chapters;
  }
  result.value = makeResult(finalText.value, chapters.value);
  ElMessage.success('大纲生成完成，可以保存为作品了');
}

async function runAfterSkeleton() {
  if (outlineSettings.pauseAfterSkeleton) {
    showCheckpoint('skeleton');
    return;
  }
  await generateEvents(coarseActs.value);
  await runAfterEvents();
}

async function runAfterEvents() {
  if (outlineSettings.pauseAfterEvents) {
    showCheckpoint('events');
    return;
  }
  await generateMinor(currentActs.value);
  await runAfterMinor();
}

async function runAfterMinor() {
  if (outlineSettings.pauseAfterMinor) {
    showCheckpoint('minor');
    return;
  }
  finishGeneration();
}

async function start() {
  if (running.value) return;
  if (!form.value.genre.trim()) {
    ElMessage.warning('先填一个题材');
    return;
  }
  resetState();
  running.value = true;
  controller = new AbortController();
  try {
    await generateConcept();
    if (!ensureNotAborted()) return;
    await generateSkeleton();
    if (!ensureNotAborted()) return;
    await runAfterSkeleton();
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

async function continueCheckpoint() {
  if (!checkpoint.value || running.value) return;
  const kind = checkpoint.value;
  checkpoint.value = null;
  running.value = true;
  controller = new AbortController();
  try {
    if (kind === 'skeleton') {
      const acts = parseCheckpointActs();
      coarseActs.value = acts;
      currentActs.value = acts;
      await generateEvents(acts);
      if (ensureNotAborted()) await runAfterEvents();
    } else if (kind === 'events') {
      const acts = parseCheckpointActs();
      currentActs.value = acts;
      await generateMinor(acts);
      if (ensureNotAborted()) await runAfterMinor();
    } else {
      finalText.value = checkpointText.value;
      finishGeneration();
    }
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

async function regenerateCheckpoint() {
  if (!checkpoint.value || running.value) return;
  const kind = checkpoint.value;
  checkpoint.value = null;
  running.value = true;
  controller = new AbortController();
  try {
    if (kind === 'skeleton') {
      await generateSkeleton();
      if (ensureNotAborted()) await runAfterSkeleton();
    } else if (kind === 'events') {
      await generateEvents(coarseActs.value);
      if (ensureNotAborted()) await runAfterEvents();
    } else {
      await generateMinor(currentActs.value);
      if (ensureNotAborted()) await runAfterMinor();
    }
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

function backCheckpoint() {
  if (running.value) return;
  if (checkpoint.value === 'events') {
    checkpoint.value = 'skeleton';
    currentActs.value = coarseActs.value;
    checkpointText.value = skeletonResult.value?.coarseText || renderActs(coarseActs.value);
    phase.value = 'skeleton';
  } else if (checkpoint.value === 'minor') {
    checkpoint.value = 'events';
    currentActs.value = eventsResult.value?.acts || currentActs.value;
    checkpointText.value = eventsResult.value?.eventsText || renderActs(currentActs.value);
    phase.value = 'events';
  }
}

function stop() {
  controller?.abort();
  running.value = false;
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
      desc="分阶段生成：书名与概念 → 粗骨架 → 大事件 → 小事件，每个阶段可检查、编辑后再继续。"
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

        <div class="checkpoint-tip">
          <span class="tip-dot" />
          生成会在粗骨架、大事件、小事件三个检查点暂停，是否暂停可在「AI 设置」里调整。
        </div>

        <div class="run-row">
          <el-button v-if="!running" type="primary" :icon="MagicStick" @click="start">
            {{ result ? '重新生成' : '开始生成' }}
          </el-button>
          <el-button v-else type="danger" plain :icon="VideoPause" @click="stop">停止</el-button>
          <span class="hint">分阶段生成，可随时按检查点审阅</span>
        </div>
      </section>

      <section class="card">
        <div class="stage-head">
          <h3 class="block-title">生成流程</h3>
          <span class="stage-phase">{{ phaseLabel }}</span>
        </div>

        <div v-if="phase === 'idle' && !result && !checkpoint" class="empty-hint">
          左边填好设定，点「开始生成」。生成会先做粗骨架，再精写大事件，最后展开小事件。
        </div>

        <template v-else>
          <div class="stage-row">
            <span class="stage-index">{{ stage.index || 1 }}/{{ stage.total || 4 }}</span>
            <span class="stage-label">{{ stage.label || '正在准备…' }}</span>
          </div>

          <div class="step-track">
            <span class="step on">定调</span>
            <span class="step" :class="{ on: phase !== 'concept' }">粗骨架</span>
            <span class="step" :class="{ on: phase === 'events' || phase === 'minor' || phase === 'done' }">大事件</span>
            <span class="step" :class="{ on: phase === 'minor' || phase === 'done' }">小事件</span>
          </div>

          <div v-if="running" class="gen-log">{{ log }}</div>

          <div v-if="conceptResult && !result" class="concept-preview">
            <div class="concept-title">《{{ conceptResult.title }}》</div>
            <p>{{ conceptResult.concept }}</p>
          </div>

          <div v-if="checkpoint" class="checkpoint-card">
            <div class="checkpoint-head">
              <div>
                <div class="checkpoint-title">{{ checkpointLabel }}</div>
                <p>{{ checkpointDesc }}</p>
              </div>
              <span class="checkpoint-badge">待确认</span>
            </div>
            <el-input
              v-model="checkpointText"
              type="textarea"
              :rows="10"
              resize="vertical"
              class="checkpoint-editor"
              placeholder="编辑当前阶段内容…"
            />
            <div class="checkpoint-actions">
              <el-button v-if="checkpoint === 'events'" text @click="backCheckpoint">返回粗骨</el-button>
              <el-button v-if="checkpoint === 'minor'" text @click="backCheckpoint">返回大事件</el-button>
              <el-button @click="regenerateCheckpoint">重新生成当前阶段</el-button>
              <el-button type="primary" :disabled="!canContinue" @click="continueCheckpoint">
                {{ checkpoint === 'minor' ? '完成生成' : '继续下一步' }}
              </el-button>
            </div>
          </div>

          <div v-if="result" class="result-box">
            <div class="result-title">《{{ result.title }}》</div>
            <div class="result-meta">
              {{ result.majorCount }} 个大事件 ·
              {{ result.chapters.filter((item) => item.type === 'minor').length }} 个小事件
            </div>
            <p class="result-desc">{{ result.concept }}</p>
            <pre class="result-outline">{{ result.outlineText }}</pre>
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

.stage-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.stage-head .block-title { margin-bottom: 14px; }
.stage-phase { font-size: 12px; color: var(--ink-3); white-space: nowrap; }

.count-row {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 14px;
}

.full { width: 100%; }

.run-row { display: flex; align-items: center; gap: 12px; margin-top: 8px; flex-wrap: wrap; }
.hint { font-size: 12px; color: var(--ink-4); }

.checkpoint-tip {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 16px;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg-soft);
  color: var(--ink-3);
  font-size: 11.5px;
  line-height: 1.6;
}
.tip-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--warn); flex: 0 0 6px; }

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

.step-track {
  display: flex;
  gap: 6px;
  margin-top: 14px;
  padding-bottom: 14px;
  border-bottom: 1px solid var(--line);
}
.step {
  flex: 1;
  padding: 6px 8px;
  border-radius: 5px;
  background: var(--bg-soft);
  color: var(--ink-3);
  text-align: center;
  font-size: 11px;
  letter-spacing: 0.3px;
}
.step.on { background: var(--brand-soft); color: var(--ink-1); font-weight: 600; }

.gen-log {
  max-height: 200px;
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

.concept-preview {
  margin-top: 14px;
  padding: 12px 14px;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--bg-soft);
}
.concept-title { font-size: 16px; font-weight: 650; color: var(--ink-1); }
.concept-preview p { margin: 5px 0 0; color: var(--ink-2); font-size: 12.5px; line-height: 1.75; }

.checkpoint-card {
  margin-top: 16px;
  padding: 16px;
  border: 1px solid var(--line-strong);
  border-radius: var(--r-md);
  background: var(--bg-card);
  box-shadow: var(--shadow-card);
}
.checkpoint-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.checkpoint-title { font-size: 14px; font-weight: 650; color: var(--ink-1); }
.checkpoint-head p { margin: 5px 0 0; font-size: 12px; line-height: 1.7; color: var(--ink-3); }
.checkpoint-badge {
  padding: 2px 7px;
  border: 1px solid var(--warn);
  border-radius: 4px;
  color: var(--warn);
  font-size: 10.5px;
  white-space: nowrap;
}
.checkpoint-editor { width: 100%; }
.checkpoint-editor :deep(.el-textarea__inner) {
  font-family: 'Source Han Serif SC', 'Songti SC', serif;
  font-size: 13px;
  line-height: 1.8;
  color: var(--ink-1);
  max-height: 38vh;
  overflow: auto;
}
.checkpoint-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; margin-top: 12px; flex-wrap: wrap; }

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
  max-height: 360px;
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
