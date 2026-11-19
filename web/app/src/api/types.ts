/** api/types.ts —— 与服务端接口对应的类型定义 */

export type DbKey = 'deepseek' | 'novel';

export interface ColumnMeta {
  name: string;
  type: 'INTEGER' | 'REAL' | 'TEXT' | string;
  pk: boolean;
  notNull: boolean;
  /** 该列在 SQL 里有 DEFAULT，新增记录时可以留空 */
  hasDefault: boolean;
  autoIncrement: boolean;
  ref: string | null;
  appMissingOnCreate?: boolean;
}

export interface TableMeta {
  db: DbKey;
  name: string;
  label: string;
  module: string;
  singleton: boolean;
  columns: ColumnMeta[];
  searchColumns: string[];
}

export interface DatabaseMeta {
  key: DbKey;
  label: string;
  file: string;
  appVersion: number;
  tables: TableMeta[];
}

export interface Catalog {
  databases: DatabaseMeta[];
}

export interface HealthInfo {
  service: string;
  apiVersion: number;
  serverTime: number;
  uptimeSeconds: number;
  /** 后端运行时版本（Java 版返回 JVM 版本） */
  node: string;
  dataDir: string;
  authRequired: boolean;
  /** 数据隔离方式：per-device = 每台设备一个独立数据槽位 */
  isolation?: string;
  deviceCount?: number;
  devices?: { deviceId: string; name: string; lastSeenAt: number | null }[];
  /** v1 遗留的共享库文件名（还在的话） */
  legacyFiles?: string[];
  databases: { key: DbKey; file: string; appVersion: number; label: string }[];
}

export interface TableStats {
  count: number;
  updatedAt: number | null;
}

export interface Stats {
  /** 当前正在查看哪台设备的槽位 */
  deviceId: string;
  deviceExists: boolean;
  deviceSeq: number;
  /** 设备清单版本号，变了说明有新设备连上来 */
  revision: number;
  devices: DeviceInfo[];
  databases: Record<DbKey, { label: string; file: string; appVersion: number; total: number; tables: Record<string, TableStats> }>;
}

export interface DeviceInfo {
  deviceId: string;
  name: string;
  platform: string;
  idBase: number;
  /** 该设备数据在服务端的目录名（devices/<scopeDir>/） */
  scopeDir: string;
  createdAt: number;
  lastSeenAt: number | null;
  /** 该设备槽位里的总行数（只有设备清单接口会算） */
  rowsOwned?: number;
  /** 按「库.表」统计的行数 */
  rowCounts?: Record<string, number>;
  conflicts?: number;
  cursor: number;
  lastPushAt: number | null;
  lastPullAt: number | null;
}

export interface DeviceList {
  activeDeviceId: string;
  devices: DeviceInfo[];
  totalRows: number;
  revision: number;
  /** v1 时期的共享库文件（还存在的话），可手动上传导入到某台设备 */
  legacyFiles?: { file: string; bytes: number }[];
}

export interface ConflictInfo {
  id: number;
  deviceId: string;
  db: string;
  table: string;
  pk: number;
  incomingRev: number;
  serverRev: number;
  incomingDevice: string;
  detectedAt: number;
  resolution: string;
  detail: string;
}

export interface SyncOverview {
  deviceId: string;
  deviceExists: boolean;
  deviceSeq: number;
  revision: number;
  devices: DeviceInfo[];
  recentConflicts: ConflictInfo[];
  allConflicts: number;
  stats: Stats['databases'] | null;
}

export type Row = Record<string, unknown>;

export interface PagedMeta {
  page: number;
  pageSize: number;
  total: number;
  pages: number;
  truncated: boolean;
  db: string;
  table: string;
  label: string;
  filters: Record<string, string>;
}

export interface ImportReport {
  db: string;
  mode: string;
  /** 数据实际落到了哪台设备的槽位 */
  deviceId: string;
  targetDevice?: string;
  importedAt: number;
  uploadedBytes: number;
  sourceVersion: number;
  tables: Record<string, { read: number; written: number; unchanged: number; cleared: number }>;
  unknownTables: string[];
  unknownColumns: Record<string, string[]>;
  warnings: string[];
  totalRows: number;
  totalWritten: number;
  totalUnchanged: number;
}

