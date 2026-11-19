/**
 * stores/agent.ts —— 右侧 Agent 面板状态
 *
 * 消息按「部件」组织：一段文本 + 若干工具卡片，顺序与后端事件到达顺序一致。
 * 会话与消息由后端持久化，这里负责当前会话、历史列表、设置和任务计划。
 */
import { computed, ref, watch } from 'vue';
import { defineStore } from 'pinia';
import { agentApi } from '@/api/agent';
import { deviceEpoch } from '@/stores/device';
import type { AgentDownload, AgentMessageDto, AgentSession, AgentSettings, AgentTask, AgentToolInfo } from '@/api/agent';

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
  /** 执行阶段进度（来自 stage 事件），如 3/12 · 生成人物，只挂在运行中的工具卡上 */
  stage?: { label: string; index: number; total: number };
}

export type AgentPart = AgentTextPart | AgentToolPart | AgentAskPart | AgentThinkingPart;

/** 思考过程：可折叠展示，随 reasoning_content 增量更新 */
export interface AgentThinkingPart {
  kind: 'thinking';
  text: string;
}

/** Agent 向用户提问：等待选择、已选择、超时未选。 */
export interface AgentAskPart {
  kind: 'ask';
  id: string;
  question: string;
  options: string[];
  status: 'waiting' | 'answered' | 'timeout';
  answer?: string;
}

/** 上下文占用与压缩状态，展示在输入框上方 */
export interface AgentContextState {
  tokens: number;
  window: number;
  threshold: number;
  percent: number;
  /** 会话累计：Σ 所有请求的 prompt / cache hit（面板显示整体缓存命中率） */
  totalPromptTokens: number;
  totalCachedTokens: number;
  lastUsage?: {
    promptTokens: number;
    completionTokens: number;
    cachedTokens: number;
  };
  /** 最近一次自动/手动压缩的结果（用于提示条） */
  compacted: { count: number; freedTokens: number } | null;
}

export interface AgentMessage {
  id: string;
  role: 'user' | 'assistant';
  parts: AgentPart[];
  createdAt: number;
  status: 'idle' | 'streaming' | 'done' | 'cancelled' | 'interrupted' | 'error';
  error?: string;
  /** 产生这条回答的（最后一次）模型请求的 usage：用于消息级缓存命中展示 */
  usage?: {
    promptTokens: number;
    completionTokens: number;
    cachedTokens: number;
  };
  /** 由历史接口加载的消息：错误文案跟随气泡展示，当前运行的错误统一走面板顶部错误条 */
  fromHistory?: boolean;
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
  const promptTokens = Number(dto.promptTokens ?? 0) || 0;
  const status: AgentMessage['status'] =
    dto.status === 'cancelled'
      ? 'cancelled'
      : dto.status === 'interrupted'
        ? 'interrupted'
        : dto.status === 'error'
          ? 'error'
          : 'done';
  // 历史里的运行已经结束：没收到结果的工具 / 提问在这里收尾，不能永远显示「执行中」
  if (dto.status !== 'streaming') {
    for (const part of parts) {
      if (part.kind === 'tool' && part.status === 'running') {
        part.status = 'error';
        if (!part.error) part.error = '任务已中断，未收到工具返回';
      } else if (part.kind === 'ask' && part.status === 'waiting') {
        part.status = 'timeout';
      }
    }
  }
  return {
    id: 'h' + dto.id,
    role: dto.role,
    parts: parts.length ? parts : dto.content ? [{ kind: 'text', text: dto.content }] : [],
    createdAt: dto.createdAt ?? Date.now(),
    status,
    error: dto.error || undefined,
    // 旧消息没有 usage：不展示缓存命中，避免显示成 0%
    usage: promptTokens > 0
      ? {
          promptTokens,
          completionTokens: Number(dto.completionTokens ?? 0) || 0,
          cachedTokens: Number(dto.cachedTokens ?? 0) || 0,
        }
      : undefined,
    fromHistory: true,
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
  const downloads = ref<AgentDownload[]>([]);
  const hiddenTaskId = ref<number | null>(null);
  const lastSeq = ref(0);
  const compacting = ref(false);
  const context = ref<AgentContextState>({
    tokens: 0,
    window: 0,
    threshold: 0,
    percent: 0,
    totalPromptTokens: 0,
    totalCachedTokens: 0,
    compacted: null,
  });

  let controller: AbortController | null = null;
  let seq = 0;

  const canSend = computed(() => !streaming.value);
  const hasMessages = computed(() => messages.value.length > 0);
  const activeTask = computed<AgentTask | null>(() => {
    const list = tasks.value;
    if (!list.length) return null;
    const running = [...list].reverse().find((task) => task.status !== 'done');
    const task = running ?? list[list.length - 1];
    return task && task.id === hiddenTaskId.value ? null : task;
  });

  function dismissTask(): void {
    const task = activeTask.value;
    if (task) hiddenTaskId.value = task.id;
  }

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
    hiddenTaskId.value = null;
    lastError.value = '';
    resetContext();
  }

