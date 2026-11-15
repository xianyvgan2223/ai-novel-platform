/**
 * stores/agent.ts —— 右侧 Agent 面板状态
 *
 * 消息按「部件」组织：一段文本 + 若干工具卡片，顺序与后端事件到达顺序一致，
 * 这样界面上就是「说了什么 → 调了什么工具 → 拿到什么」的真实时间线。
 */
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { agentApi } from '@/api/agent';
import type { AgentHistoryItem, AgentToolInfo } from '@/api/agent';

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

export type AgentPart = AgentTextPart | AgentToolPart;

export interface AgentMessage {
  id: string;
  role: 'user' | 'assistant';
  parts: AgentPart[];
  createdAt: number;
  status: 'idle' | 'streaming' | 'done' | 'cancelled' | 'error';
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

export const useAgentStore = defineStore('agent', () => {
  const messages = ref<AgentMessage[]>([]);
  const streaming = ref(false);
  const runId = ref('');
  const panelOpen = ref(readOpen());
  const panelWidth = ref(readWidth());
  const tools = ref<AgentToolInfo[]>([]);
  const lastError = ref('');

  let controller: AbortController | null = null;
  let seq = 0;

  const canSend = computed(() => !streaming.value);
  const hasMessages = computed(() => messages.value.length > 0);

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

  function clear(): void {
    messages.value = [];
    lastError.value = '';
  }

  /** 只把「已经结束」的消息作为上下文，避免把半截回复再喂回去 */
  function historyOf(): AgentHistoryItem[] {
    const out: AgentHistoryItem[] = [];
    for (const message of messages.value) {
      if (message.status === 'streaming') continue;
      const content = message.parts
        .filter((part): part is AgentTextPart => part.kind === 'text')
        .map((part) => part.text)
        .join('\n')
        .trim();
      if (content) out.push({ role: message.role, content });
    }
    return out;
  }

  async function loadTools(): Promise<void> {
    if (tools.value.length) return;
    try {
      const result = await agentApi.tools();
      tools.value = result.tools ?? [];
    } catch {
      /* 工具清单只是空状态提示，失败不影响对话 */
    }
  }

  async function send(text: string): Promise<void> {
    const content = text.trim();
    if (!content || streaming.value) return;

    const past = historyOf();
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
    controller = new AbortController();

    try {
      await agentApi.chat(
        { message: content, history: past },
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
      assistant.status = aborted ? 'cancelled' : 'error';
      if (!aborted) {
        assistant.error = error instanceof Error ? error.message : String(error);
        lastError.value = assistant.error;
      }
    } finally {
      if (assistant.status === 'streaming') assistant.status = 'done';
      streaming.value = false;
      controller = null;
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

  function handleEvent(assistant: AgentMessage, event: Record<string, unknown>): void {
    const type = String(event.type ?? '');
    switch (type) {
      case 'start':
        runId.value = String(event.runId ?? '');
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
        // stage 等进度事件由卡片内部展示，这里不需要额外状态
        break;
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

  return {
    messages,
    streaming,
    runId,
    panelOpen,
    panelWidth,
    tools,
    lastError,
    canSend,
    hasMessages,
    togglePanel,
    setWidth,
    clear,
    loadTools,
    send,
    stop,
  };
});
