/** api/agent.ts —— 右侧 Agent 面板接口（SSE + 取消） */
import { get, post, postKeepalive, postStream } from './client';
import type { StreamHandlers } from './client';

export interface AgentHistoryItem {
  role: 'user' | 'assistant';
  content: string;
}

export interface AgentChatPayload {
  message: string;
  history: AgentHistoryItem[];
}

export interface AgentToolInfo {
  name: string;
  description: string;
}

export const agentApi = {
  /** 发起对话：文本增量、工具调用、阶段进度都通过事件流返回 */
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
};
