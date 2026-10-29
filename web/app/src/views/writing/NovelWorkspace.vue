<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import {
  Check, CopyDocument, MagicStick, Notebook, Refresh, VideoPause,
} from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row, WritingAction, WritingStrength, WritingStyle } from '@/api';
import { deviceEpoch } from '@/stores/device';
import {
  ACTION_ITEMS, STRENGTH_OPTIONS, STYLE_OPTIONS, toggleAction,
} from './options';

const novels = ref<Row[]>([]);
const chapters = ref<Row[]>([]);
const novelId = ref<number | null>(null);
const chapterId = ref<number | null>(null);
const sourceTab = ref<'chapter' | 'outline'>('chapter');
const loadingNovels = ref(false);
const loadingChapters = ref(false);
const loadingDraft = ref(false);
const saving = ref(false);

const draft = ref('');
const saved = ref('');

const aiActions = ref<WritingAction[]>(['polish', 'deai']);
const aiStyle = ref<WritingStyle>('original');
const aiStrength = ref<WritingStrength>('medium');
const aiExtra = ref('');
const aiResult = ref('');
const aiRunning = ref(false);
const aiElapsed = ref<number | null>(null);
let controller: AbortController | null = null;

const novel = computed(() => novels.value.find((item) => Number(item.id) === novelId.value) ?? null);
const chapter = computed(() => chapters.value.find((item) => Number(item.id) === chapterId.value) ?? null);
const noNovels = computed(() => !loadingNovels.value && novels.value.length === 0);
const canEdit = computed(() => (sourceTab.value === 'outline' ? !!novel.value : !!chapter.value));
const dirty = computed(() => draft.value !== saved.value);
const draftChars = computed(() => draft.value.length);
const aiChars = computed(() => aiResult.value.length);
const structureOnly = computed(() => aiActions.value.length === 1 && aiActions.value[0] === 'structure');
const continueOnly = computed(() => aiActions.value.length === 1 && aiActions.value[0] === 'continue');

const headTitle = computed(() => {
  if (sourceTab.value === 'outline') return novel.value ? String(novel.value.title || '未命名作品') + ' · 大纲' : '未选择作品';
  return chapter.value ? String(chapter.value.event_title || '未命名章节') : '未选择章节';
});

function statusLabel(raw: unknown): string {
  const value = String(raw ?? '');
  if (value === 'completed') return '已写';
  if (value === 'generating') return '生成中';
  return '待写';
}

function statusTone(raw: unknown): string {
  const value = String(raw ?? '');
  if (value === 'completed') return 'ok';
  if (value === 'generating') return 'busy';
  return 'idle';
}

/** 有未保存修改时先确认，避免一键切换把改动丢掉 */
async function confirmDiscard(): Promise<boolean> {
  if (!dirty.value) return true;
  try {
    await ElMessageBox.confirm(
      '当前内容还没保存，切换后会丢失。',
      '未保存的修改',
      { type: 'warning', confirmButtonText: '仍然切换', cancelButtonText: '返回保存' },
    );
    return true;
  } catch {
    return false;
  }
}

async function loadNovels() {
  loadingNovels.value = true;
  try {
    const res = await api.listRows('deepseek', 'outline_records', { page: 1, pageSize: 200 });
    novels.value = res.data;
    if (!novels.value.length) {
      novelId.value = null;
      chapters.value = [];
      chapterId.value = null;
      draft.value = '';
      saved.value = '';
      return;
    }
    novelId.value = Number(novels.value[0].id);
    await loadChapters(novelId.value, true);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingNovels.value = false;
  }
}

