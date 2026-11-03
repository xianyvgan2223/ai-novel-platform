/** api/index.ts —— 所有后端接口的集中入口（组件里只调用这里） */
import { del, download, get, getWithMeta, post, postStream, put, uploadBinary } from './client';
import type {
  Catalog, ChapterGeneratePayload, ChapterRewritePayload, ChapterRewriteResult, ConflictInfo, DbKey, DeleteResult,
  DeviceList, DrawPayload, DrawResult, HealthInfo, ImportReport, OptimizePayload, OutlineEditPayload,
  OutlineFormatPayload, BattleGeneratePayload,
  OutlineChatPayload,
  OutlineGeneratePayload, OutlineSplitPayload, OutlineSplitResult, PagedMeta, Row, Stats, SyncOverview,
  SyncRequestInfo, WriteResult,
} from './types';
import type { StreamHandlers } from './client';

export const api = {
  // ── 服务与元数据 ──
  health: () => get<HealthInfo>('/api/health'),
  catalog: () => get<Catalog>('/api/catalog'),
  /** 当前设备的数据概览（设备由 x-device-id 决定） */
  stats: () => get<Stats>('/api/stats'),

  // ── 通用数据 ──
  listRows: (db: DbKey, table: string, params: Record<string, unknown> = {}) =>
    getWithMeta<Row[], PagedMeta>('/api/data/' + db + '/' + table, params),
  getRow: (db: DbKey, table: string, pk: number) => get<Row>('/api/data/' + db + '/' + table + '/' + pk),
  createRow: (db: DbKey, table: string, row: Row) => post<WriteResult>('/api/data/' + db + '/' + table, row),
  updateRow: (db: DbKey, table: string, pk: number, row: Row) =>
    put<WriteResult>('/api/data/' + db + '/' + table + '/' + pk, row),
  deleteRow: (db: DbKey, table: string, pk: number) => del<DeleteResult>('/api/data/' + db + '/' + table + '/' + pk),

  // ── 文件导入导出（作用于当前设备的槽位）──
  importDb: (db: DbKey, file: File | Blob, mode: 'merge' | 'replace') =>
    uploadBinary<ImportReport>('/api/transfer/import?db=' + db + '&mode=' + mode, file),
  exportDb: (db: DbKey, sanitize: boolean) =>
    download('/api/transfer/export/' + db + '?sanitize=' + (sanitize ? '1' : '0'), db + '.db'),

  // ── 设备（每台设备一个独立数据槽位）──
  devices: () => get<DeviceList>('/api/sync/devices'),
  removeDevice: (deviceId: string) => del<{ deviceId: string; existed: boolean; purgedFiles: boolean }>(
    '/api/sync/devices/' + encodeURIComponent(deviceId),
  ),

  // ── 同步 ──
  overview: () => get<SyncOverview>('/api/sync/overview'),
  conflicts: (params: Record<string, unknown> = {}) => get<ConflictInfo[]>('/api/sync/conflicts', params),
  prune: () => post<{ deviceId: string; pruned: number; upTo: number }>('/api/sync/prune'),
  pull: (params: Record<string, unknown>) => get<Record<string, unknown>>('/api/sync/pull', params),
  push: (payload: Record<string, unknown>) => post<Record<string, unknown>>('/api/sync/push', payload),

  // ── 让手机去同步：网页发起 → 手机前台轮询领取 → 回报结果 ──
  requestPhoneSync: (targetDevice = '') =>
    post<SyncRequestInfo>('/api/sync/request', { targetDevice }),
  syncRequestStatus: (id: number) => get<SyncRequestInfo>('/api/sync/request/' + id),

  // ── AI 写作（服务端代理，浏览器不持有密钥）──
  writing: {
    /** 流式改写，onDelta 收到的是正文增量 */
    optimize: (payload: OptimizePayload, handlers: StreamHandlers, signal?: AbortSignal) =>
      postStream('/api/writing/optimize', payload, handlers, signal),
    /** 抽卡：短篇点子 / 长篇大纲骨架 */
    draw: (payload: DrawPayload) => post<DrawResult>('/api/writing/draw', payload),
    /** 小说创作（Spring AI）：大纲生成 / 章节生成 / 大纲改写，均为 SSE */
    novel: {
      generateOutline: (payload: OutlineGeneratePayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/outline/generate', payload, handlers, signal),
      generateChapter: (payload: ChapterGeneratePayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/chapter/generate', payload, handlers, signal),
      editOutline: (payload: OutlineEditPayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/outline/edit', payload, handlers, signal),
      /** 大纲编辑的 AI 多轮对话（SSE，纯文本） */
      chatOutline: (payload: OutlineChatPayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/outline/chat', payload, handlers, signal),
      /** 把已有大纲拆成「大事件 → 章节」结构（非流式） */
      splitOutline: (payload: OutlineSplitPayload) =>
        post<OutlineSplitResult>('/api/writing/novel/outline/split', payload),
      /** 多选事件 / 章节，批量改写标题与概要（非流式） */
      rewriteChapters: (payload: ChapterRewritePayload) =>
        post<ChapterRewriteResult>('/api/writing/novel/chapters/rewrite', payload),
      /** 把粘贴的外部大纲重排成 App 固定格式（SSE） */
      formatOutline: (payload: OutlineFormatPayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/outline/format', payload, handlers, signal),
      /** AI 写战斗：按三要素生成战斗场面（SSE） */
      generateBattle: (payload: BattleGeneratePayload, handlers: StreamHandlers, signal?: AbortSignal) =>
        postStream('/api/writing/novel/battle/generate', payload, handlers, signal),
    },
  },
};

export * from './types';
