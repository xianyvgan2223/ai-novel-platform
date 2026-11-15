/**
 * stores/agent.ts —— 右侧 Agent 面板状态
 *
 * 消息按「部件」组织：一段文本 + 若干工具卡片，顺序与后端事件到达顺序一致。
 * 会话与消息由后端持久化，这里负责当前会话、历史列表、设置和任务计划。
 */
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { agentApi } from '@/api/agent';
import type { AgentMessageDto, AgentSession, AgentSettings, AgentTask, AgentToolInfo } from '@/api/agent';

export interface AgentTextPart {
  kind: 'text';
  text: string;
}

export interface AgentToolPart {
  kind: 'tool';
  id: string;
  name: string;
  args: Record<string, unknown>;
  status: 'running' | 'ok' | 'error';
  summary?: string;
  data?: unknown;
  error?: string;
  elapsedMs?: number;
}

export type AgentPart = AgentTextPart | AgentToolPart | AgentAskPart;

/** Agent 向用户提问：等待选择、已选择、超时未选。 */
export interface AgentAskPart {
  kind: 'ask';
  id: string;
  question: string;
  options: string[];
  status: 'waiting' | 'answered' | 'timeout';
  answer?: string;
}

export interface AgentMessage {
  id: string;
  role: 'user' | 'assistant';
  parts: AgentPart[];
  createdAt: number;
  status: 'idle' | 'streaming' | 'done' | 'cancelled' | 'interrupted' | 'error';
  error?: string;
}

const WIDTH_KEY = 'dsh.agentPanelWidth';
const OPEN_KEY = 'dsh.agentPanelOpen';
const MIN_WIDTH = 300;
const MAX_WIDTH = 620;
const DEFAULT_WIDTH = 380;

function clampWidth(value: number): number {
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(value)));
}

function readWidth(): number {
  try {
    const saved = Number(localStorage.getItem(WIDTH_KEY));
    if (Number.isFinite(saved) && saved >= MIN_WIDTH && saved <= MAX_WIDTH) {
      return clampWidth(saved);
    }
  } catch {
    /* localStorage 不可用时用默认宽度 */
  }
  return DEFAULT_WIDTH;
}