/** 「请手机同步」请求的状态 */
export interface SyncRequestInfo {
  id: number;
  targetDevice: string;
  requestedBy: string;
  requestedAt: number;
  /** pending=等待手机确认 / claimed=手机已领取 / done=完成 / failed=失败 / rejected=手机拒绝 */
  status: 'pending' | 'claimed' | 'done' | 'failed' | 'rejected';
  claimedAt: number | null;
  finishedAt: number | null;
  result: string;
  /** 手机上报的实时进度 */
  progress: {
    message: string;
    current: number | null;
    total: number | null;
    updatedAt: number;
  } | null;
}

export interface WriteResult {
  seq: number;
  rev: number;
  pk: number;
  unchanged: boolean;
  row?: Row;
  unknownColumns?: string[];
}

export interface DeleteResult {
  deleted: { table: string; pk: number; rev: number; seq: number }[];
  count: number;
  rootPk: number;
}

/** ── 写作优化 ── */

export type WritingAction = 'polish' | 'deai' | 'expand' | 'condense' | 'continue' | 'structure';

export type WritingStyle = 'original' | 'plain' | 'literary' | 'restrained' | 'hot' | 'suspense' | 'ancient';

export type WritingStrength = 'light' | 'medium' | 'strong';

export interface OptimizePayload {
  text: string;
  actions: WritingAction[];
  style?: WritingStyle;
  strength?: WritingStrength;
  /** 额外要求，例如「删掉所有比喻」 */
  extra?: string;
  settings?: AiRequestSettings;
}

export type DrawKind = 'short' | 'outline';

export interface DrawPayload {
  kind: DrawKind;
  genre?: string;
  keywords?: string;
  perspective?: string;
  count?: number;
  extra?: string;
  settings?: AiRequestSettings;
}

export interface WritingCardField {
  label: string;
  value: string;
}

export interface WritingCard {
  title: string;
  logline: string;
  fields: WritingCardField[];
}

export interface DrawResult {
  kind: DrawKind;
  cards: WritingCard[];
}

/** 写作优化流式事件的结束信息 */
export interface OptimizeDoneInfo {
  chars?: number;
  elapsedMs?: number;
}

/** ── 小说创作（Spring AI）── */

/** 单次模型调用的设置，来自网页「AI 设置」 */
export interface AiRequestSettings {
  model?: string;
  temperature?: number;
  maxTokens?: number;
  systemPrompt?: string;
  /** 仅写作工具使用：关闭后请求里带 thinking=disabled */
  enableThinking?: boolean;
}

/** 小说灵感：前端拼好的 system + 多轮消息，后端只负责流式生成 */
export interface InspirationChatTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface InspirationStreamPayload {
  systemPrompt?: string;
  messages: InspirationChatTurn[];
  settings?: AiRequestSettings;
}

export interface OutlineGeneratePayload {
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
  majorCount: number;
  minorCount: number;
  extra?: string;
  settings?: AiRequestSettings;
}

export interface GeneratedChapterRow {
  index: number;
  type: 'major' | 'minor';
  title: string;
  summary: string;
}

export interface GeneratedOutline {
  title: string;
  concept: string;
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
  charactersJson: string;
  skeletonJson: string;
  outlineText: string;
  chapters: GeneratedChapterRow[];
  majorCount: number;
  minorCount: number;
}

export interface ChapterGeneratePayload {
  title: string;
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
  outlineContent: string;
  chapterTitle: string;
  chapterSummary: string;
  prevChapterTitle?: string;
  prevChapterContent?: string;
  nextChapterTitle?: string;
  characters?: string;
  foreshadows?: string;
  storyState?: string;
  minWords?: number;
  maxWords?: number;
  extra?: string;
  settings?: AiRequestSettings;
}

export interface OutlineEditPayload {
  outlineText: string;
  instruction: string;
  extra?: string;
  settings?: AiRequestSettings;
}

/** 大纲编辑的 AI 多轮对话 */
export interface OutlineChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface OutlineChatPayload {
  chapterTitle: string;
  chapterSummary: string;
  outlineContext?: string;
  selectedEvents?: { title: string; summary: string }[];
  messages: OutlineChatMessage[];
  settings?: AiRequestSettings;
}

export interface OutlineSplitPayload {
  title?: string;
  genre?: string;
  theme?: string;
  protagonist?: string;
  worldview?: string;
  outlineText: string;
  settings?: AiRequestSettings;
}

export interface OutlineSplitResult {
  actsJson: string;
  chapters: GeneratedChapterRow[];
  outlineText: string;
}

export interface ChapterRewriteItem {
  index: number;
  type?: string;
  title: string;
  summary: string;
}