async function loadChapters(id: number, pickFirst = true) {
  loadingChapters.value = true;
  try {
    const res = await api.listRows('deepseek', 'outline_chapters', {
      outline_id: id,
      page: 1,
      pageSize: 500,
      orderBy: 'event_index',
      dir: 'asc',
    });
    chapters.value = res.data;
    if (pickFirst) {
      if (chapters.value.length) {
        await openChapter(chapters.value[0]);
      } else {
        chapterId.value = null;
        draft.value = '';
        saved.value = '';
      }
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingChapters.value = false;
  }
}

async function openChapter(row: Row) {
  chapterId.value = Number(row.id);
  aiResult.value = '';
  aiElapsed.value = null;
  loadingDraft.value = true;
  try {
    // 列表里是截断文本，正文单独取一次完整内容
    const full = await api.getRow('deepseek', 'outline_chapters', Number(row.id));
    Object.assign(row, full);
    draft.value = String(full.content ?? '');
    saved.value = draft.value;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingDraft.value = false;
  }
}

async function loadOutlineDraft() {
  const current = novel.value;
  if (!current) return;
  aiResult.value = '';
  aiElapsed.value = null;
  loadingDraft.value = true;
  try {
    const full = await api.getRow('deepseek', 'outline_records', Number(current.id));
    Object.assign(current, full);
    draft.value = String(full.content ?? '');
    saved.value = draft.value;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingDraft.value = false;
  }
}

async function onNovelChange(value: number) {
  if (!(await confirmDiscard())) return;
  novelId.value = Number(value);
  chapterId.value = null;
  draft.value = '';
  saved.value = '';
  await loadChapters(novelId.value, sourceTab.value === 'chapter');
  if (sourceTab.value === 'outline') await loadOutlineDraft();
}

async function switchSource(tab: 'chapter' | 'outline') {
  if (tab === sourceTab.value) return;
  if (!(await confirmDiscard())) return;
  sourceTab.value = tab;
  if (tab === 'outline') {
    await loadOutlineDraft();
  } else if (chapter.value) {
    await openChapter(chapter.value);
  } else if (chapters.value.length) {
    await openChapter(chapters.value[0]);
  } else {
    draft.value = '';
    saved.value = '';
  }
}

async function pickChapter(row: Row) {
  if (Number(row.id) === chapterId.value && sourceTab.value === 'chapter') return;
  if (!(await confirmDiscard())) return;
  if (sourceTab.value === 'outline') sourceTab.value = 'chapter';
  await openChapter(row);
}

async function reloadCurrent() {
  if (!(await confirmDiscard())) return;
  if (sourceTab.value === 'outline') {
    await loadOutlineDraft();
  } else if (chapter.value) {
    await openChapter(chapter.value);
  }
}

async function save() {
  if (!dirty.value || !canEdit.value) return;
  saving.value = true;
  try {
    if (sourceTab.value === 'chapter') {
      const row = chapter.value!;
      const now = new Date().toISOString();
      await api.updateRow('deepseek', 'outline_chapters', Number(row.id), {
        content: draft.value,
        updated_at: now,
      });
      row.content = draft.value;
      row.updated_at = now;
    } else {
      const current = novel.value!;
      await api.updateRow('deepseek', 'outline_records', Number(current.id), {
        content: draft.value,
      });
      current.content = draft.value;
    }
    saved.value = draft.value;
    ElMessage.success('已保存到服务器，手机下次同步会拉取这次修改');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

function toggle(key: WritingAction) {
  aiActions.value = toggleAction(aiActions.value, key);
}

async function runAi() {
  if (aiRunning.value || !canEdit.value) return;
  if (!draft.value.trim()) {
    ElMessage.warning('先把正文写出来，或从左侧载入一章');
    return;
  }
  if (!aiActions.value.length) {
    ElMessage.warning('至少选择一个 AI 动作');
    return;
  }

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
        onDelta: (delta) => {
          aiResult.value += delta;
        },
        onDone: (info) => {
          aiElapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt);
        },
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

function applyAiResult() {
  if (!aiResult.value || structureOnly.value) return;
  draft.value = continueOnly.value
    ? draft.value.trimEnd() + '\n\n' + aiResult.value
    : aiResult.value;
  ElMessage.success('已写入编辑器，记得点「保存」写回库');
}

async function copy(text: string, label = '已复制到剪贴板') {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    ElMessage.success(label);
  } catch {
    ElMessage.warning('浏览器没有允许复制，请手动选中文本');
  }
}

async function bootstrap() {
  if (!(await confirmDiscard())) return;
  await loadNovels();
}

watch(deviceEpoch, () => {
  void bootstrap();
});

onMounted(() => {
  void bootstrap();
});
</script>

<template>
  <div class="novel-workspace">
    <div v-if="noNovels" class="card empty-workspace">
      <el-icon class="empty-icon"><Notebook /></el-icon>
      <div class="empty-title">当前设备还没有作品</div>
      <div class="empty-desc">
        先在手机 App 里写小说（大纲 / 章节），同步一次后就会出现在这里；
        也可以点网页右上角「同步手机」让 App 推一份上来。
        如果数据在另一台手机，先在上方「当前设备」里切过去。
      </div>
    </div>

    <div v-else class="novel-grid">
      <aside class="card card-flush novel-side" v-loading="loadingNovels">
        <div class="side-head">
          <el-select
            :model-value="novelId ?? ''"
            :loading="loadingNovels"
            filterable
            placeholder="选择作品"
            class="novel-select"
            @change="onNovelChange"
          >
            <el-option
              v-for="item in novels"
              :key="String(item.id)"
              :label="String(item.title || '未命名作品')"
              :value="Number(item.id)"
            >
              <span>{{ item.title || '未命名作品' }}</span>
              <span class="option-meta">{{ item.genre || '' }}</span>
            </el-option>
          </el-select>

          <div class="source-tabs">
            <button type="button" :class="{ on: sourceTab === 'chapter' }" @click="switchSource('chapter')">
              章节<span class="tab-count">{{ chapters.length }}</span>
            </button>
            <button type="button" :class="{ on: sourceTab === 'outline' }" @click="switchSource('outline')">
              大纲
            </button>
          </div>
        </div>

        <div class="side-body">
          <template v-if="sourceTab === 'chapter'">
            <div v-if="loadingChapters" class="side-empty">正在加载章节…</div>
            <div v-else-if="!chapters.length" class="side-empty">
              这部作品还没有章节。<br />
              可以在手机上先生成大纲，再回来接着写。
            </div>
            <button
              v-for="(item, index) in chapters"
              :key="String(item.id)"
              type="button"
              class="chapter-item"
              :class="{ on: Number(item.id) === chapterId }"
              @click="pickChapter(item)"
            >
              <span class="ci-index">{{ index + 1 }}</span>
              <span class="ci-main">
                <span class="ci-title">{{ item.event_title || '未命名章节' }}</span>
                <span class="ci-meta">{{ statusLabel(item.status) }}</span>
              </span>
              <span class="ci-dot" :class="statusTone(item.status)" />
            </button>
          </template>

          <div v-else class="outline-summary">
            <div class="os-row"><span>书名</span><b>{{ novel?.title || '-' }}</b></div>
            <div class="os-row"><span>类型</span><b>{{ novel?.genre || '-' }}</b></div>
            <div class="os-row"><span>主题</span><b>{{ novel?.theme || '-' }}</b></div>
            <div class="os-row"><span>主角</span><b>{{ novel?.protagonist || '-' }}</b></div>
            <div class="os-row"><span>世界观</span><b>{{ novel?.worldview || '-' }}</b></div>
            <p class="os-tip">右侧编辑的是这部作品的大纲正文，保存后写回服务器。</p>
          </div>
        </div>
      </aside>

      <section class="card card-flush novel-main">
        <div class="card-head">
          <div class="editor-head">
            <h3>{{ headTitle }}</h3>
            <span v-if="dirty" class="dirty-tag">未保存</span>
          </div>
          <div class="row-gap">
            <span class="mono text-muted">{{ draftChars }} 字</span>
            <el-button text :icon="Refresh" :disabled="!canEdit || aiRunning" @click="reloadCurrent">
              重新载入
            </el-button>
            <el-button
              type="primary"
              :icon="Check"
              :disabled="!dirty"
              :loading="saving"
              @click="save"
            >
              保存
            </el-button>
          </div>
        </div>

        <div class="editor-body" v-loading="loadingDraft">
          <div v-if="!canEdit" class="empty-hint">从左侧选择要写的章节。</div>
          <el-input
            v-else
            v-model="draft"
            type="textarea"
            :rows="20"
            resize="vertical"
            class="novel-textarea"
            :placeholder="sourceTab === 'outline' ? '在这里写大纲…' : '在这里写本章正文…'"
          />
          <div v-if="dirty" class="save-hint">
            <span>修改还只在浏览器里，保存后才会写回服务器；手机下次同步即可拉取。</span>
            <el-button size="small" type="primary" :loading="saving" @click="save">立即保存</el-button>
          </div>
        </div>

        <div class="ai-tools">
          <div class="field-label">
            AI 助手
            <span class="scope">作用范围：{{ sourceTab === 'outline' ? '整篇大纲' : '整章正文' }}</span>
          </div>
          <div class="chips">
            <button
              v-for="item in ACTION_ITEMS"
              :key="item.key"
              type="button"
              class="chip"
              :class="{ on: aiActions.includes(item.key) }"
              :title="item.hint"
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
            <el-button
              v-if="!aiRunning"
              type="primary"
              :icon="MagicStick"
              :disabled="!canEdit"
              @click="runAi"
            >
              开始优化
            </el-button>
            <el-button v-else type="danger" plain :icon="VideoPause" @click="stopAi">停止</el-button>
            <span class="hint">AI 只生成到下方结果区，确认后再替换正文</span>
          </div>
        </div>
      </section>
    </div>

    <section v-if="aiResult || aiRunning" class="card card-flush ai-panel">
      <div class="card-head">
        <h3>AI 结果</h3>
        <span class="result-meta">
          <template v-if="aiRunning">生成中…</template>
          <template v-else>
            {{ aiChars }} 字<template v-if="aiElapsed"> · {{ (aiElapsed / 1000).toFixed(1) }}s</template>
          </template>
        </span>
      </div>
      <div class="ai-result-body">
        <div v-if="!aiResult && aiRunning" class="empty-hint">正在生成…</div>
        <div v-else class="ai-result-text">{{ aiResult }}<span v-if="aiRunning" class="caret" /></div>
      </div>
      <div class="card-foot">
        <div class="row-gap">
          <el-button :icon="CopyDocument" @click="copy(aiResult)">复制</el-button>
          <el-button v-if="!structureOnly" @click="applyAiResult">
            {{ continueOnly ? '追加到正文' : '替换正文' }}
          </el-button>
        </div>
        <el-button text :icon="Refresh" :disabled="aiRunning" @click="runAi">重新生成</el-button>
      </div>
    </section>
  </div>
</template>

<style scoped>
.novel-workspace { margin-bottom: 18px; }

.novel-grid {
  display: grid;
  grid-template-columns: 320px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .novel-grid { grid-template-columns: minmax(0, 1fr); }
}

/* ── 左侧作品 / 章节 ── */
.novel-side {
  display: flex;
  flex-direction: column;
  max-height: calc(100vh - 180px);
  position: sticky;
  top: 0;
}

.side-head {
  padding: 14px 14px 12px;
  border-bottom: 1px solid var(--line);
}

.novel-select { width: 100%; }

.option-meta { margin-left: 8px; font-size: 11px; color: var(--ink-3); }

.source-tabs {
  display: flex;
  gap: 4px;
  margin-top: 10px;
  padding: 3px;
  border-radius: 9px;
  background: var(--bg-soft);
}

.source-tabs button {
  flex: 1;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 6px 8px;
  border: none;
  border-radius: 7px;
  background: transparent;
  font-size: 12.5px;
  color: var(--ink-2);
  cursor: pointer;
}

.source-tabs button.on {
  background: #fff;
  color: var(--brand);
  font-weight: 600;
  box-shadow: var(--shadow-1);
}

.tab-count {
  padding: 0 5px;
  border-radius: 5px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 10.5px;
  font-variant-numeric: tabular-nums;
}

.side-body {
  flex: 1;
  overflow: auto;
  padding: 8px;
  min-height: 120px;
}

.side-empty {
  padding: 24px 14px;
  font-size: 12px;
  color: var(--ink-3);
  line-height: 1.8;
  text-align: center;
}

.chapter-item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 9px 10px;
  border: 1px solid transparent;
  border-radius: 9px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}

.chapter-item:hover { background: var(--bg-soft); }
.chapter-item.on { background: var(--brand-soft); border-color: #c9d2ff; }

.ci-index {
  width: 22px;
  height: 22px;
  flex: 0 0 22px;
  display: grid;
  place-items: center;
  border-radius: 7px;
  background: #fff;
  border: 1px solid var(--line-strong);
  color: var(--ink-3);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}

.chapter-item.on .ci-index {
  border-color: #c9d2ff;
  color: var(--brand);
}

.ci-main { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }

.ci-title {
  font-size: 12.8px;
  font-weight: 500;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.ci-meta { font-size: 10.5px; color: var(--ink-4); }

.ci-dot {
  width: 6px;
  height: 6px;
  flex: 0 0 6px;
  border-radius: 50%;
  background: var(--ink-4);
}

.ci-dot.ok { background: var(--ok); }
.ci-dot.busy { background: var(--warn); }
.ci-dot.idle { background: var(--ink-4); }

.outline-summary { padding: 12px 10px; }

.os-row {
  display: flex;
  gap: 10px;
  padding: 6px 0;
  border-bottom: 1px dashed var(--line);
  font-size: 12px;
}

.os-row span { flex: 0 0 48px; color: var(--ink-4); }
.os-row b { flex: 1; font-weight: 500; color: var(--ink-2); word-break: break-word; }

.os-tip {
  margin: 12px 0 0;
  font-size: 11.5px;
  color: var(--ink-4);
  line-height: 1.7;
}

/* ── 右侧编辑器 ── */
.novel-main { display: flex; flex-direction: column; }

.editor-head { display: flex; align-items: center; gap: 10px; min-width: 0; }

.editor-head h3 {
  max-width: 480px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.dirty-tag {
  padding: 2px 7px;
  border-radius: 5px;
  background: var(--warn-soft);
  color: #b45309;
  font-size: 10.5px;
  font-weight: 600;
}

.editor-body { padding: 18px 20px 8px; }

.novel-textarea :deep(.el-textarea__inner) {
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 15px;
  line-height: 1.95;
  padding: 14px 16px;
  background: var(--bg-soft);
  box-shadow: 0 0 0 1px var(--line) inset;
}

.save-hint {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-top: 8px;
  font-size: 11.5px;
  color: #b45309;
}

.ai-tools {
  padding: 14px 20px 18px;
  border-top: 1px solid var(--line);
}

.field-label {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 6px 0 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.3px;
  color: var(--ink-3);
}

.scope { font-weight: 400; font-size: 11px; color: var(--ink-4); letter-spacing: 0; }

.chips { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 10px; }

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

.chip:hover { border-color: #c9d2ff; }

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

/* ── AI 结果 ── */
.ai-panel { margin-top: 18px; }

.result-meta { font-size: 12px; color: var(--ink-3); font-variant-numeric: tabular-nums; }

.ai-result-body { padding: 18px 20px; }

.ai-result-text {
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

/* ── 空状态 ── */
.empty-workspace {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
  min-height: 320px;
  text-align: center;
}

.empty-icon { font-size: 32px; color: var(--ink-4); }
.empty-title { font-size: 15px; font-weight: 600; color: var(--ink-2); }

.empty-desc {
  max-width: 520px;
  font-size: 12.5px;
  line-height: 1.8;
  color: var(--ink-3);
}

.row-gap { display: flex; align-items: center; gap: 8px; }
</style>
