/** api/agent.ts —— 右侧 Agent 面板接口（SSE + 会话 + 设置） */
import { del, get, getStream, post, postKeepalive, postStream, put } from './client';
import type { StreamHandlers } from './client';

export interface AgentHistoryItem {
  role: 'user' | 'assistant';
  content: string;
}

export interface AgentChatPayload {
  message: string;
  sessionId?: number | null;
  history?: AgentHistoryItem[];
}

export interface AgentToolInfo {
  name: string;
  description: string;
}

export interface AgentSession {
  id: number;
  title: string;
  messageCount: number;
  createdAt: number;
  updatedAt: number;
  /** 上次请求的精确上下文占用（prompt_tokens） */
  contextTokens?: number;
  /** 上次请求命中的缓存 token 数 */
  contextCachedTokens?: number;
  /** 是否已有压缩摘要 */
  hasSummary?: boolean;
}

/** 上下文占用（tokens / 窗口 / 压缩阈值 / 缓存命中） */
export interface AgentContextInfo {
  tokens: number;
  window: number;
  threshold: number;
  percent: number;
  cachedTokens?: number;
  cachePercent?: number;
  /** 会话累计：Σ 所有请求的 prompt / cache hit */
  totalPromptTokens?: number;
  totalCachedTokens?: number;
  totalCachePercent?: number;
  compacted?: boolean;
}

export interface AgentCompactResult {
  compacted: boolean;
  count: number;
  freedTokens: number;
  estimatedTokens: number;
  contextWindow: number;
  threshold: number;
  percent: number;
}

export interface AgentTaskStep {
  text: string;
  status: 'pending' | 'running' | 'done' | 'skipped';
}

export interface AgentTask {
  id: number;
  title: string;
  status: string;
  runId?: string;
  steps: AgentTaskStep[];
  createdAt: number;
  updatedAt: number;
}

export interface AgentMessageDto {
  id: number;
  role: 'user' | 'assistant';
  content: string;
  parts: unknown[];
  status: string;
  error?: string;
  elapsedMs?: number;
  promptTokens?: number;
  completionTokens?: number;
  cachedTokens?: number;
  createdAt: number;
}

export interface AgentSessionDetail {
  session: AgentSession;
  messages: AgentMessageDto[];
  tasks: AgentTask[];
  context?: AgentContextInfo;
}

export interface AgentSettings {
  apiKey: string;
  hasApiKey: boolean;
  baseUrl: string;
  model: string;
  modelOptions?: { id: string; label: string; description: string }[];
  temperature: number | null;
  maxTokens: number | null;
  topP: number | null;
  frequencyPenalty: number | null;
  presencePenalty: number | null;
  systemPrompt: string;
  webSearch: boolean;
  searchCount: number;
  searchNeedContent: boolean;
  stream: boolean;
  thinking: boolean;
  reasoningEffort: string;
  /** 面板覆盖的上下文窗口（0 = 按模型默认 1M） */
  contextWindow: number;
  reasoningEfforts?: string[];
  defaults?: {
    baseUrl: string;
    model: string;
    temperature: number;
    maxTokens: number;
    searchCount: number;
    stream: boolean;
    thinking: boolean;
    reasoningEffort: string;
    contextWindow: number;
    hasEnvKey: boolean;
  };
}

export interface AgentDownload {
  id: number;
  url: string;
  filename: string;
  mime: string;
  size: number;
  status: string;
  error?: string;
  createdAt: number;
  downloadUrl: string;
}

export const agentApi = {
  /** 发起对话：文本增量、工具调用、任务计划都通过事件流返回 */
  chat: (payload: AgentChatPayload, handlers: StreamHandlers, signal?: AbortSignal) =>
    postStream('/api/agent/chat', payload, handlers, signal),

  /** 主动取消：服务端据此停掉 LLM 流与正在执行的工具 */
  cancel: (runId: string) =>
    post<{ runId: string; cancelled: boolean }>(
      '/api/agent/runs/' + encodeURIComponent(runId) + '/cancel',
      {},
    ),

  /** 页面卸载/点停止时用的「不等响应」取消，keepalive 保证请求能发出去 */
  cancelKeepalive: (runId: string) =>
    postKeepalive('/api/agent/runs/' + encodeURIComponent(runId) + '/cancel'),

  tools: () => get<{ tools: AgentToolInfo[] }>('/api/agent/tools'),

  sessions: () => get<{ sessions: AgentSession[] }>('/api/agent/sessions'),

  session: (id: number) => get<AgentSessionDetail>('/api/agent/sessions/' + id),

  deleteSession: (id: number) =>
    del<{ id: number; deleted: boolean }>('/api/agent/sessions/' + id),

  /** 手动压缩当前会话历史（对应 DSH 的 /compact） */
  compactSession: (id: number) =>
    post<AgentCompactResult>('/api/agent/sessions/' + id + '/compact', {}),

  settings: () => get<AgentSettings>('/api/agent/settings'),

  saveSettings: (payload: Partial<AgentSettings>) =>
    put<AgentSettings>('/api/agent/settings', payload),

  /** 回答 Agent 的提问，唤醒等待中的工具 */
  answerAsk: (id: string, answer: string) =>
    post<{ id: string; accepted: boolean }>(
      '/api/agent/asks/' + encodeURIComponent(id) + '/answer',
      { answer },
    ),

  /** 重连到正在运行的对话：从 after 之后重放事件并继续跟随 */
  attachRun: (runId: string, after: number, handlers: StreamHandlers, signal?: AbortSignal) =>
    getStream(
      '/api/agent/runs/' + encodeURIComponent(runId) + '/stream?after=' + Math.max(0, after),
      handlers,
      signal,
    ),

  /** 当前设备（可选会话）还没结束的运行 */
  activeRuns: (sessionId?: number | null) =>
    get<{ runs: { runId: string; sessionId: number; lastSeq: number; startedAt: number }[] }>(
      '/api/agent/runs/active',
      sessionId ? { sessionId } : {},
    ),

  /** 下载库 */
  downloads: () => get<{ downloads: AgentDownload[] }>('/api/agent/downloads'),

  deleteDownload: (id: number) =>
    del<{ id: number; deleted: boolean }>('/api/agent/downloads/' + id),
};