export interface ChapterRewritePayload {
  instruction?: string;
  outlineContext?: string;
  chapters: ChapterRewriteItem[];
  settings?: AiRequestSettings;
}

export interface ChapterRewriteResult {
  chapters: { index: number; title: string; summary: string }[];
}

/** 匹配大纲格式：把粘贴的外部大纲重排成 App 固定格式 */
export interface OutlineFormatPayload {
  input: string;
  settings?: AiRequestSettings;
}

/** AI 写战斗：三要素 + 可选额外要求 */
export interface BattleGeneratePayload {
  skills?: string;
  scene?: string;
  result?: string;
  extra?: string;
  settings?: AiRequestSettings;
}

/** ── B站视频转文字 ── */

/** 视频分P */
export interface BiliPage {
  cid: number;
  page: number;
  part: string;
  duration: number;
}

/** 字幕源（用户上传或B站 AI 字幕） */
export interface BiliSubtitle {
  lan: string;
  lanDoc: string;
  ai: boolean;
  url: string;
}

/** resolve 返回的视频信息 */
export interface BiliVideoInfo {
  bvid: string;
  aid: number;
  title: string;
  owner: string;
  duration: number;
  sessdataConfigured: boolean;
  pages: BiliPage[];
  subtitles: BiliSubtitle[];
}

/** SESSDATA / 转写环境配置概况（脱敏） */
export interface BiliSettingsInfo {
  configured: boolean;
  source: string;
  preview?: string;
  savedAt?: string;
  pythonPath: string;
  pythonOk: boolean;
  whisperOk: boolean;
}

/** 保存 SESSDATA 的结果 */
export interface BiliSettingsSaveResult {
  configured: boolean;
  cleared?: boolean;
  valid?: boolean;
  uname?: string;
}

/** 提取请求：mode=auto 服务端决策（有字幕用字幕，无字幕本地转写） */
export interface BiliExtractPayload {
  bvid?: string;
  aid: number;
  cid: number;
  mode: 'auto' | 'subtitle' | 'asr';
  duration?: number;
  subtitleUrl?: string;
  /** 以下字段只用于把这次提取保存成可回看的记录 */
  title?: string;
  owner?: string;
  page?: number;
  part?: string;
}

/** 提取完成信息（done 事件） */
export interface BiliExtractDoneInfo {
  source?: 'subtitle' | 'asr';
  chars?: number;
  elapsedMs?: number;
  /** 本次提取自动保存到服务端后的记录 id */
  transcriptId?: string;
}

/** 一次已保存的提取记录（列表项，不含正文） */
export interface BiliTranscriptSummary {
  id: string;
  title: string;
  owner: string;
  bvid: string;
  aid: number;
  cid: number;
  page: number;
  part: string;
  duration: number;
  source: string;
  chars: number;
  createdAt: number;
}

/** 提取记录详情（含完整文字稿） */
export interface BiliTranscriptDetail extends BiliTranscriptSummary {
  text: string;
}

/** 模块标识 → 中文名（与 schema.js 的 module 字段对应） */
export const MODULE_LABELS: Record<string, string> = {
  settings: '设置',
  chat: '智能对话',
  novel_writing: '写小说',
  character_chat: '角色扮演',
  trpg: '跑团模拟器',
  novel_game: '小说游戏',
};

/** 把毫秒时间戳格式化成可读文本；兼容 ISO 字符串 */
export function formatTime(value: unknown): string {
  if (value === null || value === undefined || value === '') return '-';
  const date = typeof value === 'number' ? new Date(value) : new Date(String(value));
  if (Number.isNaN(date.getTime())) return String(value);
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds())
  );
}
/** ── RAG 情节素材库 ── */

export interface RagBookStat {
  book: string;
  count: number;
}

export interface RagStatus {
  esUrl: string;
  index: string;
  esOnline: boolean;
  embeddingConfigured: boolean;
  embeddingModel: string;
  totalScenes: number;
  totalBooks: number;
  books: RagBookStat[];
  tags: string[];
  error?: string;
}

export interface RagScene {
  id: string;
  score?: number;
  title: string;
  book: string;
  plot: string;
  excerpt: string;
  tags: string[];
  characters: string[];
  sceneType: string;
  emotion: string;
  reusable: string;
  createdAt: string;
}

