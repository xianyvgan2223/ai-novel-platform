<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import {
  ChatDotRound, Check, CopyDocument, Iphone, MagicStick, Refresh, Setting, VideoPause,
} from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { isMajor, loadChapters, loadOutline } from './novelApi';
import { loadAiSettings, outlineRequestSettings } from './novelSettings';

const props = defineProps<{ id: string }>();

const outline = ref<Row | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);
const tab = ref<'text' | 'structure'>('structure');

const draft = ref('');
const savedText = ref('');
const dirty = computed(() => draft.value !== savedText.value);

const settingsVisible = ref(false);
const saving = ref(false);

/* ── 大纲正文的 AI 改写 ── */
const undoSnapshot = ref<string | null>(null);
const continueInstruction = ref('');
const aiInstruction = ref('');
const aiResult = ref('');
const aiRunning = ref(false);
const aiElapsed = ref<number | null>(null);
let controller: AbortController | null = null;

const textAreaRef = ref<HTMLTextAreaElement | null>(null);
const selectionRange = ref<{ start: number; end: number } | null>(null);

const outlineId = computed(() => Number(props.id));
const minorCount = computed(
  () => chapters.value.filter((row) => String(row.event_type) === 'minor').length,
);
/** 旧版网页生成的大纲用「## 幕 / 【大事件】/ 【章节】」，手机端解析不了 */
const legacyFormat = computed(() => /【大事件】|【章节】|^#{1,6}\s*第/m.test(draft.value));

/* ── 章节结构：多选 + 每项独立草稿 ── */
interface AiResult {
  title: string;
  summary: string;
}

interface ChapterDraft {
  id: number;
  row: Row;
  title: string;
  summary: string;
  savedTitle: string;
  savedSummary: string;
  result: AiResult | null;
  undo: { title: string; summary: string } | null;
}

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  streaming?: boolean;
}

const picked = ref<Set<number>>(new Set());
const drafts = ref<ChapterDraft[]>([]);

const allPicked = computed(
  () => chapters.value.length > 0 && picked.value.size === chapters.value.length,
);
const somePicked = computed(
  () => picked.value.size > 0 && picked.value.size < chapters.value.length,
);
const structureDirty = computed(() => drafts.value.some((item) => isDirty(item)));

watch(
  () => chapters.value.filter((row) => picked.value.has(Number(row.id))).map((row) => String(row.id)).join('|'),
  () => syncDrafts(),
);

function createDraft(row: Row): ChapterDraft {
  const title = String(row.event_title ?? '');
  const summary = String(row.event_summary ?? '');
  return {
    id: Number(row.id),
    row,
    title,
    summary,
    savedTitle: title,
    savedSummary: summary,
    result: null,
    undo: null,
  };
}

/** 选中项变化时重建右侧卡片，保留已经输入但未保存的内容 */
function syncDrafts() {
  const rows = chapters.value.filter((row) => picked.value.has(Number(row.id)));
  const previous = new Map(drafts.value.map((item) => [item.id, item]));
  drafts.value = rows.map((row) => previous.get(Number(row.id)) ?? createDraft(row));
}

function isDirty(item: ChapterDraft): boolean {
  return item.title !== item.savedTitle || item.summary !== item.savedSummary;
}

function togglePick(row: Row, checked: boolean) {
  const id = Number(row.id);
  const next = new Set(picked.value);
  if (checked) {
    next.add(id);
  } else {
    next.delete(id);
  }
  picked.value = next;
}

/** 点整行 = 勾选 / 取消勾选，和手机端多选一致 */
function toggleRow(row: Row) {
  togglePick(row, !picked.value.has(Number(row.id)));
}

function toggleAll(checked: boolean | string | number) {
  picked.value = checked
    ? new Set(chapters.value.map((row) => Number(row.id)))
    : new Set<number>();
}

function majorOf(row: Row): Row | null {
  const index = chapters.value.findIndex((item) => Number(item.id) === Number(row.id));
  for (let i = index; i >= 0; i--) {
    if (isMajor(chapters.value[i])) return chapters.value[i];
  }
  return null;
}

function majorNumberOf(row: Row): number | null {
  let count = 0;
  for (const item of chapters.value) {
    if (isMajor(item)) {
      count += 1;
      if (Number(item.id) === Number(row.id)) return count;
    }
  }
  return null;
}

function minorNumberOf(row: Row): number | null {
  let count = 0;
  for (const item of chapters.value) {
    if (isMajor(item)) {
      count = 0;
      continue;
    }
    count += 1;
    if (Number(item.id) === Number(row.id)) return count;
  }
  return null;
}