  function resetContext(): void {
    context.value = {
      tokens: 0,
      window: 0,
      threshold: 0,
      percent: 0,
      totalPromptTokens: 0,
      totalCachedTokens: 0,
      compacted: null,
    };
  }

  function percentOf(tokens: number, window: number): number {
    if (!Number.isFinite(tokens) || !Number.isFinite(window) || window <= 0) return 0;
    return Math.min(100, Math.round((tokens * 100) / window));
  }

  /**
   * 打开一个历史会话。resume=false 表示由 resumeActive 内部调用：
   * 它已经知道自己要接管运行，不能再回头调 resumeActive，否则会无限递归。
   */
  async function openSession(id: number, resume = true): Promise<void> {
    if (streaming.value) return;
    const detail = await agentApi.session(id);
    currentSessionId.value = detail.session.id;
    currentTitle.value = detail.session.title;
    messages.value = (detail.messages ?? []).map(toMessage);
    tasks.value = detail.tasks ?? [];
    hiddenTaskId.value = null;
    lastError.value = '';
    // 打开会话时带回上次的上下文占用，进度条不用等下一轮才有数
    const info = detail.context;
    const tokens = Number(info?.tokens ?? detail.session.contextTokens ?? 0) || 0;
    const window = Number(info?.window ?? 0) || 0;
    const cached = Number(info?.cachedTokens ?? detail.session.contextCachedTokens ?? 0) || 0;
    context.value = {
      tokens,
      window,
      threshold: Number(info?.threshold ?? 0) || 0,
      percent: Number(info?.percent ?? percentOf(tokens, window)) || 0,
      totalPromptTokens: Number(info?.totalPromptTokens ?? 0) || 0,
      totalCachedTokens: Number(info?.totalCachedTokens ?? 0) || 0,
      // 打开历史会话时用上次请求的实测值初始化，缓存命中率不用等下一轮才显示
      lastUsage: tokens > 0
        ? { promptTokens: tokens, completionTokens: 0, cachedTokens: cached }
        : undefined,
      compacted: null,
    };
    // 如果这个会话还有没结束的运行，自动接管
    if (resume) void resumeActive();
  }

  async function deleteSession(id: number): Promise<void> {
    if (streaming.value) return;
    await agentApi.deleteSession(id);
    if (currentSessionId.value === id) {
      newSession();
    }
    await loadSessions();
  }