/** 导入任务状态机：解析 →（等待手动开始）→ 提炼 → 合并去重 → 向量化 → 写库 → 完成 */
export type RagJobStatus =
  | 'parsing'
  | 'waiting'
  | 'extracting'
  | 'merging'
  | 'embedding'
  | 'indexing'
  | 'done'
  | 'failed';

export type RagWindowStatus = 'pending' | 'running' | 'done' | 'failed';

/** 分块窗口摘要：任务详情里带，不含窗口全文与 LLM 原文 */
export interface RagWindowSummary {
  index: number;
  title: string;
  chapterRange: string;
  chars: number;
  status: RagWindowStatus;
  sceneCount: number;
  error: string;
  elapsedMs: number;
  textPreview: string;
}

export interface RagJob {
  id: string;
  book: string;
  status: RagJobStatus;
  phase: string;
  progress: number;
  message: string;
  error: string;
  chunksTotal: number;
  chunksDone: number;
  sceneCount: number;
  mergedCount: number;
  format: string;
  chapterPattern: string;
  paragraphs: number;
  chapters: number;
  totalChars: number;
  windowChars: number;
  overlapChars: number;
  concurrency: number;
  createdAt: number;
  startedAt: number;
  finishedAt: number;
  windows: RagWindowSummary[];
}

/** 最近任务列表用的精简信息（不含窗口列表） */
export type RagJobSummary = Pick<
  RagJob,
  | 'id'
  | 'book'
  | 'status'
  | 'phase'
  | 'progress'
  | 'chunksDone'
  | 'chunksTotal'
  | 'sceneCount'
  | 'error'
  | 'createdAt'
  | 'startedAt'
  | 'finishedAt'
>;

/** 窗口详情里解析出的情节对象（比入库后的 RagScene 少一些字段） */
export interface RagSceneLike {
  title: string;
  plot: string;
  tags: string[];
  characters: string[];
  sceneType?: string;
  emotion?: string;
  reusable?: string;
}

/** GET /api/rag/jobs/{id}/windows/{index}：窗口全文 + DeepSeek 原始返回 + 解析结果 */
export interface RagWindowDetail extends RagWindowSummary {
  text: string;
  rawOutput: string;
  scenes: RagSceneLike[];
}

/** 重新分块 / 开始提炼时提交的参数（字段都可省略，省略则沿用服务端设置） */
export interface RagJobSplitPayload {
  windowChars?: number;
  overlapChars?: number;
  concurrency?: number;
}

/** 提炼设置 */
export interface RagSettings {
  manualExtract: boolean;
  windowChars: number;
  overlapChars: number;
  concurrency: number;
  defaults: {
    manualExtract: boolean;
    windowChars: number;
    overlapChars: number;
    concurrency: number;
  };
}

/** PUT /api/rag/settings 允许提交的部分字段 */
export interface RagSettingsPayload {
  manualExtract?: boolean;
  windowChars?: number;
  overlapChars?: number;
  concurrency?: number;
}

export interface RagImportResult {
  jobId: string;
  book: string;
  chars: number;
  replace: boolean;
}

export interface RagSearchResult {
  query: string;
  hits: RagScene[];
}

export interface RagImitateResult {
  draft: string;
  references: RagScene[];
  query: string;
}
/** ── 分阶段一键生成大纲（与移动端流程/检查点对齐） ── */

export interface OutlineEvent {
  title: string;
  summary: string;
}

export interface OutlineAct {
  name: string;
  events: OutlineEvent[];
}

export interface OutlineStagePayload {
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
  extra?: string;
  majorCount?: number;
  minorCount?: number;
  title?: string;
  concept?: string;
  conceptText?: string;
  acts?: OutlineAct[];
  ledgerText?: string;
  settings?: AiRequestSettings;
}

export interface OutlineConceptResult {
  title: string;
  concept: string;
  conceptText: string;
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
}

export interface OutlineSkeletonResult {
  title: string;
  concept: string;
  acts: OutlineAct[];
  coarseText: string;
  skeletonText: string;
  eventCount: number;
  majorCount: number;
  minorCount: number;
}

export interface OutlineEventsResult {
  title: string;
  concept: string;
  acts: OutlineAct[];
  coarseActs: OutlineAct[];
  coarseText: string;
  eventsText: string;
  ledgerText: string;
  ledger?: Record<string, unknown>;
  minorCount: number;
}

export interface OutlineMinorResult {
  title: string;
  concept: string;
  acts: OutlineAct[];
  outlineText: string;
  chapters: GeneratedChapterRow[];
  ledgerText: string;
  minorCount: number;
}
