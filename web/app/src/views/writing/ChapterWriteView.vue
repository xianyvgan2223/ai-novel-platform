<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage, ElMessageBox } from 'element-plus';
import {
  ArrowLeft, ArrowRight, Check, CopyDocument, Document, MagicStick, Refresh, Setting, VideoPause,
} from '@element-plus/icons-vue';
import { api } from '@/api';
import type { ChapterGeneratePayload, Row, WritingAction, WritingStrength, WritingStyle } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { ACTION_ITEMS, STRENGTH_OPTIONS, STYLE_OPTIONS, toggleAction } from './options';
import { isMinor, loadChapters, loadOutline, saveChapterContent } from './novelApi';
import { chapterRequestSettings, chapterSettings, loadAiSettings } from './novelSettings';

const props = defineProps<{ id: string }>();
const router = useRouter();

const chapter = ref<Row | null>(null);
const outline = ref<Row | null>(null);
const siblings = ref<Row[]>([]);
const loading = ref(false);
const saving = ref(false);

const backTo = computed(() => `/writing/outline/${outline.value?.id ?? ''}/chapters`);

const draft = ref('');
const saved = ref('');
const dirty = computed(() => draft.value !== saved.value);

const chapterMinWords = ref(2000);
const chapterMaxWords = ref(3000);
const chapterExtra = ref('');
const settingsVisible = ref(false);
const undoSnapshot = ref<string | null>(null);
const continueInstruction = ref('');
const stateVisible = ref(false);
const stateDraft = ref('');
const savingState = ref(false);

const aiActions = ref<WritingAction[]>(['polish', 'deai']);
const aiStyle = ref<WritingStyle>('original');
const aiStrength = ref<WritingStrength>('medium');
const aiExtra = ref('');
const aiResult = ref('');
const aiRunning = ref(false);
const aiElapsed = ref<number | null>(null);
const aiKind = ref<'optimize' | 'chapter'>('chapter');
let controller: AbortController | null = null;

const structureOnly = computed(() => aiActions.value.length === 1 && aiActions.value[0] === 'structure');
const continueOnly = computed(() => aiActions.value.length === 1 && aiActions.value[0] === 'continue');

const siblingsMinor = computed(() => siblings.value.filter((row) => isMinor(row)));
const currentIndex = computed(
  () => siblingsMinor.value.findIndex((row) => Number(row.id) === Number(props.id)),
);
const prevChapter = computed(
  () => (currentIndex.value > 0 ? siblingsMinor.value[currentIndex.value - 1] : null),
);
const nextChapter = computed(
  () => (currentIndex.value >= 0 && currentIndex.value < siblingsMinor.value.length - 1
    ? siblingsMinor.value[currentIndex.value + 1]
    : null),
);

