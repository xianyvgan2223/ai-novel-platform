/** api/agent.ts —— 右侧 Agent 面板接口（SSE + 会话 + 设置） */
import { del, get, post, postKeepalive, postStream, put } from './client';
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
  createdAt: number;
}

export interface AgentSessionDetail {
  session: AgentSession;
  messages: AgentMessageDto[];
  tasks: AgentTask[];
}

export interface AgentSettings {
  apiKey: string;
  hasApiKey: boolean;
  baseUrl: string;
  model: string;
  temperature: number | null;
  maxTokens: number | null;
  topP: number | null;
  frequencyPenalty: number | null;
  presencePenalty: number | null;
  systemPrompt: string;
  webSearch: boolean;
  searchCount: number;
  searchNeedContent: boolean;
  defaults?: { baseUrl: string; model: string; hasEnvKey: boolean };
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

  settings: () => get<AgentSettings>('/api/agent/settings'),

  saveSettings: (payload: Partial<AgentSettings>) =>
    put<AgentSettings>('/api/agent/settings', payload),

  /** 回答 Agent 的提问，唤醒等待中的工具 */
  answerAsk: (id: string, answer: string) =>
    post<{ id: string; accepted: boolean }>(
      '/api/agent/asks/' + encodeURIComponent(id) + '/answer',
      { answer },
    ),
};
