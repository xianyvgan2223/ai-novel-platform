<script setup lang="ts">
/**
 * 网页端「小说灵感」：把移动端的推演 / 对话 / 人物卡 / 大纲注入搬过来。
 * 推演每次并行生成多个候选，选中一个作为故事事实，再继续往后推。
 */
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { Delete, MagicStick, Plus, Refresh, Setting, VideoPause } from '@element-plus/icons-vue';
import { formatTime } from '@/api';
import RichText from '@/components/RichText.vue';
import PageHeader from '@/components/PageHeader.vue';
import InspirationBranchCard from './InspirationBranchCard.vue';
import InspirationCardsDrawer from './InspirationCardsDrawer.vue';
import InspirationOutlineDialog from './InspirationOutlineDialog.vue';
import InspirationSettingsDrawer from './InspirationSettingsDrawer.vue';
import {
  aiSettings, buildChatSystemPrompt, buildGenerateTurns, buildMergeTurns, buildSystemPrompt,
  createBranch, createChatMessage, createMessage, createSession, deleteBranch, deleteMessage, deleteSession,
  isoNow, listBranches, listCards, listChatMessages, listMessages, listSessions, loadSettings,
  setBranchChosen, streamInspiration, toSettings, updateBranch, updateMessage, updateSession,
} from './inspirationApi';
import type {
  InspirationBranch, InspirationCard, InspirationChatMessage, InspirationMessage, InspirationSession,
  InspirationSettings, OutlineEvent,
} from './inspirationApi';

interface DraftBranch {
  index: number;
  text: string;
  done: boolean;
  error: string;
}

interface DraftState {
  messageId: number;
  instruction: string;
  generationNo: number;
  merge: boolean;
  branches: DraftBranch[];
}

type TimelineItem =
  | { kind: 'round'; time: string; id: number; message: InspirationMessage }
  | { kind: 'chat'; time: string; id: number; chat: InspirationChatMessage };

const loading = ref(true);
const sessions = ref<InspirationSession[]>([]);
const session = ref<InspirationSession | null>(null);
const messages = ref<InspirationMessage[]>([]);
const chatMessages = ref<InspirationChatMessage[]>([]);
const cards = ref<InspirationCard[]>([]);
const settings = ref<InspirationSettings>(toSettings({}));
const mode = ref<'deduction' | 'chat'>('deduction');
const input = ref('');
const errorText = ref('');

const generating = ref(false);
const merging = ref(false);
const chatGenerating = ref(false);
const chatDraft = ref('');
const draft = ref<DraftState | null>(null);
const activeGenerations = ref<Record<number, number>>({});
const mergePicks = ref<Record<number, number[]>>({});

const bodyRef = ref<HTMLElement | null>(null);
const nearBottom = ref(true);
let scrollScheduled = false;
const controllers: AbortController[] = [];
let chatController: AbortController | null = null;

/* 对话框 */
const settingsVisible = ref(false);
const worldVisible = ref(false);
const worldViewDraft = ref('');
const themeDraft = ref('');
const cardsVisible = ref(false);
const outlineVisible = ref(false);

const branchEditVisible = ref(false);
const branchEditBranch = ref<InspirationBranch | null>(null);
const branchEditText = ref('');
const branchSaving = ref(false);

const instructionEditVisible = ref(false);
const instructionEditMessage = ref<InspirationMessage | null>(null);
const instructionEditText = ref('');
const instructionRegenerate = ref(true);
const instructionSaving = ref(false);

const mergeDialogVisible = ref(false);
const mergeTarget = ref<InspirationMessage | null>(null);
const mergeRequirement = ref('');

const busy = computed(() => generating.value || merging.value || chatGenerating.value);
const currentTitle = computed(() => session.value?.title.trim() || '小说灵感');
const canSend = computed(() => input.value.trim().length > 0 && !busy.value);

const timeline = computed<TimelineItem[]>(() => {
  const items: TimelineItem[] = [
    ...messages.value.map((message) => ({
      kind: 'round' as const,
      time: message.createdAt,
      id: message.id,
      message,
    })),
    ...chatMessages.value.map((chat) => ({
      kind: 'chat' as const,
      time: chat.createdAt,
      id: chat.id,
      chat,
    })),
  ];
  return items.sort((a, b) => a.time.localeCompare(b.time) || a.id - b.id);
});

const adoptedResults = computed(() =>
  messages.value
    .map((message) => message.branches.find((branch) => branch.chosen && branch.content.trim()))
    .filter((branch): branch is InspirationBranch => Boolean(branch))
    .map((branch) => branch.content.trim()),
);

const selectedEventCount = computed(() => session.value?.events.length ?? 0);
const injectedCardCount = computed(() => cards.value.filter((card) => card.inject && card.name.trim()).length);

/* ── 初始化 / 会话 ── */

