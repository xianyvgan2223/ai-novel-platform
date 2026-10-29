/**
 * api/client.ts —— 统一请求封装
 *
 * 只依赖 fetch，不引入 axios，减少一层抽象。
 * 所有接口统一返回 { ok, data, meta }，这里把 data 拆出来，
 * 出错则抛出带后端说明的 Error，交给调用方用 ElMessage 提示。
 *
 * 每个请求都会带上 x-device-id 请求头 —— 服务端按它决定读写哪台设备的数据槽位。
 */
import { activeDeviceId } from '@/stores/device';

const BASE = (import.meta.env.VITE_API_BASE ?? '').replace(/\/+$/, '');
const TOKEN = import.meta.env.VITE_API_TOKEN ?? '';

export interface Envelope<T> {
  ok: boolean;
  data: T;
  meta?: Record<string, unknown>;
  error?: string;
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly url: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

function headers(extra?: HeadersInit): HeadersInit {
  const base: Record<string, string> = {};
  if (TOKEN) base['x-api-token'] = TOKEN;
  // 数据隔离的关键：告诉服务端这次操作针对哪台设备
  const device = activeDeviceId.value;
  if (device) base['x-device-id'] = device;
  return { ...base, ...(extra ?? {}) };
}

async function parse<T>(res: Response, url: string): Promise<{ data: T; meta?: Record<string, unknown> }> {
  const text = await res.text();
  let body: Envelope<T> | null = null;
  try {
    body = text ? (JSON.parse(text) as Envelope<T>) : null;
  } catch {
    throw new ApiError('服务端返回了非 JSON 内容（请确认同步服务已启动）', res.status, url);
  }
  if (!res.ok || body?.ok !== true) {
    throw new ApiError(body?.error ?? ('请求失败：HTTP ' + res.status), res.status, url);
  }
  return { data: body.data, meta: body.meta };
}

export async function get<T>(path: string, params?: Record<string, unknown>): Promise<T> {
  const url = buildUrl(path, params);
  const res = await fetch(url, { headers: headers() });
  return (await parse<T>(res, url)).data;
}

/** 需要读取分页等元信息时使用；M 为 meta 的类型，默认宽松对象 */
export async function getWithMeta<T, M = Record<string, unknown>>(
  path: string,
  params?: Record<string, unknown>,
): Promise<{ data: T; meta: M }> {
  const url = buildUrl(path, params);
  const res = await fetch(url, { headers: headers() });
  const parsed = await parse<T>(res, url);
  return { data: parsed.data, meta: (parsed.meta ?? {}) as M };
}

export async function post<T>(path: string, body?: unknown): Promise<T> {
  const url = BASE + path;
  const res = await fetch(url, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'application/json' }),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return (await parse<T>(res, url)).data;
}

export async function put<T>(path: string, body?: unknown): Promise<T> {
  const url = BASE + path;
  const res = await fetch(url, {
    method: 'PUT',
    headers: headers({ 'Content-Type': 'application/json' }),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return (await parse<T>(res, url)).data;
}

export async function del<T>(path: string): Promise<T> {
  const url = BASE + path;
  const res = await fetch(url, { method: 'DELETE', headers: headers() });
  return (await parse<T>(res, url)).data;
}

/** 上传原始二进制（导入 .db） */
export async function uploadBinary<T>(path: string, file: File | Blob): Promise<T> {
  const url = BASE + path;
  const res = await fetch(url, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'application/octet-stream' }),
    body: file,
  });
  return (await parse<T>(res, url)).data;
}

/** 下载二进制并触发浏览器保存（导出 .db，需要带令牌，所以不能用 window.open） */
export async function download(path: string, fallbackName: string): Promise<void> {
  const url = BASE + path;
  const res = await fetch(url, { headers: headers() });
  if (!res.ok) {
    const text = await res.text();
    let message = '下载失败：HTTP ' + res.status;
    try {
      message = (JSON.parse(text) as Envelope<unknown>).error ?? message;
    } catch {
      /* 保留默认提示 */
    }
    throw new ApiError(message, res.status, url);
  }
  const encoded = res.headers.get('x-export-file');
  const name = encoded ? decodeURIComponent(encoded) : fallbackName;
  const blob = await res.blob();
  const objectUrl = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = objectUrl;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(objectUrl);
}

export interface StreamHandlers {
  onDelta?: (text: string) => void;
  onDone?: (info: Record<string, unknown>) => void;
}

/**
 * POST 后按 SSE 逐段读取（写作优化用）。
 * 服务端约定每行 `data: {"type":"delta"|"done"|"error", ...}`。
 * 传 AbortSignal 可以在生成中途停止，已收到的内容由调用方保留。
 */
export async function postStream(
  path: string,
  body: unknown,
  handlers: StreamHandlers,
  signal?: AbortSignal,
): Promise<void> {
  const url = BASE + path;
  const res = await fetch(url, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'application/json', Accept: 'text/event-stream' }),
    body: JSON.stringify(body),
    signal,
  });

  if (!res.ok) {
    const text = await res.text();
    let message = '请求失败：HTTP ' + res.status;
    try {
      message = (JSON.parse(text) as Envelope<unknown>).error ?? message;
    } catch {
      /* 保留默认提示 */
    }
    throw new ApiError(message, res.status, url);
  }
  if (!res.body) throw new ApiError('服务端没有返回流式响应', res.status, url);

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let finished = false;

  const handleBlock = (block: string) => {
    const data = block
      .split('\n')
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trim())
      .join('');
    if (!data) return;

    let event: { type?: string; text?: string; error?: string; [key: string]: unknown };
    try {
      event = JSON.parse(data);
    } catch {
      return;
    }

    if (event.type === 'delta' && event.text) {
      handlers.onDelta?.(event.text);
    } else if (event.type === 'error') {
      throw new ApiError(event.error ?? 'AI 生成失败', 500, url);
    } else if (event.type === 'done') {
      finished = true;
      handlers.onDone?.(event);
    }
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const blocks = buffer.split('\n\n');
    buffer = blocks.pop() ?? '';
    for (const block of blocks) handleBlock(block);
  }

  buffer += decoder.decode();
  if (buffer.trim()) handleBlock(buffer);
  if (!finished) handlers.onDone?.({});
}

function buildUrl(path: string, params?: Record<string, unknown>): string {
  const url = new URL(BASE + path, window.location.origin);
  for (const [key, value] of Object.entries(params ?? {})) {
    if (value === undefined || value === null || value === '') continue;
    url.searchParams.set(key, String(value));
  }
  // 同源时去掉 origin，保持相对路径便于调试
  return BASE ? url.toString() : url.pathname + url.search;
}