  /** 手动压缩历史（对应 DSH 的 /compact）。返回压缩条数与释放的 token。 */
  async function compactNow(): Promise<{ count: number; freedTokens: number } | null> {
    const id = currentSessionId.value;
    if (!id || streaming.value || compacting.value) return null;
    compacting.value = true;
    try {
      const result = await agentApi.compactSession(id);
      context.value = {
        ...context.value,
        tokens: Number(result.estimatedTokens) || 0,
        window: Number(result.contextWindow) || context.value.window,
        threshold: Number(result.threshold) || context.value.threshold,
        percent: Number(result.percent) || 0,
        compacted: result.compacted
          ? { count: Number(result.count) || 0, freedTokens: Number(result.freedTokens) || 0 }
          : null,
      };
      return { count: Number(result.count) || 0, freedTokens: Number(result.freedTokens) || 0 };
    } finally {
      compacting.value = false;
    }
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

  // ── 下载库 ──

  /** 下载库列表；失败直接抛出，由打开弹窗的调用方提示，避免静默失败 */
  async function loadDownloads(): Promise<void> {
    const result = await agentApi.downloads();
    downloads.value = result.downloads ?? [];
  }

  async function deleteDownload(id: number): Promise<void> {
    await agentApi.deleteDownload(id);
    downloads.value = downloads.value.filter((item) => item.id !== id);
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

    messages.value.push({
      id: nextId('a'),
      role: 'assistant',
      parts: [],
      createdAt: Date.now(),
      status: 'streaming',
    });
    // 关键：必须拿数组里的响应式代理。直接改 push 进去的原始对象不会触发渲染，
    // 表现就是生成过程中界面一动不动，直到流结束才刷一次。
    const assistant = liveMessage(messages.value[messages.value.length - 1]);

    streaming.value = true;
    lastError.value = '';
    runId.value = '';
    lastSeq.value = 0;
    // 新一轮开始：收起上一轮的压缩提示
    context.value = { ...context.value, compacted: null };
    controller = new AbortController();
    let terminated = false;

    try {
      await agentApi.chat(
        { message: content, sessionId: currentSessionId.value },
        {
          onEvent: (event) => {
            if (isTerminalEvent(event)) terminated = true;
            handleEvent(assistant, event);
          },
        },
        controller.signal,
      );
      // 连接结束但没收到 done/cancelled/error：多半是代理/网络把流掐断了，
      // 后台还在跑，接回去继续看，而不是把气泡标记成完成。
      if (assistant.status === 'streaming' && runId.value) {
        await resume(assistant);
        return;
      }
      // 后台也没在跑（没拿到 runId）：保留已收到的内容，但明确标成中断而不是完成
      if (!terminated && assistant.status === 'streaming') {
        markInterrupted(assistant);
      }
    } catch (error) {
      // 错误事件已经由 handleEvent 把气泡收尾（error）；此时再 resume 会多出一条重复回复
      if (assistant.status !== 'streaming') return;
      const aborted = error instanceof DOMException && error.name === 'AbortError';
      if (aborted) {
        assistant.status = 'cancelled';
        settleRunningTools(assistant);
      } else if (runId.value) {
        // 网络抖动/连接被掐断：后台仍在跑，自动接回去
        await resume(assistant);
        return;
      } else {
        assistant.status = 'error';
        assistant.error = error instanceof Error ? error.message : String(error);
        lastError.value = assistant.error;
        settleRunningTools(assistant);
      }
    } finally {
      settleRunningTools(assistant);
      streaming.value = false;
      controller = null;
      void loadSessions();
    }
  }

  /** 停止生成：先等服务端确认取消（失败再用 keepalive 兜底），然后收尾本地流 */
  async function stop(): Promise<void> {
    if (!streaming.value) return;
    const id = runId.value;
    if (id) {
      try {
        await agentApi.cancel(id);
      } catch {
        // 取消请求失败时退回 keepalive，至少把「停止」送达服务端
        agentApi.cancelKeepalive(id);
      }
    }
    controller?.abort();
    const assistant = messages.value[messages.value.length - 1];
    if (assistant && assistant.role === 'assistant' && assistant.status === 'streaming') {
      assistant.status = 'cancelled';
      settleRunningTools(assistant);
    }
    runId.value = '';
    lastSeq.value = 0;
    streaming.value = false;
  }

  /** 接回一个正在后台运行的对话。existing 为空时新建气泡并从 0 重放。 */
  async function resume(existing?: AgentMessage): Promise<void> {
    if (!runId.value) return;
    let bubble = existing;
    // 已收尾的气泡（done/cancelled/error）不再接回：否则会多出一条重复回复
    if (bubble && bubble.status !== 'streaming') return;
    if (!bubble) {
      messages.value.push({
        id: nextId('a'),
        role: 'assistant',
        parts: [],
        createdAt: Date.now(),
        status: 'streaming',
      });
      bubble = messages.value[messages.value.length - 1];
      lastSeq.value = 0;
    }
    const target = liveMessage(bubble);
    streaming.value = true;
    controller = new AbortController();
    let terminated = false;
    try {
      await agentApi.attachRun(
        runId.value,
        lastSeq.value,
        {
          onEvent: (event) => {
            if (isTerminalEvent(event)) terminated = true;
            handleEvent(target, event);
          },
          onDone: () => {
            // 真正的 done 事件由 handleEvent 收尾；这里只解除 busy。
            // 流在没收到终止事件时结束（断线）留给 finally 判断，不能当「完成」。
            streaming.value = false;
          },
        },
        controller.signal,
      );
    } catch {
      /* 重连失败就保留已经收到的内容 */
    } finally {
      // 只有收到 done/cancelled/error 才算正常结束；否则是断线，内容可能不完整
      if (!terminated && target.status === 'streaming') markInterrupted(target);
      settleRunningTools(target);
      streaming.value = false;
      controller = null;
      void loadSessions();
    }
  }

  /** 页面刷新或切换会话后，检查是否有未结束的运行并接管。返回是否真的有运行被接管。 */
  async function resumeActive(): Promise<boolean> {
    if (streaming.value) return true;
    let run: { runId: string; sessionId: number } | undefined;
    try {
      const result = await agentApi.activeRuns(currentSessionId.value);
      run = result.runs?.[0];
    } catch {
      return false; // 没有可接管的运行
    }
    if (!run) return false;
    // 接管前先补齐运行所属会话的历史，否则只能看到运行中的半条回复。
    // 当前会话没变且已有消息时不重复加载；openSession 内部再调 resumeActive 会递归，传 false。
    if (currentSessionId.value !== run.sessionId || !messages.value.length) {
      try {
        await openSession(run.sessionId, false);
      } catch {
        /* 历史加载失败也继续接管实时流，至少能看到后续输出 */
      }
    }
    runId.value = run.runId;
    lastSeq.value = 0;
    await resume();
    return true;
  }

  /** 收到这些事件才算运行正常收尾，否则视为连接中断 */
  function isTerminalEvent(event: Record<string, unknown>): boolean {
    return ['done', 'cancelled', 'error'].includes(String(event.type ?? ''));
  }

  /** 连接断了但没收到终止事件：保留已收到的内容并标注可能不完整，而不是显示「完成」 */
  function markInterrupted(assistant: AgentMessage): void {
    assistant.status = 'interrupted';
    assistant.error = '连接中断，内容可能不完整';
    settleRunningTools(assistant);
  }

  function handleEvent(message: AgentMessage, event: Record<string, unknown>): void {
    // 统一改代理对象：store 里的对象可能来自 push 的原始值，直接改不会触发渲染
    const assistant = liveMessage(message);
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
      case 'thinking': {
        const text = String(event.text ?? '');
        if (!text) break;
        const last = assistant.parts[assistant.parts.length - 1];
        if (last && last.kind === 'thinking') {
          last.text += text;
        } else {
          assistant.parts.push({ kind: 'thinking', text });
        }
        break;
      }
      case 'stage': {
        // 阶段进度挂在最后一个正在运行的工具卡上；没有运行中的卡就忽略
        const part = findRunningTool(assistant, '');
        if (part) {
          part.stage = {
            label: String(event.label ?? ''),
            index: Number(event.index ?? 0),
            total: Number(event.total ?? 0),
          };
        }
        break;
      }
      case 'tool_call': {
        const id = String(event.id ?? '');
        // 重放事件时同一个 id 可能重复到达，避免出现两张一样、其中一张永远「执行中」的卡
        if (id && findTool(assistant, id)) break;
        assistant.parts.push({
          kind: 'tool',
          id,
          name: String(event.name ?? 'tool'),
          args: asRecord(event.args),
          status: 'running',
        });
        break;
      }
      case 'tool_result':
      case 'tool_error': {
        const id = String(event.id ?? '');
        let matched = false;
        for (const part of assistant.parts) {
          if (part.kind === 'tool' && id && part.id === id) {
            applyToolResult(part, type, event);
            matched = true;
          }
        }
        if (!matched) {
          const part =
            findTool(assistant, id) ?? findRunningTool(assistant, String(event.name ?? ''));
          if (part) applyToolResult(part, type, event);
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
        const id = String(event.id ?? '');
        if (id && findAsk(assistant, id)) break;
        assistant.parts.push({
          kind: 'ask',
          id,
          question: String(event.question ?? ''),
          options,
          status: 'waiting',
        });
        break;
      }
      case 'ask_answer': {
        const id = String(event.id ?? '');
        for (const part of assistant.parts) {
          if (part.kind === 'ask' && part.id === id) {
            part.status = event.timeout ? 'timeout' : 'answered';
            part.answer = String(event.answer ?? '');
          }
        }
        break;
      }
      case 'download':
        // 事件触发刷新失败不打扰对话；用户打开下载库时会看到明确提示
        void loadDownloads().catch(() => {
          /* 打开下载库时提示 */
        });
        break;
      case 'context': {
        const tokens = Number(event.tokens ?? 0) || 0;
        const window = Number(event.window ?? context.value.window) || 0;
        context.value = {
          ...context.value,
          tokens,
          window,
          threshold: Number(event.threshold ?? context.value.threshold) || 0,
          percent: Number(event.percent ?? percentOf(tokens, window)) || 0,
        };
        break;
      }
      case 'usage': {
        const promptTokens = Number(event.promptTokens ?? 0) || 0;
        const window = Number(event.window ?? context.value.window) || 0;
        const totalPromptTokens = Number(event.totalPromptTokens ?? context.value.totalPromptTokens) || 0;
        const totalCachedTokens = Number(event.totalCachedTokens ?? context.value.totalCachedTokens) || 0;
        // 同一轮 run 可能有多次模型请求：用最后一次（也就是生成最终回答那次）
        // 作为这条消息的缓存命中数据，和服务端持久化的口径一致。
        assistant.usage = {
          promptTokens,
          completionTokens: Number(event.completionTokens ?? 0) || 0,
          cachedTokens: Number(event.cachedTokens ?? 0) || 0,
        };
        context.value = {
          ...context.value,
          tokens: promptTokens,
          window,
          threshold: Number(event.threshold ?? context.value.threshold) || 0,
          percent: Number(event.percent ?? percentOf(promptTokens, window)) || 0,
          totalPromptTokens,
          totalCachedTokens,
          lastUsage: {
            promptTokens,
            completionTokens: Number(event.completionTokens ?? 0) || 0,
            cachedTokens: Number(event.cachedTokens ?? 0) || 0,
          },
        };
        break;
      }
      case 'compaction': {
        const tokens = Number(event.estimatedTokens ?? context.value.tokens) || 0;
        const window = Number(event.window ?? context.value.window) || 0;
        context.value = {
          ...context.value,
          tokens,
          window,
          threshold: Number(event.threshold ?? context.value.threshold) || 0,
          percent: percentOf(tokens, window),
          compacted: {
            count: Number(event.count ?? 0) || 0,
            freedTokens: Number(event.freedTokens ?? 0) || 0,
          },
        };
        break;
      }
      case 'error':
        assistant.status = 'error';
        assistant.error = String(event.error ?? '生成失败');
        lastError.value = assistant.error;
        settleRunningTools(assistant);
        streaming.value = false;
        break;
      case 'cancelled':
        assistant.status = 'cancelled';
        settleRunningTools(assistant);
        streaming.value = false;
        break;
      case 'done':
        assistant.status = 'done';
        settleRunningTools(assistant);
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

  /** 取 messages 里的响应式代理：直接改 push 进去的原始对象不会触发渲染 */
  function liveMessage(message: AgentMessage): AgentMessage {
    return messages.value.find((item) => item.id === message.id) ?? message;
  }

  function applyToolResult(
    part: AgentToolPart,
    type: string,
    event: Record<string, unknown>,
  ): void {
    part.elapsedMs = Number(event.elapsedMs ?? 0);
    if (type === 'tool_result') {
      part.status = 'ok';
      part.summary = String(event.summary ?? '');
      part.data = event.data;
      part.error = undefined;
    } else {
      part.status = 'error';
      part.error = String(event.error ?? '工具执行失败');
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

  /** 结果事件缺少 id 时，按工具名兜底找最后一张仍在运行的卡 */
  function findRunningTool(assistant: AgentMessage, name: string): AgentToolPart | null {
    for (let i = assistant.parts.length - 1; i >= 0; i -= 1) {
      const part = assistant.parts[i];
      if (part.kind === 'tool' && part.status === 'running' && (!name || part.name === name)) {
        return part;
      }
    }
    return null;
  }

  /**
   * 运行结束时兜底：还在「执行中」的工具卡不再转圈；
   * 等待中的提问也收成超时，避免运行结束后还留着可点的假交互。
   */
  function settleRunningTools(assistant: AgentMessage): void {
    for (const part of assistant.parts) {
      if (part.kind === 'tool' && part.status === 'running') {
        part.status = 'error';
        if (!part.error) part.error = '未收到工具返回（可能已中断）';
      } else if (part.kind === 'ask' && part.status === 'waiting') {
        part.status = 'timeout';
      }
    }
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

  // 切换设备后会话/任务/下载都换到另一台设备的槽位：中止当前流并整体重置，避免状态串台
  watch(deviceEpoch, () => {
    controller?.abort();
    controller = null;
    streaming.value = false;
    runId.value = '';
    lastSeq.value = 0;
    messages.value = [];
    sessions.value = [];
    currentSessionId.value = null;
    currentTitle.value = '';
    tasks.value = [];
    downloads.value = [];
    hiddenTaskId.value = null;
    lastError.value = '';
    resetContext();
    void loadSessions();
  });

  return {
    messages,
    streaming,
    runId,
    panelOpen,
    panelWidth,
    tools,
    lastError,
    lastSeq,
    sessions,
    currentSessionId,
    currentTitle,
    tasks,
    settings,
    downloads,
    context,
    compacting,
    activeTask,
    dismissTask,
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
    loadDownloads,
    deleteDownload,
    send,
    stop,
    compactNow,
    answerAsk,
    resumeActive,
  };
});