async function load() {
  loading.value = true;
  try {
    const row = await api.getRow('deepseek', 'outline_chapters', Number(props.id));
    chapter.value = row;
    draft.value = String(row.content ?? '');
    saved.value = draft.value;
    const work = await loadOutline(Number(row.outline_id));
    outline.value = work;
    siblings.value = await loadChapters(Number(row.outline_id));
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

async function save() {
  if (!chapter.value || !dirty.value || saving.value) return;
  saving.value = true;
  try {
    await saveChapterContent(Number(chapter.value.id), draft.value);
    chapter.value.content = draft.value;
    chapter.value.status = 'completed';
    saved.value = draft.value;
    ElMessage.success('已保存到服务器');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function buildPayload(): Promise<ChapterGeneratePayload | null> {
  const work = outline.value;
  const row = chapter.value;
  if (!work || !row) return null;

  let prevContent = '';
  if (prevChapter.value) {
    try {
      const full = await api.getRow('deepseek', 'outline_chapters', Number(prevChapter.value.id));
      prevContent = String(full.ai_summary ?? '').trim() || String(full.content ?? '');
    } catch {
      prevContent = String(prevChapter.value.content ?? '');
    }
  }

  return {
    title: String(work.title ?? ''),
    genre: String(work.genre ?? ''),
    theme: String(work.theme ?? ''),
    protagonist: String(work.protagonist ?? ''),
    worldview: String(work.worldview ?? ''),
    outlineContent: String(work.content ?? ''),
    chapterTitle: String(row.event_title ?? ''),
    chapterSummary: String(row.event_summary ?? ''),
    prevChapterTitle: prevChapter.value ? String(prevChapter.value.event_title ?? '') : undefined,
    prevChapterContent: prevContent ? prevContent.slice(-1200) : undefined,
    nextChapterTitle: nextChapter.value ? String(nextChapter.value.event_title ?? '') : undefined,
    characters: String(work.characters ?? '') || undefined,
    foreshadows: String(work.foreshadows ?? '') || undefined,
    storyState: String(work.story_state ?? '') || undefined,
    minWords: chapterMinWords.value,
    maxWords: chapterMaxWords.value,
    extra: chapterExtra.value.trim() || undefined,
    settings: chapterRequestSettings(),
  };
}

async function generateChapter() {
  if (aiRunning.value) return;
  const payload = await buildPayload();
  if (!payload) return;
  if (!String(payload.chapterSummary ?? '').trim()) {
    ElMessage.warning('这一篇还没有概要，先回大纲编辑补一句概要');
    return;
  }

  aiKind.value = 'chapter';
  aiResult.value = '';
  aiElapsed.value = null;
  aiRunning.value = true;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.novel.generateChapter(
      payload,
      {
        onDelta: (delta) => { aiResult.value += delta; },
        onDone: (info) => { aiElapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    aiRunning.value = false;
    controller = null;
  }
}

async function runOptimize() {
  if (aiRunning.value) return;
  if (!draft.value.trim()) {
    ElMessage.warning('先把正文写出来，或先生成正文');
    return;
  }
  if (!aiActions.value.length) {
    ElMessage.warning('至少选择一个优化动作');
    return;
  }

  aiKind.value = 'optimize';
  aiResult.value = '';
  aiElapsed.value = null;
  aiRunning.value = true;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.optimize(
      {
        text: draft.value,
        actions: aiActions.value,
        style: aiStyle.value,
        strength: aiStrength.value,
        extra: aiExtra.value.trim() || undefined,
      },
      {
        onDelta: (delta) => { aiResult.value += delta; },
        onDone: (info) => { aiElapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    aiRunning.value = false;
    controller = null;
  }
}

function stopAi() {
  controller?.abort();
}

function applyAi() {
  if (!aiResult.value) return;
  if (aiKind.value === 'chapter') {
    undoSnapshot.value = draft.value;
    draft.value = aiResult.value;
    ElMessage.success('已写入正文，记得点「保存」');
    return;
  }
  if (structureOnly.value) return;
  undoSnapshot.value = draft.value;
  draft.value = continueOnly.value
    ? draft.value.trimEnd() + '\n\n' + aiResult.value
    : aiResult.value;
  ElMessage.success('已写入正文，记得点「保存」');
}

function undoDraft() {
  if (undoSnapshot.value === null) return;
  draft.value = undoSnapshot.value;
  undoSnapshot.value = null;
  ElMessage.success('已撤回上一次替换');
}

/** 对当前 AI 结果继续提要求（走逐段优化接口） */
async function continueModify() {
  if (aiRunning.value || !aiResult.value) return;
  const instruction = continueInstruction.value.trim();
  if (!instruction) {
    ElMessage.warning('先写一句对结果的要求');
    return;
  }
  const base = aiResult.value;
  aiResult.value = '';
  aiKind.value = 'optimize';
  aiRunning.value = true;
  aiElapsed.value = null;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.optimize(
      {
        text: base,
        actions: ['polish'],
        style: aiStyle.value,
        strength: aiStrength.value,
        extra: instruction,
      },
      {
        onDelta: (delta) => { aiResult.value += delta; },
        onDone: (info) => { aiElapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
    continueInstruction.value = '';
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    aiRunning.value = false;
    controller = null;
  }
}

function toggle(key: WritingAction) {
  aiActions.value = toggleAction(aiActions.value, key);
}

/** 剧情状态账本：与手机端同一份 outline_records.story_state */
function openState() {
  stateDraft.value = String(outline.value?.story_state ?? '');
  stateVisible.value = true;
}

async function saveState() {
  const row = outline.value;
  if (!row || savingState.value) return;
  savingState.value = true;
  try {
    await api.updateRow('deepseek', 'outline_records', Number(row.id), {
      story_state: stateDraft.value,
    });
    row.story_state = stateDraft.value;
    ElMessage.success('剧情账本已保存');
    stateVisible.value = false;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    savingState.value = false;
  }
}

async function copy(text: string) {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    ElMessage.success('已复制');
  } catch {
    ElMessage.warning('浏览器没有允许复制');
  }
}

async function go(target: Row | null) {
  if (!target) return;
  if (dirty.value) {
    try {
      await ElMessageBox.confirm('当前修改还没保存，切换后会丢失。', '未保存', {
        confirmButtonText: '仍然切换',
        cancelButtonText: '返回保存',
        type: 'warning',
      });
    } catch {
      return;
    }
  }
  router.push('/writing/chapter/' + target.id);
}

onMounted(async () => {
  await loadAiSettings();
  chapterMinWords.value = chapterSettings.chapterMinWords;
  chapterMaxWords.value = chapterSettings.chapterMaxWords;
  await load();
});
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(chapter?.event_title || '小事件写作')"
      :desc="`${String(outline?.title || '')} · ${dirty ? '有未保存修改' : '内容与服务器一致'}`"
      :back="backTo"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
        <el-button :icon="Document" @click="openState">剧情账本</el-button>
        <el-button :icon="ArrowLeft" :disabled="!prevChapter" @click="go(prevChapter)">上一个小事件</el-button>
        <el-button :icon="ArrowRight" :disabled="!nextChapter" @click="go(nextChapter)">下一个小事件</el-button>
        <el-button type="primary" :icon="Check" :disabled="!dirty" :loading="saving" @click="save">保存</el-button>
      </template>
    </PageHeader>

    <section class="card card-flush">
      <div class="card-head">
        <h3>正文</h3>
        <span class="mono text-muted">{{ draft.length }} 字</span>
      </div>
      <div class="editor-body">
        <el-input
          v-model="draft"
          type="textarea"
          :rows="20"
          resize="vertical"
          class="novel-textarea"
          placeholder="在这里写本篇正文…"
        />
      </div>
      <div class="ai-tools">
        <div class="gen-row">
          <el-button type="primary" :icon="MagicStick" :disabled="aiRunning" @click="generateChapter">
            生成本篇正文
          </el-button>
          <span class="gen-label">目标字数</span>
          <el-input-number v-model="chapterMinWords" :min="300" :max="20000" :step="500" size="small" controls-position="right" class="num-input" />
          <span class="gen-label">~</span>
          <el-input-number v-model="chapterMaxWords" :min="300" :max="30000" :step="500" size="small" controls-position="right" class="num-input" />
          <el-input v-model="chapterExtra" size="small" placeholder="额外要求（可选）" class="gen-extra" />
        </div>

        <el-divider class="divider" />

        <div class="field-label">逐段优化</div>
        <div class="chips">
          <button
            v-for="item in ACTION_ITEMS"
            :key="item.key"
            type="button"
            class="chip"
            :class="{ on: aiActions.includes(item.key) }"
            @click="toggle(item.key)"
          >
            {{ item.label }}
          </button>
        </div>
        <div class="chips">
          <button
            v-for="item in STYLE_OPTIONS"
            :key="item.key"
            type="button"
            class="chip chip-sm"
            :class="{ on: aiStyle === item.key }"
            @click="aiStyle = item.key"
          >
            {{ item.label }}
          </button>
        </div>
        <div class="chips">
          <button
            v-for="item in STRENGTH_OPTIONS"
            :key="item.key"
            type="button"
            class="chip chip-sm"
            :class="{ on: aiStrength === item.key }"
            @click="aiStrength = item.key"
          >
            {{ item.label }}
          </button>
        </div>
        <el-input v-model="aiExtra" placeholder="额外要求（可选），例如：保留人物对话，只改叙述" class="extra-input" />
        <div class="run-row">
          <el-button v-if="!aiRunning" type="primary" plain :icon="MagicStick" @click="runOptimize">
            优化当前内容
          </el-button>
          <el-button v-else type="danger" plain :icon="VideoPause" @click="stopAi">停止</el-button>
          <span class="hint">AI 结果只出现在下方，确认后再替换</span>
        </div>
      </div>
    </section>

    <section v-if="aiResult || aiRunning" class="card card-flush ai-panel">
      <div class="card-head">
        <h3>{{ aiKind === 'chapter' ? 'AI 生成的小事件正文' : 'AI 优化结果' }}</h3>
        <span class="result-meta">
          {{ aiRunning ? '生成中…' : `${aiResult.length} 字` }}
          <template v-if="!aiRunning && aiElapsed"> · {{ (aiElapsed / 1000).toFixed(1) }}s</template>
        </span>
      </div>
      <div class="ai-result-body">
        <div class="ai-result-text">{{ aiResult }}<span v-if="aiRunning" class="caret" /></div>
        <div class="ai-continue">
          <el-input v-model="continueInstruction" size="small" placeholder="对结果继续提要求，例如：再紧凑一点、保留人物对话" />
          <el-button size="small" :disabled="aiRunning || !aiResult" @click="continueModify">继续修改</el-button>
        </div>
      </div>
      <div class="card-foot">
        <div class="row-gap">
          <el-button :icon="CopyDocument" @click="copy(aiResult)">复制</el-button>
          <el-button v-if="aiKind !== 'optimize' || !structureOnly" @click="applyAi">
            {{ aiKind === 'chapter' ? '替换正文' : continueOnly ? '追加到正文' : '替换正文' }}
          </el-button>
          <el-button v-if="undoSnapshot !== null" text @click="undoDraft">撤回</el-button>
        </div>
        <el-button text :icon="Refresh" :disabled="aiRunning" @click="aiKind === 'chapter' ? generateChapter() : runOptimize()">
          重新生成
        </el-button>
      </div>
    </section>

    <el-drawer v-model="stateVisible" title="剧情状态账本" size="480px">
      <div class="state-body">
        <div class="hint block">
          记录角色状态、伏笔与悬念，生成后续小事件时会作为【全局剧情状态】注入，让前后小事件接得上。
        </div>
        <el-input
          v-model="stateDraft"
          type="textarea"
          :rows="20"
          resize="vertical"
          placeholder="例如：&#10;林川：已入山门三年，剑骨初醒；&#10;伏笔：父亲临死前提到的黑玉令牌尚未交代；&#10;悬念：血刀客背后的主使身份未知。"
        />
      </div>
      <template #footer>
        <el-button @click="stateVisible = false">取消</el-button>
        <el-button type="primary" :loading="savingState" @click="saveState">保存</el-button>
      </template>
    </el-drawer>

    <AiSettingsDrawer v-model="settingsVisible" kind="chapter" />
  </div>
</template>

<style scoped>
.editor-body { padding: 18px 20px 8px; }

.novel-textarea :deep(.el-textarea__inner) {
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 15px;
  line-height: 1.95;
  padding: 14px 16px;
  background: var(--bg-soft);
  box-shadow: 0 0 0 1px var(--line) inset;
}

.ai-tools { padding: 14px 20px 18px; border-top: 1px solid var(--line); }

.gen-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.gen-label { font-size: 11.5px; color: var(--ink-4); }
.num-input { width: 96px; }
.gen-extra { flex: 1; min-width: 180px; }

.divider { margin: 14px 0; }

.field-label { margin: 0 0 8px; font-size: 12px; font-weight: 600; color: var(--ink-3); }

.chips { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 10px; }

.chip {
  padding: 6px 13px;
  border-radius: 999px;
  border: 1px solid var(--line-strong);
  background: #fff;
  font-size: 12.5px;
  color: var(--ink-2);
  cursor: pointer;
}

.chip.on {
  border-color: #c9d2ff;
  background: var(--brand-soft);
  color: var(--brand);
  font-weight: 600;
}

.chip-sm { padding: 5px 11px; font-size: 12px; }
.extra-input { margin-bottom: 12px; }
.run-row { display: flex; align-items: center; gap: 14px; }
.hint { font-size: 11.5px; color: var(--ink-4); }

.ai-panel { margin-top: 18px; }
.result-meta { font-size: 12px; color: var(--ink-3); }
.ai-result-body { padding: 18px 20px; }

.ai-result-text {
  white-space: pre-wrap;
  word-break: break-word;
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 15px;
  line-height: 1.95;
  color: var(--ink-1);
}

.ai-continue { display: flex; gap: 8px; margin-top: 12px; }

.caret {
  display: inline-block;
  width: 7px;
  height: 16px;
  margin-left: 2px;
  vertical-align: -2px;
  background: var(--brand);
  animation: blink 1s steps(2, start) infinite;
}

@keyframes blink { to { opacity: 0; } }

.row-gap { display: flex; align-items: center; gap: 8px; }

.state-body { display: flex; flex-direction: column; gap: 10px; }
.hint.block { display: block; margin: 0; font-size: 11.5px; color: var(--ink-4); line-height: 1.6; }
</style>