async function bootstrap(): Promise<void> {
  loading.value = true;
  try {
    settings.value = await loadSettings();
    sessions.value = await listSessions();
    if (sessions.value.length) {
      await openSession(sessions.value[0].id);
    } else {
      const id = await createSession();
      sessions.value = await listSessions();
      await openSession(id);
    }
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}

async function loadSessionList(): Promise<void> {
  sessions.value = await listSessions();
}

async function openSession(id: number): Promise<void> {
  stopAll();
  generating.value = false;
  merging.value = false;
  chatGenerating.value = false;
  const found = sessions.value.find((item) => item.id === id);
  if (!found) return;
  session.value = { ...found };
  messages.value = [];
  chatMessages.value = [];
  cards.value = [];
  activeGenerations.value = {};
  mergePicks.value = {};
  draft.value = null;
  chatDraft.value = '';
  errorText.value = '';
  loading.value = true;
  try {
    const [branches, chat, cardList] = await Promise.all([
      listBranches(id),
      listChatMessages(id),
      listCards(id),
    ]);
    messages.value = await listMessages(id, branches);
    chatMessages.value = chat;
    cards.value = cardList;
    scrollToBottom(true);
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}

async function ensureSession(): Promise<number> {
  if (session.value) return session.value.id;
  const id = await createSession();
  await loadSessionList();
  await openSession(id);
  return id;
}

async function newSession(): Promise<void> {
  if (busy.value) return;
  try {
    const id = await createSession();
    await loadSessionList();
    await openSession(id);
    ElMessage.success('已新建灵感会话');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function removeSession(target: InspirationSession): Promise<void> {
  try {
    await ElMessageBox.confirm(`删除灵感会话「${target.title || '新的灵感'}」及其全部推演 / 对话？`, '删除会话', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    stopAll();
    await deleteSession(target.id);
    await loadSessionList();
    if (session.value?.id === target.id) {
      session.value = null;
      messages.value = [];
      chatMessages.value = [];
      cards.value = [];
      if (sessions.value.length) {
        await openSession(sessions.value[0].id);
      } else {
        const id = await createSession();
        await loadSessionList();
        await openSession(id);
      }
    }
    ElMessage.success('已删除');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function applySessionPatch(patch: Record<string, unknown>): Promise<void> {
  const current = session.value;
  if (!current) return;
  await updateSession(current.id, patch);
  await loadSessionList();
}

/* ── 滚动 ── */

function onScroll(): void {
  const el = bodyRef.value;
  if (!el) return;
  nearBottom.value = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
}

function scrollToBottom(force = false): void {
  if (!force && !nearBottom.value) return;
  if (scrollScheduled) return;
  scrollScheduled = true;
  void nextTick(() => {
    scrollScheduled = false;
    const el = bodyRef.value;
    if (el) el.scrollTop = el.scrollHeight;
  });
}

/* ── 推演 ── */

function maxGeneration(message: InspirationMessage): number {
  return message.branches.reduce((max, branch) => Math.max(max, branch.generationNo), 0);
}

function generations(message: InspirationMessage): number[] {
  return [...new Set(message.branches.map((branch) => branch.generationNo))].sort((a, b) => a - b);
}

function activeGeneration(message: InspirationMessage): number {
  const gens = generations(message);
  const selected = activeGenerations.value[message.id];
  if (selected && gens.includes(selected)) return selected;
  const chosen = message.branches.find((branch) => branch.chosen);
  if (chosen) return chosen.generationNo;
  return gens.length ? gens[gens.length - 1] : 1;
}

function setGeneration(message: InspirationMessage, generation: number): void {
  activeGenerations.value = { ...activeGenerations.value, [message.id]: generation };
}

function visibleBranches(message: InspirationMessage): InspirationBranch[] {
  const generation = activeGeneration(message);
  return message.branches.filter((branch) => branch.generationNo === generation);
}

function branchLabel(message: InspirationMessage, branch: InspirationBranch): string {
  if (branch.kind === 'merge') return '合并结果';
  const sameGen = message.branches.filter((item) => item.generationNo === branch.generationNo);
  const index = sameGen.findIndex((item) => item.id === branch.id);
  return `推演 ${index + 1}`;
}

function historyBefore(messageId: number) {
  const out: { instruction: string; result: string }[] = [];
  for (const message of messages.value) {
    if (message.id === messageId) break;
    const chosen = message.branches.find((branch) => branch.chosen && branch.content.trim());
    if (!chosen) continue;
    out.push({ instruction: message.content, result: chosen.content.trim() });
  }
  return out;
}

function baseSystemPrompt(): string {
  return buildSystemPrompt({
    settings: settings.value,
    worldView: session.value?.worldView ?? '',
    theme: session.value?.theme ?? '',
    events: session.value?.events ?? [],
    cards: cards.value,
  });
}

async function reloadMessages(): Promise<void> {
  const current = session.value;
  if (!current) return;
  const branches = await listBranches(current.id);
  messages.value = await listMessages(current.id, branches);
  mergePicks.value = {};
}

async function persistDraft(active: DraftState, sessionId: number): Promise<number> {
  let saved = 0;
  for (const branch of active.branches) {
    const content = branch.text.trim();
    if (!content) continue;
    await createBranch({
      sessionId,
      messageId: active.messageId,
      content,
      kind: active.merge ? 'merge' : 'single',
      generationNo: active.generationNo,
      sourceIds: active.merge ? (mergePicks.value[active.messageId] ?? []) : [],
    });
    saved += 1;
  }
  return saved;
}

async function generateForMessage(message: InspirationMessage): Promise<void> {
  if (busy.value) return;
  const current = session.value;
  if (!current) return;
  const sessionId = current.id;
  stopAll();
  generating.value = true;
  errorText.value = '';
  const generationNo = maxGeneration(message) + 1;
  const count = Math.min(10, Math.max(1, settings.value.concurrency));
  const active: DraftState = {
    messageId: message.id,
    instruction: message.content,
    generationNo,
    merge: false,
    branches: Array.from({ length: count }, (_, i) => ({ index: i + 1, text: '', done: false, error: '' })),
  };
  draft.value = active;
  scrollToBottom(true);

  const system = baseSystemPrompt();
  const history = historyBefore(message.id);
  let aborted = 0;

  const tasks = active.branches.map(async (branch, index) => {
    const controller = new AbortController();
    controllers.push(controller);
    const turns = buildGenerateTurns({
      history,
      instruction: message.content,
      variantIndex: index + 1,
      variantCount: count,
    });
    try {
      await streamInspiration(
        { systemPrompt: system, messages: turns, settings: aiSettings(settings.value) },
        {
          onDelta: (delta) => {
            branch.text += delta;
            scrollToBottom();
          },
          onDone: () => {
            branch.done = true;
          },
        },
        controller.signal,
      );
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        aborted += 1;
        branch.error = '已停止';
      } else {
        branch.error = err instanceof Error ? err.message : String(err);
        errorText.value ||= `生成失败：${branch.error}`;
      }
    } finally {
      branch.done = true;
    }
  });

  try {
    await Promise.all(tasks);
    // 用户中途切走会话：不要把上一轮的候选写进新会话
    if (session.value?.id !== sessionId) return;
    const saved = await persistDraft(active, sessionId);
    if (saved > 0) {
      await reloadMessages();
      setGeneration(message, generationNo);
      scrollToBottom();
      if (aborted > 0) ElMessage.info('已停止，保留已生成的内容');
    } else if (aborted === 0) {
      errorText.value = '模型没有返回内容，可尝试调大最大生成长度后重试';
    }
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : String(err);
  } finally {
    generating.value = false;
    draft.value = null;
    controllers.length = 0;
  }
}

async function sendDeduction(): Promise<void> {
  const text = input.value.trim();
  if (!text || busy.value) return;
  input.value = '';
  try {
    const sessionId = await ensureSession();
    const messageId = await createMessage(sessionId, text);
    const message: InspirationMessage = {
      id: messageId,
      sessionId,
      content: text,
      createdAt: isoNow(),
      revisions: [],
      branches: [],
    };
    messages.value = [...messages.value, message];
    const title = session.value?.title.trim() ?? '';
    if (!title || title === '新的灵感') {
      const nextTitle = text.length > 20 ? `${text.slice(0, 20)}…` : text;
      if (session.value) session.value.title = nextTitle;
      await applySessionPatch({ title: nextTitle });
    } else {
      await applySessionPatch({});
    }
    scrollToBottom(true);
    await generateForMessage(message);
  } catch (err) {
    errorText.value = `发送失败：${err instanceof Error ? err.message : String(err)}`;
    generating.value = false;
    draft.value = null;
  }
}

async function regenerate(message: InspirationMessage): Promise<void> {
  if (busy.value) return;
  await generateForMessage(message);
}

async function chooseBranch(message: InspirationMessage, branch: InspirationBranch): Promise<void> {
  if (busy.value) return;
  try {
    await setBranchChosen(message.id, branch.id, message.branches);
    setGeneration(message, branch.generationNo);
    await reloadMessages();
    ElMessage.success('已采用这一版，后面的推演会承接它');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

function pickBranch(message: InspirationMessage, branch: InspirationBranch, value: boolean): void {
  const current = new Set(mergePicks.value[message.id] ?? []);
  if (value) current.add(branch.id);
  else current.delete(branch.id);
  mergePicks.value = { ...mergePicks.value, [message.id]: [...current] };
}

function pickedBranches(message: InspirationMessage): InspirationBranch[] {
  const ids = new Set(mergePicks.value[message.id] ?? []);
  return message.branches.filter((branch) => ids.has(branch.id));
}

function openMerge(message: InspirationMessage): void {
  const picked = pickedBranches(message);
  if (picked.length < 2) {
    ElMessage.warning('至少选两个候选推演才能合并');
    return;
  }
  mergeTarget.value = message;
  mergeRequirement.value = '';
  mergeDialogVisible.value = true;
}

async function doMerge(): Promise<void> {
  const message = mergeTarget.value;
  if (!message || busy.value) return;
  const picked = pickedBranches(message);
  if (picked.length < 2) return;
  const sessionId = session.value?.id;
  if (sessionId == null) return;
  mergeDialogVisible.value = false;
  merging.value = true;
  errorText.value = '';
  const generationNo = maxGeneration(message) + 1;
  const active: DraftState = {
    messageId: message.id,
    instruction: '合并推演',
    generationNo,
    merge: true,
    branches: [{ index: 1, text: '', done: false, error: '' }],
  };
  draft.value = active;
  scrollToBottom(true);
  const branch = active.branches[0];
  const controller = new AbortController();
  controllers.push(controller);
  try {
    const turns = buildMergeTurns({
      history: historyBefore(message.id),
      instruction: message.content,
      branches: picked.map((item) => item.content),
      requirement: mergeRequirement.value,
    });
    await streamInspiration(
      { systemPrompt: baseSystemPrompt(), messages: turns, settings: aiSettings(settings.value) },
      {
        onDelta: (delta) => {
          branch.text += delta;
          scrollToBottom();
        },
        onDone: () => {
          branch.done = true;
        },
      },
      controller.signal,
    );
    branch.done = true;
  } catch (err) {
    branch.error = err instanceof Error ? err.message : String(err);
    errorText.value = `合并失败：${branch.error}`;
    branch.done = true;
  }

  try {
    if (session.value?.id !== sessionId) return;
    const saved = await persistDraft(active, sessionId);
    if (saved > 0) {
      await reloadMessages();
      const merged = messages.value
        .find((item) => item.id === message.id)
        ?.branches.find((item) => item.generationNo === generationNo && item.kind === 'merge');
      if (merged) {
        await setBranchChosen(message.id, merged.id, messages.value.find((item) => item.id === message.id)?.branches ?? []);
        await reloadMessages();
      }
      setGeneration(message, generationNo);
      mergePicks.value = { ...mergePicks.value, [message.id]: [] };
      scrollToBottom();
      ElMessage.success('已合并并采用');
    }
  } catch (err) {
    errorText.value = err instanceof Error ? err.message : String(err);
  } finally {
    merging.value = false;
    draft.value = null;
    controllers.length = 0;
  }
}

async function removeBranch(branch: InspirationBranch): Promise<void> {
  try {
    await ElMessageBox.confirm('删除这条推演结果？', '删除推演', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    await deleteBranch(branch.id);
    await reloadMessages();
    ElMessage.success('已删除');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function removeMessage(message: InspirationMessage): Promise<void> {
  try {
    await ElMessageBox.confirm('删除这一轮指令及它下面的所有推演？', '删除这一轮', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  try {
    await deleteMessage(message.id);
    await reloadMessages();
    ElMessage.success('已删除');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

function openBranchEditor(branch: InspirationBranch): void {
  branchEditBranch.value = branch;
  branchEditText.value = branch.content;
  branchEditVisible.value = true;
}

async function saveBranchEditor(): Promise<void> {
  const branch = branchEditBranch.value;
  if (!branch || branchSaving.value) return;
  branchSaving.value = true;
  try {
    await updateBranch(branch.id, branchEditText.value);
    branchEditVisible.value = false;
    await reloadMessages();
    ElMessage.success('推演正文已保存');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    branchSaving.value = false;
  }
}

function openInstructionEditor(message: InspirationMessage): void {
  instructionEditMessage.value = message;
  instructionEditText.value = message.content;
  instructionRegenerate.value = true;
  instructionEditVisible.value = true;
}

async function saveInstruction(): Promise<void> {
  const message = instructionEditMessage.value;
  if (!message || instructionSaving.value) return;
  const text = instructionEditText.value.trim();
  if (!text) {
    ElMessage.warning('指令不能为空');
    return;
  }
  instructionSaving.value = true;
  try {
    await updateMessage(message.id, text);
    message.content = text;
    instructionEditVisible.value = false;
    await reloadMessages();
    if (instructionRegenerate.value && !busy.value) {
      const latest = messages.value.find((item) => item.id === message.id);
      if (latest) await generateForMessage(latest);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    instructionSaving.value = false;
  }
}

/* ── 对话 ── */

async function sendChat(): Promise<void> {
  const text = input.value.trim();
  if (!text || busy.value) return;
  input.value = '';
  try {
    const sessionId = await ensureSession();
    const userId = await createChatMessage(sessionId, 'user', text);
    const now = isoNow();
    chatMessages.value = [...chatMessages.value, { id: userId, sessionId, role: 'user', content: text, createdAt: now }];
    const title = session.value?.title.trim() ?? '';
    if (!title || title === '新的灵感') {
      const nextTitle = text.length > 20 ? `${text.slice(0, 20)}…` : text;
      if (session.value) session.value.title = nextTitle;
      await applySessionPatch({ title: nextTitle });
    } else {
      await applySessionPatch({});
    }
    scrollToBottom(true);

    chatGenerating.value = true;
    chatDraft.value = '';
    errorText.value = '';
    chatController = new AbortController();
    const system = buildChatSystemPrompt({
      settings: settings.value,
      worldView: session.value?.worldView ?? '',
      theme: session.value?.theme ?? '',
      events: session.value?.events ?? [],
      cards: cards.value,
      deductionResults: adoptedResults.value,
    });
    const turns = [
      ...chatMessages.value
        .filter((message) => message.id !== userId)
        .map((message) => ({ role: message.role, content: message.content })),
      { role: 'user' as const, content: text },
    ];
    try {
      await streamInspiration(
        { systemPrompt: system, messages: turns, settings: aiSettings(settings.value) },
        {
          onDelta: (delta) => {
            if (session.value?.id !== sessionId) return;
            chatDraft.value += delta;
            scrollToBottom();
          },
        },
        chatController.signal,
      );
      const content = chatDraft.value.trim();
      if (content) {
        const assistantId = await createChatMessage(sessionId, 'assistant', content);
        if (session.value?.id === sessionId) {
          chatMessages.value = [
            ...chatMessages.value,
            { id: assistantId, sessionId, role: 'assistant', content, createdAt: isoNow() },
          ];
        }
      }
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        ElMessage.info('已停止生成');
      } else {
        errorText.value = `对话失败：${err instanceof Error ? err.message : String(err)}`;
      }
    } finally {
      chatGenerating.value = false;
      chatDraft.value = '';
      chatController = null;
      scrollToBottom();
    }
  } catch (err) {
    errorText.value = `发送失败：${err instanceof Error ? err.message : String(err)}`;
    chatGenerating.value = false;
    chatController = null;
  }
}

function send(): void {
  if (!canSend.value) return;
  if (mode.value === 'chat') void sendChat();
  else void sendDeduction();
}

function onKeydown(event: KeyboardEvent): void {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    send();
  }
}

function stopAll(): void {
  while (controllers.length) controllers.pop()?.abort();
  chatController?.abort();
  chatController = null;
}

/* ── 设定 / 大纲 / 人物卡 / 设置 ── */

function openWorld(): void {
  worldViewDraft.value = session.value?.worldView ?? '';
  themeDraft.value = session.value?.theme ?? '';
  worldVisible.value = true;
}

async function saveWorldTheme(): Promise<void> {
  if (!session.value) return;
  try {
    await applySessionPatch({ world_view: worldViewDraft.value.trim(), theme: themeDraft.value.trim() });
    session.value.worldView = worldViewDraft.value.trim();
    session.value.theme = themeDraft.value.trim();
    worldVisible.value = false;
    ElMessage.success('设定已保存');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function saveOutlineSelection(payload: {
  outlineRecordId: number | null;
  outlineTitle: string;
  events: OutlineEvent[];
}): Promise<void> {
  // 先关弹窗：保存是异步的，避免按钮点完弹窗还停在原地
  outlineVisible.value = false;
  if (!session.value) return;
  try {
    await applySessionPatch({
      outline_record_id: payload.outlineRecordId,
      outline_title: payload.outlineTitle,
      selected_events: JSON.stringify(payload.events),
    });
    session.value.outlineRecordId = payload.outlineRecordId;
    session.value.outlineTitle = payload.outlineTitle;
    session.value.events = payload.events;
    ElMessage.success(payload.events.length ? `已导入 ${payload.events.length} 个大纲事件` : '已清除大纲事件');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function reloadCards(): Promise<void> {
  if (!session.value) return;
  cards.value = await listCards(session.value.id);
}

async function onSettingsSaved(next: InspirationSettings): Promise<void> {
  settings.value = next;
  settingsVisible.value = false;
}

/* ── 生命周期 ── */

onMounted(() => {
  void bootstrap();
});

onUnmounted(() => {
  stopAll();
});
</script>

<template>
  <div class="page insp-page">
    <PageHeader
      title="小说灵感"
      desc="和 AI 一起推演下一段剧情。推演模式每次并行生成多个候选，采用一个后再继续往后推；也可以切到对话模式讨论设定。"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="bootstrap">刷新</el-button>
        <el-button :icon="Setting" @click="settingsVisible = true">设置</el-button>
      </template>
    </PageHeader>

    <div class="insp-grid">
      <aside class="card card-flush session-panel">
        <div class="session-head">
          <h3>灵感会话</h3>
          <el-button text size="small" :icon="Plus" :disabled="busy" @click="newSession">新建</el-button>
        </div>
        <div class="session-list">
          <button
            v-for="item in sessions"
            :key="item.id"
            type="button"
            class="session-row"
            :class="{ on: session?.id === item.id }"
            @click="openSession(item.id)"
          >
            <span class="session-main">
              <span class="session-title">{{ item.title || '新的灵感' }}</span>
              <span class="session-meta">{{ formatTime(item.updatedAt) }}</span>
            </span>
            <el-icon class="session-del" title="删除会话" @click.stop="removeSession(item)">
              <Delete />
            </el-icon>
          </button>
          <div v-if="!sessions.length" class="empty-hint">还没有灵感会话</div>
        </div>
      </aside>

      <section class="card card-flush insp-main" v-loading="loading">
        <div class="insp-top">
          <div class="title-block">
            <h3>{{ currentTitle }}</h3>
            <span class="mode-hint">{{ mode === 'chat' ? '讨论设定 / 剧情，不自动续写' : `每次并行 ${settings.concurrency} 个候选推演` }}</span>
          </div>
          <div class="mode-switch">
            <button type="button" :class="{ on: mode === 'deduction' }" @click="mode = 'deduction'">推演</button>
            <button type="button" :class="{ on: mode === 'chat' }" @click="mode = 'chat'">聊天</button>
          </div>
          <div class="insp-tools">
            <el-button size="small" text @click="openWorld">设定</el-button>
            <el-button size="small" text @click="cardsVisible = true">人物卡</el-button>
            <el-button size="small" text @click="outlineVisible = true">导入大纲</el-button>
          </div>
        </div>

        <div class="ctx-line">
          <button type="button" class="ctx-chip" :class="{ on: Boolean(session?.worldView) }" @click="openWorld">
            世界观 {{ session?.worldView ? '已设' : '未设' }}
          </button>
          <button type="button" class="ctx-chip" :class="{ on: Boolean(session?.theme) }" @click="openWorld">
            主题 {{ session?.theme ? '已设' : '未设' }}
          </button>
          <button type="button" class="ctx-chip" :class="{ on: selectedEventCount > 0 }" @click="outlineVisible = true">
            大纲事件 {{ selectedEventCount }}
          </button>
          <button type="button" class="ctx-chip" :class="{ on: cards.length > 0 }" @click="cardsVisible = true">
            人物卡 {{ cards.length }}<template v-if="injectedCardCount"> / 注入 {{ injectedCardCount }}</template>
          </button>
          <span v-if="session?.outlineTitle" class="ctx-note">来源：《{{ session.outlineTitle }}》</span>
        </div>

        <div v-if="errorText" class="insp-error">
          <span>{{ errorText }}</span>
          <button type="button" @click="errorText = ''">×</button>
        </div>

        <div ref="bodyRef" class="insp-body" @scroll="onScroll">
          <div v-if="!timeline.length && !draft && !chatGenerating" class="insp-empty">
            <div class="empty-title">从一个想法开始</div>
            <div class="empty-sub">
              推演：描述接下来想发生什么，AI 会并行给出多个候选；聊天：讨论人物、设定或时间线。
            </div>
            <div class="empty-actions">
              <button type="button" class="idea-btn" @click="input = '主角在雨夜的小巷里遇到一个不该出现的人'">
                主角在雨夜的小巷里遇到一个不该出现的人
              </button>
              <button type="button" class="idea-btn" @click="input = '把下一章的冲突写成：看似赢了，其实落入圈套'">
                下一章冲突：看似赢了，其实落入圈套
              </button>
              <button type="button" class="idea-btn" @click="input = '给我三个不同的下一幕走向'">
                给我三个不同的下一幕走向
              </button>
            </div>
          </div>

          <template v-for="item in timeline" :key="`${item.kind}-${item.id}`">
            <div v-if="item.kind === 'chat'" class="msg" :class="item.chat.role">
              <div class="bubble" :class="item.chat.role">
                <RichText v-if="item.chat.role === 'assistant'" :text="item.chat.content" />
                <template v-else>{{ item.chat.content }}</template>
              </div>
            </div>

            <div v-else class="round">
              <div class="msg user">
                <div class="bubble user">{{ item.message.content }}</div>
                <div class="round-actions">
                  <el-button size="small" text @click="openInstructionEditor(item.message)">改指令</el-button>
                  <el-button size="small" text :disabled="busy" @click="regenerate(item.message)">重新推演</el-button>
                  <el-button size="small" text type="danger" @click="removeMessage(item.message)">删除</el-button>
                </div>
              </div>

              <div class="round-body">
                <div v-if="generations(item.message).length > 1" class="round-tools">
                  <span class="round-tool-label">版本</span>
                  <el-select
                    :model-value="activeGeneration(item.message)"
                    size="small"
                    class="generation-select"
                    @change="(value) => setGeneration(item.message, Number(value))"
                  >
                    <el-option
                      v-for="generation in generations(item.message)"
                      :key="generation"
                      :label="`第 ${generation} 代`"
                      :value="generation"
                    />
                  </el-select>
                  <span class="round-tool-hint">采用其中一版后，后续推演会承接它</span>
                </div>

                <div class="branch-grid">
                  <InspirationBranchCard
                    v-for="branch in visibleBranches(item.message)"
                    :key="branch.id"
                    :branch="branch"
                    :label="branchLabel(item.message, branch)"
                    :picked="(mergePicks[item.message.id] ?? []).includes(branch.id)"
                    :can-pick="true"
                    @choose="chooseBranch(item.message, branch)"
                    @edit="openBranchEditor(branch)"
                    @delete="removeBranch(branch)"
                    @pick="(value) => pickBranch(item.message, branch, value)"
                  />
                </div>

                <div v-if="(mergePicks[item.message.id]?.length ?? 0) >= 2" class="merge-row">
                  <span class="text-muted">已选 {{ mergePicks[item.message.id]?.length }} 个候选</span>
                  <el-button size="small" type="primary" :icon="MagicStick" :disabled="busy" @click="openMerge(item.message)">
                    合并所选
                  </el-button>
                </div>

                <div v-if="draft && draft.messageId === item.message.id" class="draft-branches">
                  <article v-for="branch in draft.branches" :key="branch.index" class="draft-branch">
                    <div class="draft-head">
                      <span class="draft-label">{{ draft.merge ? '合并中' : `推演 ${branch.index}` }}</span>
                      <span v-if="!branch.done" class="draft-state"><i />生成中…</span>
                      <span v-else-if="branch.error" class="draft-error">{{ branch.error }}</span>
                      <span v-else class="draft-state done">已完成</span>
                    </div>
                    <div class="draft-body">{{ branch.text }}<span v-if="!branch.done" class="caret" /></div>
                  </article>
                </div>

                <div
                  v-if="draft && draft.messageId === item.message.id && !draft.merge && !item.message.branches.length"
                  class="round-tool-hint"
                >
                  生成完成后会自动保存到这一轮下面。
                </div>
              </div>
            </div>
          </template>

          <div v-if="chatGenerating || chatDraft" class="msg assistant">
            <div class="bubble assistant chat-draft">
              {{ chatDraft }}<span class="caret" />
            </div>
          </div>
        </div>

        <footer class="composer">
          <textarea
            v-model="input"
            class="composer-input"
            :placeholder="mode === 'chat' ? '和 AI 讨论剧情、人物或设定（Enter 发送，Shift+Enter 换行）' : '描述接下来想推演的情节（Enter 发送，Shift+Enter 换行）'"
            rows="3"
            :disabled="busy"
            @keydown="onKeydown"
          />
          <div class="composer-foot">
            <span class="composer-hint">
              {{ mode === 'chat' ? '对话不会自动保存为推演结果' : `推演会生成 ${settings.concurrency} 个候选并自动保存` }}
            </span>
            <el-button v-if="busy" type="danger" plain :icon="VideoPause" @click="stopAll">停止</el-button>
            <el-button v-else type="primary" :disabled="!canSend" @click="send">
              发送
            </el-button>
          </div>
        </footer>
      </section>
    </div>

    <InspirationSettingsDrawer v-model="settingsVisible" :settings="settings" @saved="onSettingsSaved" />
    <InspirationCardsDrawer
      v-model="cardsVisible"
      :session="session"
      :cards="cards"
      :settings="settings"
      @changed="reloadCards"
    />
    <InspirationOutlineDialog v-model="outlineVisible" :session="session" @saved="saveOutlineSelection" />

    <el-dialog v-model="worldVisible" title="本作设定" width="min(560px, 94vw)" append-to-body>
      <el-form label-position="top">
        <el-form-item label="世界观">
          <el-input
            v-model="worldViewDraft"
            type="textarea"
            :rows="5"
            placeholder="时代、地点、规则、力量体系……"
          />
        </el-form-item>
        <el-form-item label="主题">
          <el-input
            v-model="themeDraft"
            type="textarea"
            :rows="4"
            placeholder="这部作品想表达什么、核心矛盾是什么"
          />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="worldVisible = false">取消</el-button>
        <el-button type="primary" @click="saveWorldTheme">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="branchEditVisible" title="编辑推演正文" width="min(760px, 94vw)" append-to-body>
      <textarea v-model="branchEditText" class="edit-area" rows="18" />
      <template #footer>
        <el-button @click="branchEditVisible = false">取消</el-button>
        <el-button type="primary" :loading="branchSaving" @click="saveBranchEditor">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="instructionEditVisible" title="修改这一轮指令" width="min(560px, 94vw)" append-to-body>
      <textarea v-model="instructionEditText" class="edit-area small" rows="6" />
      <el-checkbox v-model="instructionRegenerate" class="regen-check">保存后重新推演</el-checkbox>
      <template #footer>
        <el-button @click="instructionEditVisible = false">取消</el-button>
        <el-button type="primary" :loading="instructionSaving" @click="saveInstruction">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="mergeDialogVisible" title="合并候选推演" width="min(520px, 94vw)" append-to-body>
      <p class="merge-hint">AI 会保留各版里最好的冲突、转折和细节，合并成一个连贯结果，并自动采用它。</p>
      <el-input
        v-model="mergeRequirement"
        type="textarea"
        :rows="3"
        placeholder="附加要求（可选），例如：保留第一版的节奏、第二版的结尾"
      />
      <template #footer>
        <el-button @click="mergeDialogVisible = false">取消</el-button>
        <el-button type="primary" :disabled="busy" @click="doMerge">开始合并</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.insp-page { max-width: 1500px; padding-bottom: 24px; }

.insp-grid {
  display: grid;
  grid-template-columns: 240px minmax(0, 1fr);
  gap: 16px;
  align-items: stretch;
}

.session-panel {
  height: calc(100vh - 220px);
  min-height: 480px;
  display: flex;
  flex-direction: column;
}
.session-head { display: flex; align-items: center; justify-content: space-between; padding: 13px 14px; border-bottom: 1px solid var(--line); }
.session-head h3 { margin: 0; font-size: 14px; font-weight: 600; color: var(--ink-1); }
.session-list { overflow-y: auto; padding: 6px; flex: 1; }

.session-row {
  display: flex;
  align-items: center;
  gap: 6px;
  width: 100%;
  padding: 8px 9px;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  text-align: left;
  cursor: pointer;
}
.session-row:hover { background: var(--bg-soft); }
.session-row.on { background: var(--brand-soft); border-color: var(--line-strong); }
.session-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.session-title { font-size: 12.5px; font-weight: 550; color: var(--ink-1); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.session-meta { font-size: 10.5px; color: var(--ink-4); }
.session-del { font-size: 13px; color: var(--ink-4); opacity: 0; }
.session-row:hover .session-del { opacity: 1; }
.session-del:hover { color: var(--danger); }

.insp-main {
  height: calc(100vh - 220px);
  min-height: 520px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.insp-top { display: flex; align-items: center; gap: 12px; padding: 13px 18px; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
.title-block { min-width: 0; flex: 1; }
.title-block h3 { margin: 0; font-size: 15px; font-weight: 600; color: var(--ink-1); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mode-hint { display: block; margin-top: 3px; font-size: 10.5px; color: var(--ink-4); }
.mode-switch { display: inline-flex; gap: 3px; padding: 3px; border: 1px solid var(--line); border-radius: 9px; }
.mode-switch button { padding: 5px 12px; border: none; border-radius: 7px; background: transparent; color: var(--ink-3); font-size: 12px; cursor: pointer; }
.mode-switch button.on { background: var(--brand); color: var(--bg-page); font-weight: 600; }
.insp-tools { display: flex; align-items: center; gap: 2px; }

.ctx-line { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; padding: 8px 18px; border-bottom: 1px solid var(--line); }
.ctx-chip { padding: 2px 8px; border: 1px solid var(--line); border-radius: 999px; background: var(--bg-card); color: var(--ink-3); font-size: 11px; cursor: pointer; }
.ctx-chip:hover { border-color: var(--line-strong); color: var(--ink-1); }
.ctx-chip.on { background: var(--bg-soft); color: var(--ink-1); border-color: var(--line-strong); }
.ctx-note { font-size: 10.5px; color: var(--ink-4); }

.insp-error { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; margin: 10px 16px 0; padding: 7px 10px; border-radius: 8px; background: var(--danger-soft); color: var(--danger); font-size: 11.5px; line-height: 1.6; }
.insp-error button { border: none; background: transparent; color: inherit; cursor: pointer; font-size: 14px; line-height: 1; }

.insp-body { flex: 1; min-height: 0; overflow-y: auto; padding: 16px 18px 20px; display: flex; flex-direction: column; gap: 18px; }

.insp-empty { padding: 40px 10px; text-align: center; }
.empty-title { font-size: 15px; font-weight: 600; color: var(--ink-1); }
.empty-sub { max-width: 520px; margin: 8px auto 0; font-size: 12px; line-height: 1.7; color: var(--ink-3); }
.empty-actions { display: flex; flex-direction: column; align-items: center; gap: 7px; margin-top: 16px; }
.idea-btn { max-width: 520px; padding: 7px 12px; border: 1px solid var(--line); border-radius: 999px; background: var(--bg-card); color: var(--ink-2); font-size: 12px; cursor: pointer; }
.idea-btn:hover { border-color: var(--line-strong); background: var(--bg-soft); }

.msg { display: flex; flex-direction: column; }
.msg.user { align-items: flex-end; }
.bubble { max-width: 86%; padding: 9px 12px; border-radius: 11px; font-size: 13px; line-height: 1.75; word-break: break-word; }
.bubble.user { background: var(--brand); color: var(--bg-page); border-bottom-right-radius: 3px; white-space: pre-wrap; }
.bubble.assistant { max-width: 100%; background: var(--bg-soft); color: var(--ink-1); border-bottom-left-radius: 3px; }
.bubble.assistant :deep(p) { margin: 0 0 8px; }
.bubble.assistant :deep(p:last-child) { margin-bottom: 0; }

.round { display: flex; flex-direction: column; gap: 10px; }
.round-actions { display: flex; align-items: center; gap: 2px; margin-top: 3px; }
.round-actions :deep(.el-button) { padding: 2px 4px; height: 22px; }
.round-body { display: flex; flex-direction: column; gap: 10px; }
.round-tools { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.round-tool-label { font-size: 11px; color: var(--ink-3); }
.generation-select { width: 110px; }
.round-tool-hint { font-size: 10.5px; color: var(--ink-4); line-height: 1.6; }

.branch-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.branch-grid :deep(.branch-card) { min-height: 180px; }

.merge-row { display: flex; align-items: center; justify-content: flex-end; gap: 10px; }

.draft-branches { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.draft-branch { border: 1px dashed var(--line-strong); border-radius: 12px; background: var(--bg-soft); min-height: 150px; display: flex; flex-direction: column; }
.draft-head { display: flex; align-items: center; gap: 8px; padding: 9px 12px 0; }
.draft-label { padding: 1px 6px; border-radius: 5px; background: var(--bg-card); border: 1px solid var(--line); color: var(--ink-3); font-size: 10.5px; }
.draft-state { margin-left: auto; display: inline-flex; align-items: center; gap: 5px; font-size: 10.5px; color: var(--ink-4); }
.draft-state i { width: 5px; height: 5px; border-radius: 50%; background: var(--brand); animation: insp-pulse 1.1s ease-in-out infinite; }
.draft-state.done { color: var(--ok); }
.draft-error { margin-left: auto; font-size: 10.5px; color: var(--danger); }
.draft-body { flex: 1; padding: 8px 12px 12px; font-size: 12.5px; line-height: 1.8; color: var(--ink-2); white-space: pre-wrap; word-break: break-word; max-height: 360px; overflow-y: auto; }

.composer { padding: 10px 14px 12px; border-top: 1px solid var(--line); }
.composer-input { display: block; width: 100%; resize: vertical; min-height: 66px; max-height: 180px; padding: 9px 11px; border: 1px solid var(--line); border-radius: 10px; background: var(--bg-soft); color: var(--ink-1); font-family: var(--font-sans); font-size: 13px; line-height: 1.65; outline: none; }
.composer-input:focus { border-color: var(--line-strong); background: var(--bg-card); }
.composer-foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
.composer-hint { font-size: 10.5px; color: var(--ink-4); }

.edit-area { display: block; width: 100%; resize: vertical; padding: 10px 12px; border: 1px solid var(--line); border-radius: 9px; background: var(--bg-soft); color: var(--ink-1); font-family: var(--font-serif); font-size: 13.5px; line-height: 1.85; outline: none; }
.edit-area.small { font-family: var(--font-sans); font-size: 13px; }
.edit-area:focus { border-color: var(--line-strong); background: var(--bg-card); }
.regen-check { margin-top: 8px; }
.merge-hint { margin: 0 0 10px; font-size: 12px; line-height: 1.7; color: var(--ink-3); }

.caret { display: inline-block; width: 6px; height: 14px; margin-left: 2px; vertical-align: -2px; background: var(--ink-3); animation: insp-blink 1s steps(2, start) infinite; }

@keyframes insp-pulse { 0%, 100% { opacity: 0.35; } 50% { opacity: 1; } }
@keyframes insp-blink { to { opacity: 0; } }

@media (max-width: 1000px) {
  .insp-grid { grid-template-columns: minmax(0, 1fr); align-items: start; }
  .session-panel { height: auto; max-height: 260px; }
  .insp-main { height: auto; min-height: 620px; }
  .branch-grid, .draft-branches { grid-template-columns: minmax(0, 1fr); }
}
</style>