function eventLabel(row: Row): string {
  if (isMajor(row)) {
    const number = majorNumberOf(row);
    return number ? `大事件${number}` : '大事件';
  }
  const number = minorNumberOf(row);
  return number ? `小事件${number}` : '小事件';
}

function statusText(row: Row): string {
  return String(row.status) === 'completed' ? '已写' : '待写';
}

function contentChars(row: Row): number {
  return String(row.content ?? '').trim().length;
}

async function load() {
  loading.value = true;
  try {
    outline.value = await loadOutline(outlineId.value);
    chapters.value = await loadChapters(outlineId.value);
    draft.value = String(outline.value.content ?? '');
    savedText.value = draft.value;
    if (!picked.value.size && chapters.value.length) {
      picked.value = new Set([Number(chapters.value[0].id)]);
    }
    syncDrafts();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

/* ── 保存 ── */

async function saveText() {
  if (!outline.value || !dirty.value || saving.value) return;
  saving.value = true;
  try {
    await api.updateRow('deepseek', 'outline_records', outlineId.value, {
      content: draft.value,
    });
    outline.value.content = draft.value;
    savedText.value = draft.value;
    ElMessage.success('大纲已保存');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function saveDraft(item: ChapterDraft, quiet = false): Promise<boolean> {
  if (!outline.value || !isDirty(item) || saving.value) return false;
  saving.value = true;
  try {
    const now = new Date().toISOString();
    await api.updateRow('deepseek', 'outline_chapters', item.id, {
      event_title: item.title,
      event_summary: item.summary,
      updated_at: now,
    });
    item.savedTitle = item.title;
    item.savedSummary = item.summary;
    item.row.event_title = item.title;
    item.row.event_summary = item.summary;
    if (!quiet) ElMessage.success('小事件信息已保存');
    return true;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
    return false;
  } finally {
    saving.value = false;
  }
}

async function saveAllDrafts() {
  const targets = drafts.value.filter((item) => isDirty(item));
  if (!targets.length) return;
  let saved = 0;
  for (const item of targets) {
    if (await saveDraft(item, true)) saved += 1;
  }
  if (saved) ElMessage.success(`已保存 ${saved} 项`);
}

function saveCurrent() {
  if (tab.value === 'text') {
    void saveText();
  } else {
    void saveAllDrafts();
  }
}

/* ── 正文 AI 改写（整篇 / 选中段 / 继续提要求 / 撤回） ── */

async function runAi() {
  if (aiRunning.value) return;
  const instruction = aiInstruction.value.trim();
  if (!instruction) {
    ElMessage.warning('先写一句修改指令，例如「第二幕加入反派反杀」');
    return;
  }
  if (!draft.value.trim()) {
    ElMessage.warning('当前大纲为空');
    return;
  }
  selectionRange.value = null;
  await streamEdit(draft.value, instruction);
}

async function rewriteSelection() {
  if (aiRunning.value) return;
  const el = textAreaRef.value;
  if (!el) return;
  const start = el.selectionStart ?? 0;
  const end = el.selectionEnd ?? 0;
  const selected = draft.value.slice(start, end);
  if (!selected.trim()) {
    ElMessage.warning('先在正文里选中要改写的文字');
    return;
  }
  const instruction = aiInstruction.value.trim() || '润色这段文字，保持原意，层次更清晰';
  selectionRange.value = { start, end };
  await streamEdit(selected, instruction);
}

async function streamEdit(text: string, instruction: string) {
  aiResult.value = '';
  aiElapsed.value = null;
  aiRunning.value = true;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.novel.editOutline(
      { outlineText: text, instruction, settings: outlineRequestSettings() },
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
  undoSnapshot.value = draft.value;
  draft.value = aiResult.value;
  selectionRange.value = null;
  ElMessage.success('已替换大纲，记得点「保存」');
}

function applySelectionAi() {
  if (!aiResult.value || !selectionRange.value) return;
  const { start, end } = selectionRange.value;
  undoSnapshot.value = draft.value;
  draft.value = draft.value.slice(0, start) + aiResult.value + draft.value.slice(end);
  selectionRange.value = null;
  aiResult.value = '';
  ElMessage.success('已替换选中文字，记得点「保存」');
}

function undoDraft() {
  if (undoSnapshot.value === null) return;
  draft.value = undoSnapshot.value;
  undoSnapshot.value = null;
  ElMessage.success('已撤回上一次替换');
}

async function continueEdit() {
  if (aiRunning.value || !aiResult.value) return;
  const instruction = continueInstruction.value.trim();
  if (!instruction) {
    ElMessage.warning('先写一句对结果的要求');
    return;
  }
  selectionRange.value = null;
  const base = aiResult.value;
  aiResult.value = '';
  await streamEdit(base, instruction);
  continueInstruction.value = '';
}

/** 把旧版网页格式（## 幕 / 【大事件】/ 【章节】）转成手机端可解析的规范格式 */
function convertToMobileFormat() {
  if (!legacyFormat.value) {
    ElMessage.info('当前大纲已经是手机端可解析的格式');
    return;
  }
  const out: string[] = [];
  let majorSeq = 0;
  let minorSeq = 0;
  for (const raw of draft.value.split('\n')) {
    const text = raw.trim();
    const act = /^#{1,6}\s*(第[一二三四五六七八九十0-9]+幕.*)$/.exec(text);
    if (act) {
      out.push(`══ ${act[1]} ══`, '');
      continue;
    }
    const major = /^【大事件】\s*(.+)$/.exec(text);
    if (major) {
      majorSeq += 1;
      minorSeq = 0;
      out.push(`══ 大事件${majorSeq}：${major[1]} ══`);
      continue;
    }
    const minor = /^【章节】\s*(.+)$/.exec(text);
    if (minor) {
      minorSeq += 1;
      const body = minor[1];
      const at = body.search(/[：:]/);
      const title = (at >= 0 ? body.slice(0, at) : body).trim();
      const summary = at >= 0 ? body.slice(at + 1).trim() : '';
      out.push(`○ 小事件${minorSeq}：${title}`);
      if (summary) out.push(summary);
      out.push('');
      continue;
    }
    out.push(raw);
  }
  draft.value = out.join('\n').replace(/\n{3,}/g, '\n\n').trim() + '\n';
  ElMessage.success('已转为手机端格式，记得点「保存」');
}

/* ── 批量 AI 改写：结果只挂在对应项下方，不直接改库 ── */

const batchInstruction = ref('');
const batchBusy = ref(false);

function pickItems(rows: Row[]) {
  return rows.map((row) => ({
    index: Number(row.event_index ?? 0),
    type: String(row.event_type ?? 'minor'),
    title: String(row.event_title ?? ''),
    summary: String(row.event_summary ?? ''),
  }));
}

async function batchRewrite() {
  if (batchBusy.value || !picked.value.size) return;
  const rows = chapters.value.filter((row) => picked.value.has(Number(row.id)));
  batchBusy.value = true;
  try {
    const result = await api.writing.novel.rewriteChapters({
      instruction: batchInstruction.value.trim() || '润色标题与概要，让冲突更具体、更有钩子',
      outlineContext: draft.value.slice(0, 3000),
      chapters: pickItems(rows),
      settings: outlineRequestSettings(),
    });
    const byIndex = new Map(result.chapters.map((item) => [Number(item.index), item]));
    let count = 0;
    for (const item of drafts.value) {
      const target = byIndex.get(Number(item.row.event_index));
      if (!target) continue;
      item.result = { title: target.title, summary: target.summary };
      count += 1;
    }
    if (count) {
      ElMessage.success(`已生成 ${count} 项改写结果，确认后逐项替换`);
    } else {
      ElMessage.warning('没有匹配到可改写的项');
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    batchBusy.value = false;
  }
}

function applyResult(item: ChapterDraft, mode: 'both' | 'title' | 'summary') {
  if (!item.result) return;
  item.undo = { title: item.title, summary: item.summary };
  if (mode !== 'summary') item.title = item.result.title;
  if (mode !== 'title') item.summary = item.result.summary;
  ElMessage.success('已替换，记得点「保存」');
}

function undoApply(item: ChapterDraft) {
  if (!item.undo) return;
  item.title = item.undo.title;
  item.summary = item.undo.summary;
  item.undo = null;
  ElMessage.success('已撤回上一次替换');
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

/* ── AI 对话（多轮，围绕当前事件 / 章节） ── */

const chatVisible = ref(false);
const chatTargetId = ref<number | null>(null);
const chatMessages = ref<ChatMessage[]>([]);
const chatInput = ref('');
const chatRunning = ref(false);
const chatError = ref('');
const injectSelected = ref(false);
const chatBodyRef = ref<HTMLElement | null>(null);
let chatController: AbortController | null = null;

const quickPrompts = [
  '按小说设定写出本节概要',
  '细化本节的情节推进',
  '让本节与前后事件衔接更自然',
  '精简本节概要，去掉冗余',
  '换一个更贴切的标题',
];

const chatTarget = computed(
  () => drafts.value.find((item) => item.id === chatTargetId.value) ?? null,
);

function openChat(item: ChapterDraft) {
  if (chatTargetId.value !== item.id) {
    chatMessages.value = [];
    chatError.value = '';
  }
  chatTargetId.value = item.id;
  chatVisible.value = true;
  void scrollChat();
}

function scrollChat() {
  void nextTick(() => {
    const el = chatBodyRef.value;
    if (el) el.scrollTop = el.scrollHeight;
  });
}

async function sendChat(text?: string) {
  if (chatRunning.value) return;
  const target = chatTarget.value;
  if (!target) return;
  const content = (text ?? chatInput.value).trim();
  if (!content) return;
  if (text === undefined) chatInput.value = '';

  chatError.value = '';
  chatMessages.value.push({ role: 'user', content });
  const assistantIndex = chatMessages.value.length;
  chatMessages.value.push({ role: 'assistant', content: '', streaming: true });
  scrollChat();

  const history = chatMessages.value
    .slice(0, assistantIndex)
    .map((item) => ({ role: item.role, content: item.content }));

  const selectedEvents = injectSelected.value
    ? drafts.value
      .filter((item) => item.id !== target.id)
      .map((item) => ({ title: item.title, summary: item.summary }))
    : [];

  chatRunning.value = true;
  chatController = new AbortController();
  try {
    await api.writing.novel.chatOutline(
      {
        chapterTitle: target.title,
        chapterSummary: target.summary,
        outlineContext: draft.value.slice(0, 6000),
        selectedEvents,
        messages: history,
        settings: outlineRequestSettings(),
      },
      {
        onDelta: (delta) => {
          chatMessages.value[assistantIndex].content += delta;
          scrollChat();
        },
      },
      chatController.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成');
    } else {
      chatError.value = err instanceof Error ? err.message : String(err);
    }
  } finally {
    chatMessages.value[assistantIndex].streaming = false;
    chatRunning.value = false;
    chatController = null;
  }
}

function stopChat() {
  chatController?.abort();
}

function clearChat() {
  if (chatRunning.value) return;
  chatMessages.value = [];
  chatError.value = '';
}

function firstLine(text: string): string {
  const line = text.split('\n').map((part) => part.trim()).find((part) => part.length > 0) ?? '';
  return line
    .replace(/^标题\s*[：:]\s*/, '')
    .replace(/^[\s═=＝*_]+/, '')
    .replace(/[\s═=＝*_]+$/, '');
}

function applyChat(message: ChatMessage, mode: 'summary' | 'append' | 'title') {
  const target = chatTarget.value;
  const text = message.content.trim();
  if (!target || !text) return;
  target.undo = { title: target.title, summary: target.summary };
  if (mode === 'summary') {
    target.summary = text;
  } else if (mode === 'append') {
    target.summary = target.summary ? `${target.summary}\n${text}` : text;
  } else {
    target.title = firstLine(text);
  }
  ElMessage.success('已写入，记得点「保存」');
}

watch(chatVisible, (visible) => {
  if (!visible) stopChat();
});

/* ── 初始化 ── */

function reload() {
  picked.value = new Set();
  drafts.value = [];
  void load();
}

onMounted(() => {
  void loadAiSettings();
  void load();
});
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      :title="String(outline?.title || '大纲编辑')"
      :desc="'共 ' + chapters.length + ' 个事件 · ' + minorCount + ' 个小事件。可多选事件/小事件，分别修改或让 AI 对话改写。'"
      back="/writing/outlines?intent=edit"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
        <el-button :icon="Refresh" @click="reload">重新载入</el-button>
        <el-button
          type="primary"
          :icon="Check"
          :loading="saving"
          :disabled="tab === 'text' ? !dirty : !structureDirty"
          @click="saveCurrent"
        >
          保存
        </el-button>
      </template>
    </PageHeader>

    <div class="edit-tabs">
      <button type="button" :class="{ on: tab === 'text' }" @click="tab = 'text'">大纲正文</button>
      <button type="button" :class="{ on: tab === 'structure' }" @click="tab = 'structure'">事件结构</button>
    </div>

    <div class="edit-grid">
      <aside class="card card-flush structure-panel">
        <div class="card-head"><h3>事件与小事件</h3><span class="mono text-muted">{{ chapters.length }} 项</span></div>
        <div class="struct-tools">
          <el-checkbox
            :model-value="allPicked"
            :indeterminate="somePicked"
            @change="toggleAll"
          >
            全选
          </el-checkbox>
          <span class="text-muted">已选 {{ picked.size }} 项</span>
        </div>
        <div class="batch-row">
          <el-input v-model="batchInstruction" size="small" placeholder="批量改写指令（可选）" />
          <el-button
            size="small"
            type="primary"
            :icon="MagicStick"
            :loading="batchBusy"
            :disabled="!picked.size"
            @click="batchRewrite"
          >
            AI 改写所选
          </el-button>
        </div>
        <div class="batch-hint">改写结果只显示在右侧对应项下方，确认后再替换。</div>
        <div class="structure-body">
          <template v-for="item in chapters" :key="String(item.id)">
            <div
              class="structure-line major"
              :class="{ on: picked.has(Number(item.id)) }"
              v-if="isMajor(item)"
            >
              <input
                type="checkbox"
                class="pick"
                :checked="picked.has(Number(item.id))"
                @change="togglePick(item, ($event.target as HTMLInputElement).checked)"
              />
              <button type="button" class="structure-row major-btn" @click="toggleRow(item)">
                <span class="sr-index">{{ item.event_index }}</span>
                <span class="sr-main">
                  <span class="sr-title">{{ item.event_title || '未命名' }}</span>
                  <span class="sr-meta">大事件</span>
                </span>
              </button>
            </div>
            <div
              v-else
              class="structure-line"
              :class="{ on: picked.has(Number(item.id)) }"
            >
              <input
                type="checkbox"
                class="pick"
                :checked="picked.has(Number(item.id))"
                @change="togglePick(item, ($event.target as HTMLInputElement).checked)"
              />
              <button type="button" class="structure-row" @click="toggleRow(item)">
                <span class="sr-index">{{ item.event_index }}</span>
                <span class="sr-main">
                  <span class="sr-title">{{ item.event_title || '未命名' }}</span>
                  <span class="sr-meta">小事件</span>
                </span>
              </button>
            </div>
          </template>
          <div v-if="!chapters.length" class="empty-hint">这部作品还没有事件结构。</div>
        </div>
      </aside>

      <section class="card card-flush edit-main">
        <template v-if="tab === 'text'">
          <div class="card-head">
            <h3>大纲正文</h3>
            <div class="head-right">
              <span v-if="dirty" class="dirty-tag">未保存</span>
              <el-button
                v-if="legacyFormat"
                size="small"
                :icon="Iphone"
                @click="convertToMobileFormat"
              >
                转为手机格式
              </el-button>
            </div>
          </div>
          <div class="edit-body">
            <textarea
              ref="textAreaRef"
              v-model="draft"
              class="outline-textarea-native"
              rows="22"
              placeholder="在这里编辑大纲正文… 选中一段文字可以让 AI 只改这一段"
            />
            <div class="ai-row">
              <el-input v-model="aiInstruction" placeholder="AI 指令，例如：第二幕加入反派反杀，节奏更紧凑" />
              <el-button v-if="!aiRunning" :icon="MagicStick" @click="rewriteSelection">改写选中</el-button>
              <el-button v-if="!aiRunning" type="primary" :icon="MagicStick" @click="runAi">AI 修改整篇</el-button>
              <el-button v-else type="danger" plain :icon="VideoPause" @click="stopAi">停止</el-button>
            </div>
            <div class="ai-hint">选中一段文字 →「改写选中」只替换那一段；不选则「AI 修改整篇」。</div>
            <div v-if="aiResult || aiRunning" class="ai-result">
              <div class="ai-result-head">
                <span>{{ selectionRange ? 'AI 改写选中' : 'AI 修改结果' }}</span>
                <span class="mono text-muted">
                  {{ aiRunning ? '生成中…' : aiResult.length + ' 字' }}
                </span>
              </div>
              <div class="ai-result-text">{{ aiResult }}<span v-if="aiRunning" class="caret" /></div>
              <div class="ai-continue">
                <el-input v-model="continueInstruction" size="small" placeholder="对结果继续提要求，例如：再紧凑一点、保留人物对话" />
                <el-button size="small" :disabled="aiRunning || !aiResult" @click="continueEdit">继续改写</el-button>
              </div>
              <div class="ai-result-foot">
                <el-button
                  size="small"
                  :disabled="aiRunning || !aiResult"
                  @click="selectionRange ? applySelectionAi() : applyAi()"
                >
                  {{ selectionRange ? '替换选中' : '替换大纲' }}
                </el-button>
                <el-button v-if="undoSnapshot !== null" size="small" text @click="undoDraft">撤回</el-button>
                <el-button size="small" text :icon="Refresh" :disabled="aiRunning" @click="selectionRange ? rewriteSelection() : runAi()">
                  重新生成
                </el-button>
              </div>
            </div>
          </div>
        </template>

        <template v-else>
          <div class="card-head">
            <h3>所选事件 / 小事件</h3>
            <div class="head-right">
              <span v-if="picked.size > 1" class="multi-tag">多选 {{ picked.size }} 项</span>
              <span v-if="structureDirty" class="dirty-tag">未保存</span>
            </div>
          </div>
          <div class="edit-body">
            <div v-if="!drafts.length" class="empty-hint">
              在左侧勾选要编辑的事件或小事件（可多选），这里会逐项显示所选内容。
            </div>
            <div v-else class="draft-list">
              <div v-for="item in drafts" :key="item.id" class="draft-card">
                <div class="draft-head">
                  <div class="dh-left">
                    <span class="type-tag" :class="{ major: isMajor(item.row) }">
                      {{ isMajor(item.row) ? '大事件' : '小事件' }}
                    </span>
                    <span class="dh-label">{{ eventLabel(item.row) }}</span>
                    <span v-if="!isMajor(item.row) && majorOf(item.row)" class="dh-meta">
                      所属：{{ majorOf(item.row)?.event_title }}
                    </span>
                    <span class="dh-meta">· {{ statusText(item.row) }}</span>
                    <span v-if="contentChars(item.row)" class="dh-meta">· 正文 {{ contentChars(item.row) }} 字</span>
                  </div>
                  <div class="dh-actions">
                    <el-button size="small" :icon="ChatDotRound" @click="openChat(item)">AI 改写这项</el-button>
                    <el-button size="small" text :disabled="!isDirty(item)" :loading="saving" @click="saveDraft(item)">
                      保存这项
                    </el-button>
                  </div>
                </div>

                <div class="field-label">标题</div>
                <el-input v-model="item.title" placeholder="事件 / 小事件标题" />
                <div class="field-label">概要</div>
                <el-input
                  v-model="item.summary"
                  type="textarea"
                  :rows="5"
                  resize="vertical"
                  placeholder="这一事件 / 小事件发生什么、冲突与结果"
                />

                <div v-if="item.result" class="ai-inline">
                  <div class="ai-inline-head">
                    <span>AI 改写结果</span>
                    <span class="text-muted">未应用</span>
                  </div>
                  <div class="ai-inline-row"><b>标题：</b>{{ item.result.title }}</div>
                  <div class="ai-inline-row summary"><b>概要：</b>{{ item.result.summary }}</div>
                  <div class="ai-inline-foot">
                    <el-button size="small" type="primary" plain @click="applyResult(item, 'both')">全部替换</el-button>
                    <el-button size="small" @click="applyResult(item, 'title')">替换标题</el-button>
                    <el-button size="small" @click="applyResult(item, 'summary')">替换概要</el-button>
                    <el-button size="small" text :icon="CopyDocument" @click="copy(item.result.title + '\n' + item.result.summary)">复制</el-button>
                  </div>
                </div>

                <div v-if="item.undo" class="undo-row">
                  <span>已替换过一次</span>
                  <el-button size="small" text @click="undoApply(item)">撤回替换</el-button>
                </div>
              </div>
            </div>
          </div>
        </template>
      </section>
    </div>

    <el-drawer
      v-model="chatVisible"
      :title="chatTarget ? `AI 生成大纲 · ${eventLabel(chatTarget.row)}` : 'AI 生成大纲'"
      size="560px"
    >
      <div class="chat-wrap">
        <div ref="chatBodyRef" class="chat-body">
          <div v-if="chatTarget" class="current-bubble">
            <div class="cb-head">
              <span>当前大纲</span>
              <span v-if="isDirty(chatTarget)" class="dirty-tag">未保存</span>
            </div>
            <div class="cb-title">{{ chatTarget.title || '（未命名小事件）' }}</div>
            <div class="cb-summary">
              {{ chatTarget.summary || '（暂无概要，可在下方告诉 AI 你想怎么写）' }}
            </div>
          </div>

          <div v-for="(message, index) in chatMessages" :key="index" class="chat-msg" :class="message.role">
            <div class="bubble">
              <template v-if="message.content">{{ message.content }}</template>
              <span v-else class="text-muted">生成中…</span>
              <span v-if="message.streaming" class="caret" />
            </div>
            <div v-if="message.role === 'assistant' && !message.streaming && message.content.trim()" class="apply-row">
              <el-button size="small" text @click="applyChat(message, 'summary')">替换概要</el-button>
              <el-button size="small" text @click="applyChat(message, 'append')">追加到概要</el-button>
              <el-button size="small" text @click="applyChat(message, 'title')">替换标题</el-button>
              <el-button size="small" text @click="copy(message.content)">复制</el-button>
            </div>
          </div>

          <div v-if="!chatMessages.length" class="chat-hint">
            和 AI 聊聊这一节怎么写。AI 会读取整部大纲与同批所选事件，只改标题 / 概要，不写正文。
          </div>
        </div>

        <div v-if="chatError" class="chat-error">{{ chatError }}</div>

        <div class="chat-quick">
          <button
            v-for="prompt in quickPrompts"
            :key="prompt"
            type="button"
            class="chip chip-sm"
            :disabled="chatRunning"
            @click="sendChat(prompt)"
          >
            {{ prompt }}
          </button>
        </div>

        <el-checkbox v-model="injectSelected" class="inject-check">
          把同批所选的其他事件也交给 AI
        </el-checkbox>

        <div class="chat-input">
          <el-input
            v-model="chatInput"
            type="textarea"
            :rows="2"
            resize="none"
            placeholder="描述你的要求，例如：把本节概要改成主角初遇反派"
            @keydown.enter.exact.prevent="sendChat()"
          />
          <div class="chat-actions">
            <el-button text :disabled="chatRunning || !chatMessages.length" @click="clearChat">清空对话</el-button>
            <el-button v-if="!chatRunning" type="primary" :icon="ChatDotRound" @click="sendChat()">发送</el-button>
            <el-button v-else type="danger" plain :icon="VideoPause" @click="stopChat">停止</el-button>
          </div>
        </div>
      </div>
    </el-drawer>

    <AiSettingsDrawer v-model="settingsVisible" kind="outline" />
  </div>
</template>

<style scoped>
.edit-tabs {
  display: inline-flex;
  gap: 4px;
  padding: 4px;
  margin-bottom: 16px;
  border-radius: 10px;
  background: #fff;
  border: 1px solid var(--line);
}

.edit-tabs button {
  padding: 7px 18px;
  border: none;
  border-radius: 8px;
  background: transparent;
  font-size: 13px;
  color: var(--ink-2);
  cursor: pointer;
}

.edit-tabs button.on {
  background: var(--brand-soft);
  color: var(--brand);
  font-weight: 600;
}

.edit-grid {
  display: grid;
  grid-template-columns: 300px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .edit-grid { grid-template-columns: minmax(0, 1fr); }
}

.structure-panel { max-height: calc(100vh - 220px); display: flex; flex-direction: column; }
.structure-body { overflow: auto; padding: 4px 6px 8px; flex: 1; }

.struct-tools {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 2px 14px 8px;
}

.batch-row { display: flex; gap: 8px; padding: 0 12px 6px; }
.batch-hint { padding: 0 14px 10px; font-size: 11px; color: var(--ink-4); line-height: 1.5; }

.structure-line {
  display: flex;
  align-items: center;
  gap: 4px;
  border: 1px solid transparent;
  border-radius: 8px;
  padding-right: 6px;
}

.structure-line:hover { background: var(--bg-soft); }
.structure-line.on { background: var(--brand-soft); border-color: #d4cec2; }

.pick { margin: 0 0 0 6px; accent-color: var(--brand); cursor: pointer; }

.major-btn .sr-title { font-weight: 600; color: var(--ink-1); }

.structure-row {
  display: flex;
  align-items: center;
  gap: 9px;
  width: 100%;
  padding: 8px 9px;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}

.structure-row:hover { background: var(--bg-soft); }
.structure-row.on { background: var(--brand-soft); border-color: #d4cec2; }

.sr-index {
  width: 22px;
  height: 22px;
  flex: 0 0 22px;
  display: grid;
  place-items: center;
  border-radius: 6px;
  background: #fff;
  border: 1px solid var(--line-strong);
  color: var(--ink-3);
  font-size: 10.5px;
}

.sr-main { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.sr-title { font-size: 12.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sr-meta { font-size: 10px; color: var(--ink-4); }

.edit-main { min-height: 520px; }
.edit-body { padding: 18px 20px; }

.outline-textarea-native {
  display: block;
  width: 100%;
  min-height: 420px;
  padding: 14px 16px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--bg-soft);
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 14.5px;
  line-height: 1.9;
  color: var(--ink-1);
  resize: vertical;
  outline: none;
}

.outline-textarea-native:focus { border-color: #d4cec2; background: #fff; }

.ai-hint { margin-top: 8px; font-size: 11.5px; color: var(--ink-4); }
.ai-continue { display: flex; gap: 8px; margin-top: 10px; }

.ai-row { display: flex; gap: 10px; align-items: center; margin-top: 14px; }

.ai-result {
  margin-top: 14px;
  padding: 14px 16px;
  border-radius: 10px;
  border: 1px solid var(--line);
  background: var(--bg-soft);
}

.ai-result-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 12px;
  font-weight: 600;
  color: var(--ink-2);
}

.ai-result-text {
  max-height: 260px;
  overflow: auto;
  margin-top: 8px;
  font-family: 'Source Han Serif SC', 'Songti SC', serif;
  font-size: 13.5px;
  line-height: 1.9;
  color: var(--ink-1);
  white-space: pre-wrap;
}

.ai-result-foot { display: flex; gap: 8px; margin-top: 10px; }

/* ── 多选卡片 ── */
.draft-list { display: flex; flex-direction: column; gap: 16px; }

.draft-card {
  padding: 14px 16px 16px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #fff;
}

.draft-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}

.dh-left { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; min-width: 0; }

.type-tag {
  padding: 1px 6px;
  border-radius: 5px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
  color: var(--ink-3);
  font-size: 10.5px;
}

.type-tag.major { color: var(--brand); border-color: #d4cec2; background: var(--brand-soft); }

.dh-label { font-size: 12px; font-weight: 600; color: var(--ink-1); }
.dh-meta { font-size: 11px; color: var(--ink-4); }
.dh-actions { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; }

.ai-inline {
  margin-top: 12px;
  padding: 10px 12px;
  border-radius: 10px;
  border: 1px dashed #d4cec2;
  background: var(--brand-soft);
}

.ai-inline-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 11.5px;
  font-weight: 600;
  color: var(--brand);
}

.ai-inline-row { margin-top: 6px; font-size: 12.5px; line-height: 1.7; color: var(--ink-1); }
.ai-inline-row.summary { white-space: pre-wrap; color: var(--ink-2); }
.ai-inline-foot { display: flex; gap: 6px; margin-top: 8px; flex-wrap: wrap; }

.undo-row {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 10px;
  font-size: 11.5px;
  color: var(--ink-4);
}

.field-label { margin: 14px 0 8px; font-size: 12px; font-weight: 600; color: var(--ink-3); }
.field-label:first-child { margin-top: 0; }

.dirty-tag {
  padding: 2px 7px;
  border-radius: 5px;
  background: var(--warn-soft);
  color: var(--warn);
  font-size: 10.5px;
  font-weight: 600;
}

.multi-tag {
  padding: 2px 7px;
  border-radius: 5px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 10.5px;
  font-weight: 600;
}

.head-right { display: flex; align-items: center; gap: 8px; }

/* ── AI 对话抽屉 ── */
.chat-wrap { display: flex; flex-direction: column; height: 100%; min-height: 0; }

.chat-body { flex: 1; overflow: auto; padding: 4px 2px 12px; }

.current-bubble {
  margin-bottom: 14px;
  padding: 10px 12px;
  border-radius: 10px;
  background: var(--bg-soft);
  border: 1px solid var(--line);
}

.cb-head { display: flex; align-items: center; justify-content: space-between; font-size: 11px; font-weight: 600; color: var(--ink-3); }
.cb-title { margin-top: 6px; font-size: 13px; font-weight: 600; color: var(--ink-1); }
.cb-summary { margin-top: 4px; font-size: 12px; line-height: 1.7; color: var(--ink-2); white-space: pre-wrap; }

.chat-msg { display: flex; flex-direction: column; margin-bottom: 12px; }
.chat-msg.user { align-items: flex-end; }

.chat-msg .bubble {
  max-width: 88%;
  padding: 9px 12px;
  border-radius: 10px;
  font-size: 13px;
  line-height: 1.7;
  white-space: pre-wrap;
  word-break: break-word;
}

.chat-msg.user .bubble { background: var(--brand); color: #fff; }
.chat-msg.assistant .bubble { background: var(--bg-soft); border: 1px solid var(--line); color: var(--ink-1); }

.apply-row { display: flex; flex-wrap: wrap; gap: 2px; margin-top: 4px; }

.chat-hint { padding: 14px 8px; text-align: center; font-size: 11.5px; line-height: 1.6; color: var(--ink-4); }

.chat-quick { display: flex; flex-wrap: wrap; gap: 6px; padding: 8px 0; }

.chip {
  padding: 5px 10px;
  border-radius: 999px;
  border: 1px solid var(--line-strong);
  background: #fff;
  font-size: 11.5px;
  color: var(--ink-2);
  cursor: pointer;
}

.chip:hover { border-color: #d4cec2; color: var(--brand); }
.chip:disabled { opacity: 0.5; cursor: not-allowed; }

.inject-check { margin: 2px 0 8px; }

.chat-error {
  margin-bottom: 8px;
  padding: 6px 10px;
  border-radius: 8px;
  background: var(--warn-soft);
  color: var(--warn);
  font-size: 11.5px;
}

.chat-input { border-top: 1px solid var(--line); padding-top: 10px; }
.chat-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; margin-top: 8px; }

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
</style>