function readOpen(): boolean {
  try {
    return localStorage.getItem(OPEN_KEY) === '1';
  } catch {
    return false;
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function toMessage(dto: AgentMessageDto): AgentMessage {
  const parts = Array.isArray(dto.parts) ? (dto.parts as AgentPart[]) : [];
  return {
    id: 'h' + dto.id,
    role: dto.role,
    parts: parts.length ? parts : dto.content ? [{ kind: 'text', text: dto.content }] : [],
    createdAt: dto.createdAt ?? Date.now(),
    status:
      dto.status === 'cancelled'
        ? 'cancelled'
        : dto.status === 'interrupted'
          ? 'interrupted'
          : dto.status === 'error'
            ? 'error'
            : 'done',
    error: dto.error || undefined,
  };
}

export const useAgentStore = defineStore('agent', () => {
  const messages = ref<AgentMessage[]>([]);
  const streaming = ref(false);
  const runId = ref('');
  const panelOpen = ref(readOpen());
  const panelWidth = ref(readWidth());
  const tools = ref<AgentToolInfo[]>([]);
  const lastError = ref('');

  const sessions = ref<AgentSession[]>([]);
  const currentSessionId = ref<number | null>(null);
  const currentTitle = ref('');
  const tasks = ref<AgentTask[]>([]);
  const settings = ref<AgentSettings | null>(null);
  const lastSeq = ref(0);

  let controller: AbortController | null = null;
  let seq = 0;

  const canSend = computed(() => !streaming.value);
  const hasMessages = computed(() => messages.value.length > 0);
  const activeTask = computed<AgentTask | null>(() => {
    const list = tasks.value;
    if (!list.length) return null;
    const running = [...list].reverse().find((task) => task.status !== 'done');
    return running ?? list[list.length - 1];
  });

  function nextId(prefix: string): string {
    seq += 1;
    return prefix + '-' + Date.now().toString(36) + '-' + seq;
  }

  function persistPanel(): void {
    try {
      localStorage.setItem(WIDTH_KEY, String(panelWidth.value));
      localStorage.setItem(OPEN_KEY, panelOpen.value ? '1' : '0');
    } catch {
      /* 忽略 */
    }
  }

  function togglePanel(): void {
    panelOpen.value = !panelOpen.value;
    persistPanel();
  }

  function setWidth(value: number): void {
    panelWidth.value = clampWidth(value);
    persistPanel();
  }

  // ── 会话 ──

  async function loadSessions(): Promise<void> {
    try {
      const result = await agentApi.sessions();
      sessions.value = result.sessions ?? [];
    } catch {
      /* 历史列表失败不影响当前对话 */
    }
  }

  /** 新对话：只清空本地状态，会话在后端由第一条消息创建。 */
  function newSession(): void {
    if (streaming.value) return;
    currentSessionId.value = null;
    currentTitle.value = '';
    messages.value = [];
    tasks.value = [];
    lastError.value = '';
  }

  async function openSession(id: number): Promise<void> {
    if (streaming.value) return;
    const detail = await agentApi.session(id);
    currentSessionId.value = detail.session.id;
    currentTitle.value = detail.session.title;
    messages.value = (detail.messages ?? []).map(toMessage);
    tasks.value = detail.tasks ?? [];
    lastError.value = '';
    // 如果这个会话还有没结束的运行，自动接管
    void resumeActive();
  }

  async function deleteSession(id: number): Promise<void> {
    if (streaming.value) return;
    await agentApi.deleteSession(id);
    if (currentSessionId.value === id) {
      newSession();
    }
    await loadSessions();
  }

  // ── 设置 ──

  async function loadSettings(): Promise<void> {
    try {
      settings.value = await agentApi.settings();
    } catch {
      /* 设置加载失败时保留默认行为 */
    }
  }

  async function saveSettings(payload: Partial<AgentSettings>): Promise<void> {
    settings.value = await agentApi.saveSettings(payload);
  }

  // ── 工具清单 ──

  async function loadTools(): Promise<void> {
    if (tools.value.length) return;
    try {
      const result = await agentApi.tools();
      tools.value = result.tools ?? [];
    } catch {
      /* 工具清单只是空状态提示，失败不影响对话 */
    }
  }

  // ── 对话 ──

  async function send(text: string): Promise<void> {
    const content = text.trim();
    if (!content || streaming.value) return;

    messages.value.push({
      id: nextId('u'),
      role: 'user',
      parts: [{ kind: 'text', text: content }],
      createdAt: Date.now(),
      status: 'done',
    });

    const assistant: AgentMessage = {
      id: nextId('a'),
      role: 'assistant',
      parts: [],
      createdAt: Date.now(),
      status: 'streaming',
    };
    messages.value.push(assistant);

    streaming.value = true;
    lastError.value = '';
    runId.value = '';
    lastSeq.value = 0;
    controller = new AbortController();

    try {
      await agentApi.chat(
        { message: content, sessionId: currentSessionId.value },
        {
          onEvent: (event) => handleEvent(assistant, event),
          onDone: () => {
            if (assistant.status === 'streaming') assistant.status = 'done';
            streaming.value = false;
          },
        },
        controller.signal,
      );
    } catch (error) {
      const aborted = error instanceof DOMException && error.name === 'AbortError';
      if (!aborted && runId.value) {
        // 网络抖动/连接被掐断：后台仍在跑，自动接回去
        await resume(assistant);
      } else {
        assistant.status = aborted ? 'cancelled' : 'error';
        if (!aborted) {
          assistant.error = error instanceof Error ? error.message : String(error);
          lastError.value = assistant.error;
        }
      }
    } finally {
      if (assistant.status === 'streaming') assistant.status = 'done';
      streaming.value = false;
      controller = null;
      void loadSessions();
    }
  }

  function stop(): void {
    if (!streaming.value) return;
    if (runId.value) {
      agentApi.cancelKeepalive(runId.value);
    }
    controller?.abort();
    const assistant = messages.value[messages.value.length - 1];
    if (assistant && assistant.role === 'assistant' && assistant.status === 'streaming') {
      assistant.status = 'cancelled';
    }
    streaming.value = false;
  }

  /** 接回一个正在后台运行的对话。existing 为空时新建气泡并从 0 重放。 */
  async function resume(existing?: AgentMessage): Promise<void> {
    if (!runId.value) return;
    let bubble = existing;
    if (!bubble || bubble.status !== 'streaming') {
      bubble = {
        id: nextId('a'),
        role: 'assistant',
        parts: [],
        createdAt: Date.now(),
        status: 'streaming',
      };
      messages.value.push(bubble);
      lastSeq.value = 0;
    }
    const target = bubble;
    streaming.value = true;
    controller = new AbortController();
    try {
      await agentApi.attachRun(
        runId.value,
        lastSeq.value,
        {
          onEvent: (event) => handleEvent(target, event),
          onDone: () => {
            if (target.status === 'streaming') target.status = 'done';
            streaming.value = false;
          },
        },
        controller.signal,
      );
    } catch {
      /* 重连失败就保留已经收到的内容 */
    } finally {
      if (target.status === 'streaming') target.status = 'done';
      streaming.value = false;
      controller = null;
      void loadSessions();
    }
  }

  /** 页面刷新或切换会话后，检查是否有未结束的运行并接管。 */
  async function resumeActive(): Promise<void> {
    if (streaming.value) return;
    try {
      const result = await agentApi.activeRuns(currentSessionId.value);
      const run = result.runs?.[0];
      if (!run) return;
      runId.value = run.runId;
      if (!currentSessionId.value) currentSessionId.value = run.sessionId;
      lastSeq.value = 0;
      await resume();
    } catch {
      /* 没有可接管的运行 */
    }
  }

  function handleEvent(assistant: AgentMessage, event: Record<string, unknown>): void {
    if (typeof event.seq === 'number') {
      lastSeq.value = event.seq;
    }
    const type = String(event.type ?? '');
    switch (type) {
      case 'start':
        runId.value = String(event.runId ?? '');
        if (event.sessionId != null) {
          currentSessionId.value = Number(event.sessionId) || null;
        }
        if (event.title) {
          currentTitle.value = String(event.title);
        }
        break;
      case 'delta':
        appendText(assistant, String(event.text ?? ''));
        break;
      case 'tool_call':
        assistant.parts.push({
          kind: 'tool',
          id: String(event.id ?? ''),
          name: String(event.name ?? 'tool'),
          args: asRecord(event.args),
          status: 'running',
        });
        break;
      case 'tool_result': {
        const part = findTool(assistant, String(event.id ?? ''));
        if (part) {
          part.status = 'ok';
          part.summary = String(event.summary ?? '');
          part.data = event.data;
          part.elapsedMs = Number(event.elapsedMs ?? 0);
        }
        break;
      }
      case 'tool_error': {
        const part = findTool(assistant, String(event.id ?? ''));
        if (part) {
          part.status = 'error';
          part.error = String(event.error ?? '工具执行失败');
          part.elapsedMs = Number(event.elapsedMs ?? 0);
        }
        break;
      }
      case 'task': {
        const task = event.task as AgentTask | undefined;
        if (task && task.id != null) {
          upsertTask(task);
        }
        break;
      }
      case 'ask': {
        const options = Array.isArray(event.options) ? (event.options as string[]) : [];
        assistant.parts.push({
          kind: 'ask',
          id: String(event.id ?? ''),
          question: String(event.question ?? ''),
          options,
          status: 'waiting',
        });
        break;
      }
      case 'ask_answer': {
        const part = findAsk(assistant, String(event.id ?? ''));
        if (part) {
          part.status = event.timeout ? 'timeout' : 'answered';
          part.answer = String(event.answer ?? '');
        }
        break;
      }
      case 'error':
        assistant.status = 'error';
        assistant.error = String(event.error ?? '生成失败');
        lastError.value = assistant.error;
        streaming.value = false;
        break;
      case 'cancelled':
        assistant.status = 'cancelled';
        streaming.value = false;
        break;
      case 'done':
        assistant.status = 'done';
        streaming.value = false;
        break;
      default:
        break;
    }
  }

  function upsertTask(task: AgentTask): void {
    const index = tasks.value.findIndex((item) => item.id === task.id);
    if (index >= 0) {
      tasks.value.splice(index, 1, task);
    } else {
      tasks.value.push(task);
    }
  }

  function appendText(assistant: AgentMessage, text: string): void {
    if (!text) return;
    const last = assistant.parts[assistant.parts.length - 1];
    if (last && last.kind === 'text') {
      last.text += text;
    } else {
      assistant.parts.push({ kind: 'text', text });
    }
  }

  function findTool(assistant: AgentMessage, id: string): AgentToolPart | null {
    for (let i = assistant.parts.length - 1; i >= 0; i -= 1) {
      const part = assistant.parts[i];
      if (part.kind === 'tool' && part.id === id) return part;
    }
    return null;
  }

  function findAsk(assistant: AgentMessage, id: string): AgentAskPart | null {
    for (let i = assistant.parts.length - 1; i >= 0; i -= 1) {
      const part = assistant.parts[i];
      if (part.kind === 'ask' && part.id === id) return part;
    }
    return null;
  }

  /** 提交用户选择：服务端唤醒等待中的 ask_user 工具，对话继续。 */
  async function answerAsk(part: AgentAskPart, answer: string): Promise<void> {
    if (part.status !== 'waiting') return;
    const result = await agentApi.answerAsk(part.id, answer);
    if (result.accepted) {
      part.status = 'answered';
      part.answer = answer;
    } else {
      part.status = 'timeout';
    }
  }

  return {
    messages,
    streaming,
    runId,
    panelOpen,
    panelWidth,
    tools,
    lastError,
    sessions,
    currentSessionId,
    currentTitle,
    tasks,
    settings,
    activeTask,
    canSend,
    hasMessages,
    togglePanel,
    setWidth,
    loadSessions,
    newSession,
    openSession,
    deleteSession,
    loadSettings,
    saveSettings,
    loadTools,
    send,
    stop,
    answerAsk,
    resumeActive,
  };
});
