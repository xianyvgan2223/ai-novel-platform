/**
 * 小说灵感 — 网页端数据访问与提示词。
 *
 * 数据存 deepseek 库的 inspiration_* 表（通过网页通用数据接口，按设备隔离）；
 * 表结构与移动端保持一致，页面本身不依赖后端新接口，只额外调用一个通用的流式生成接口。
 */
import { api } from '@/api';
import type { Row } from '@/api';
import type { StreamHandlers } from '@/api/client';
import type { AiRequestSettings } from '@/api/types';

export const DEFAULT_SYSTEM_PROMPT =
  '你是一位中文小说作家，正在和作者一起推演小说剧情。请严格按照作者本轮指令的要求输出。';

const WRITING_RULES =
  '【最高优先级】严格按照作者本轮指令的要求输出：作者要求正文就写正文；' +
  '要求大纲、分析、方案、条目、对话或其它形式，就按相应形式输出。不要自行添加作者没有要求的内容。\n' +
  '内容要求：\n' +
  '- 承接【故事前文】最后的结果，保持人物、时间、地点、伤势与情绪连续（作者另有要求时以作者要求为准）；\n' +
  '- 遵守【世界观】【主题】；人物言行符合【人物卡】；\n' +
  '- 若给出【大纲事件】，只在这些事件的范围内推进，不提前写后续事件、不改动既定剧情；\n' +
  '- 除作者要求外，不要自行添加标题、章节编号或解释说明。';

export interface InspirationSettings {
  model: string;
  temperature: number;
  maxTokens: number;
  systemPrompt: string;
  enableThinking: boolean;
  reasoningEffort: string;
  concurrency: number;
}

export interface OutlineEvent {
  chapterId: number | null;
  type: 'major' | 'minor';
  title: string;
  summary: string;
  majorNumber: number | null;
  minorNumber: number | null;
}

export interface InspirationSession {
  id: number;
  title: string;
  worldView: string;
  theme: string;
  outlineRecordId: number | null;
  outlineTitle: string;
  events: OutlineEvent[];
  createdAt: string;
  updatedAt: string;
}

export interface InspirationMessage {
  id: number;
  sessionId: number;
  content: string;
  createdAt: string;
  revisions: unknown[];
  branches: InspirationBranch[];
}

export interface InspirationBranch {
  id: number;
  sessionId: number;
  messageId: number;
  content: string;
  kind: 'single' | 'merge';
  chosen: boolean;
  generationNo: number;
  sourceIds: number[];
  createdAt: string;
  updatedAt: string;
}

export interface InspirationChatMessage {
  id: number;
  sessionId: number;
  role: 'user' | 'assistant';
  content: string;
  createdAt: string;
}

export interface InspirationCard {
  id: number;
  sessionId: number;
  name: string;
  description: string;
  personality: string;
  experiences: string;
  skills: string;
  status: string;
  inject: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface ChatTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface HistoryTurn {
  instruction: string;
  result: string;
}

const DEFAULT_SETTINGS: InspirationSettings = {
  model: 'deepseek-flash',
  temperature: 0.8,
  maxTokens: 4096,
  systemPrompt: '',
  enableThinking: true,
  reasoningEffort: 'high',
  concurrency: 3,
};

export function isoNow(): string {
  return new Date().toISOString();
}

/* ── 行 → 模型 ── */

function decodeEvents(raw: unknown): OutlineEvent[] {
  try {
    const parsed = JSON.parse(String(raw ?? '[]'));
    if (!Array.isArray(parsed)) return [];
    return parsed.map((item: Record<string, unknown>) => ({
      chapterId: item.chapterId == null ? null : Number(item.chapterId),
      type: String(item.type ?? 'minor') === 'major' ? 'major' : 'minor',
      title: String(item.title ?? ''),
      summary: String(item.summary ?? ''),
      majorNumber: item.majorNumber == null ? null : Number(item.majorNumber),
      minorNumber: item.minorNumber == null ? null : Number(item.minorNumber),
    }));
  } catch {
    return [];
  }
}

export function encodeEvents(events: OutlineEvent[]): string {
  return JSON.stringify(events);
}

export function toSession(row: Row): InspirationSession {
  return {
    id: Number(row.id),
    title: String(row.title ?? ''),
    worldView: String(row.world_view ?? ''),
    theme: String(row.theme ?? ''),
    outlineRecordId: row.outline_record_id == null ? null : Number(row.outline_record_id),
    outlineTitle: String(row.outline_title ?? ''),
    events: decodeEvents(row.selected_events),
    createdAt: String(row.created_at ?? ''),
    updatedAt: String(row.updated_at ?? ''),
  };
}

export function toSettings(row: Row): InspirationSettings {
  return {
    model: String(row.model ?? DEFAULT_SETTINGS.model),
    temperature: Number(row.temperature ?? DEFAULT_SETTINGS.temperature),
    maxTokens: Number(row.max_tokens ?? DEFAULT_SETTINGS.maxTokens),
    systemPrompt: String(row.system_prompt ?? ''),
    enableThinking: Number(row.enable_thinking ?? 1) === 1,
    reasoningEffort: String(row.reasoning_effort ?? 'high'),
    concurrency: Math.min(10, Math.max(1, Number(row.concurrency ?? 3))),
  };
}

export function toMessage(row: Row, branches: InspirationBranch[]): InspirationMessage {
  let revisions: unknown[] = [];
  try {
    const parsed = JSON.parse(String(row.revisions ?? '[]'));
    if (Array.isArray(parsed)) revisions = parsed;
  } catch {
    revisions = [];
  }
  return {
    id: Number(row.id),
    sessionId: Number(row.session_id ?? 0),
    content: String(row.content ?? ''),
    createdAt: String(row.created_at ?? ''),
    revisions,
    branches,
  };
}

export function toBranch(row: Row): InspirationBranch {
  let sourceIds: number[] = [];
  try {
    const parsed = JSON.parse(String(row.source_ids ?? '[]'));
    if (Array.isArray(parsed)) sourceIds = parsed.map((v) => Number(v)).filter((v) => Number.isFinite(v));
  } catch {
    sourceIds = [];
  }
  return {
    id: Number(row.id),
    sessionId: Number(row.session_id ?? 0),
    messageId: Number(row.message_id ?? 0),
    content: String(row.content ?? ''),
    kind: String(row.kind ?? 'single') === 'merge' ? 'merge' : 'single',
    chosen: Number(row.chosen ?? 0) === 1,
    generationNo: Math.max(1, Number(row.generation_no ?? 1)),
    sourceIds,
    createdAt: String(row.created_at ?? ''),
    updatedAt: String(row.updated_at ?? ''),
  };
}

export function toChatMessage(row: Row): InspirationChatMessage {
  return {
    id: Number(row.id),
    sessionId: Number(row.session_id ?? 0),
    role: String(row.role ?? 'user') === 'assistant' ? 'assistant' : 'user',
    content: String(row.content ?? ''),
    createdAt: String(row.created_at ?? ''),
  };
}

export function toCard(row: Row): InspirationCard {
  return {
    id: Number(row.id),
    sessionId: Number(row.session_id ?? 0),
    name: String(row.name ?? ''),
    description: String(row.description ?? ''),
    personality: String(row.personality ?? ''),
    experiences: String(row.experiences ?? ''),
    skills: String(row.skills ?? ''),
    status: String(row.status ?? ''),
    inject: Number(row.inject ?? 1) === 1,
    createdAt: String(row.created_at ?? ''),
    updatedAt: String(row.updated_at ?? ''),
  };
}

/* ── 设置 ── */

export async function loadSettings(): Promise<InspirationSettings> {
  const res = await api.listRows('deepseek', 'inspiration_settings', {
    page: 1,
    pageSize: 1,
    orderBy: 'id',
    dir: 'asc',
  });
  if (res.data.length) return toSettings(res.data[0]);
  try {
    const now = isoNow();
    await api.createRow('deepseek', 'inspiration_settings', {
      id: 1,
      ...settingsRow(DEFAULT_SETTINGS),
      updated_at: now,
    });
  } catch {
    /* 另一个页面刚创建过时会冲突，读取即可 */
  }
  return { ...DEFAULT_SETTINGS };
}

function settingsRow(settings: InspirationSettings): Row {
  return {
    model: settings.model,
    temperature: settings.temperature,
    max_tokens: settings.maxTokens,
    system_prompt: settings.systemPrompt,
    enable_thinking: settings.enableThinking ? 1 : 0,
    reasoning_effort: settings.reasoningEffort,
    concurrency: settings.concurrency,
  };
}

export async function saveSettings(settings: InspirationSettings): Promise<void> {
  await api.updateRow('deepseek', 'inspiration_settings', 1, settingsRow(settings));
}

/* ── 会话 ── */

export async function listSessions(): Promise<InspirationSession[]> {
  const res = await api.listRows('deepseek', 'inspiration_sessions', {
    page: 1,
    pageSize: 200,
    orderBy: 'updated_at',
    dir: 'desc',
  });
  return res.data.map(toSession);
}

export async function createSession(patch: Partial<Row> = {}): Promise<number> {
  const now = isoNow();
  const result = await api.createRow('deepseek', 'inspiration_sessions', {
    title: '新的灵感',
    world_view: '',
    theme: '',
    outline_title: '',
    selected_events: '[]',
    created_at: now,
    updated_at: now,
    ...patch,
  });
  return Number(result.pk);
}

export async function updateSession(id: number, patch: Partial<Row>): Promise<void> {
  await api.updateRow('deepseek', 'inspiration_sessions', id, { ...patch, updated_at: isoNow() });
}

export async function deleteSession(id: number): Promise<void> {
  await api.deleteRow('deepseek', 'inspiration_sessions', id);
}

/* ── 指令 / 推演 / 对话 / 人物卡 ── */

export async function listMessages(sessionId: number, branches: InspirationBranch[]): Promise<InspirationMessage[]> {
  const res = await api.listRows('deepseek', 'inspiration_messages', {
    session_id: sessionId,
    page: 1,
    pageSize: 500,
    full: 1,
    orderBy: 'id',
    dir: 'asc',
  });
  return res.data.map((row) => toMessage(row, branches.filter((b) => b.messageId === Number(row.id))));
}

export async function listBranches(sessionId: number): Promise<InspirationBranch[]> {
  const res = await api.listRows('deepseek', 'inspiration_branches', {
    session_id: sessionId,
    page: 1,
    pageSize: 2000,
    full: 1,
    orderBy: 'id',
    dir: 'asc',
  });
  return res.data.map(toBranch);
}

export async function createMessage(sessionId: number, content: string): Promise<number> {
  const now = isoNow();
  const result = await api.createRow('deepseek', 'inspiration_messages', {
    session_id: sessionId,
    content,
    revisions: '[]',
    created_at: now,
    updated_at: now,
  });
  return Number(result.pk);
}

export async function updateMessage(id: number, content: string): Promise<void> {
  await api.updateRow('deepseek', 'inspiration_messages', id, { content, updated_at: isoNow() });
}

export async function deleteMessage(id: number): Promise<void> {
  await api.deleteRow('deepseek', 'inspiration_messages', id);
}

export async function createBranch(input: {
  sessionId: number;
  messageId: number;
  content: string;
  kind?: 'single' | 'merge';
  generationNo: number;
  sourceIds?: number[];
}): Promise<number> {
  const now = isoNow();
  const result = await api.createRow('deepseek', 'inspiration_branches', {
    session_id: input.sessionId,
    message_id: input.messageId,
    content: input.content,
    kind: input.kind ?? 'single',
    chosen: 0,
    generation_no: input.generationNo,
    source_ids: JSON.stringify(input.sourceIds ?? []),
    created_at: now,
    updated_at: now,
  });
  return Number(result.pk);
}

export async function updateBranch(id: number, content: string): Promise<void> {
  await api.updateRow('deepseek', 'inspiration_branches', id, { content, updated_at: isoNow() });
}

export async function setBranchChosen(messageId: number, branchId: number, branches: InspirationBranch[]): Promise<void> {
  const targets = branches.filter((b) => b.messageId === messageId && b.chosen);
  for (const branch of targets) {
    await api.updateRow('deepseek', 'inspiration_branches', branch.id, { chosen: 0 });
  }
  await api.updateRow('deepseek', 'inspiration_branches', branchId, { chosen: 1 });
}

export async function deleteBranch(id: number): Promise<void> {
  await api.deleteRow('deepseek', 'inspiration_branches', id);
}

export async function listChatMessages(sessionId: number): Promise<InspirationChatMessage[]> {
  const res = await api.listRows('deepseek', 'inspiration_chat_messages', {
    session_id: sessionId,
    page: 1,
    pageSize: 1000,
    full: 1,
    orderBy: 'id',
    dir: 'asc',
  });
  return res.data.map(toChatMessage);
}

export async function createChatMessage(sessionId: number, role: 'user' | 'assistant', content: string): Promise<number> {
  const now = isoNow();
  const result = await api.createRow('deepseek', 'inspiration_chat_messages', {
    session_id: sessionId,
    role,
    content,
    created_at: now,
    updated_at: now,
  });
  return Number(result.pk);
}

export async function listCards(sessionId: number): Promise<InspirationCard[]> {
  const res = await api.listRows('deepseek', 'inspiration_cards', {
    session_id: sessionId,
    page: 1,
    pageSize: 200,
    full: 1,
    orderBy: 'id',
    dir: 'asc',
  });
  return res.data.map(toCard);
}

export async function createCard(input: Omit<InspirationCard, 'id' | 'createdAt' | 'updatedAt'>): Promise<number> {
  const now = isoNow();
  const result = await api.createRow('deepseek', 'inspiration_cards', {
    session_id: input.sessionId,
    name: input.name,
    description: input.description,
    personality: input.personality,
    experiences: input.experiences,
    skills: input.skills,
    status: input.status,
    inject: input.inject ? 1 : 0,
    created_at: now,
    updated_at: now,
  });
  return Number(result.pk);
}

export async function updateCard(card: InspirationCard): Promise<void> {
  await api.updateRow('deepseek', 'inspiration_cards', card.id, {
    name: card.name,
    description: card.description,
    personality: card.personality,
    experiences: card.experiences,
    skills: card.skills,
    status: card.status,
    inject: card.inject ? 1 : 0,
    updated_at: isoNow(),
  });
}

export async function deleteCard(id: number): Promise<void> {
  await api.deleteRow('deepseek', 'inspiration_cards', id);
}

/* ── 提示词 ── */

export function buildSystemPrompt(input: {
  settings: InspirationSettings;
  worldView?: string;
  theme?: string;
  events?: OutlineEvent[];
  cards?: InspirationCard[];
}): string {
  const configured = input.settings.systemPrompt.trim();
  const base = configured || DEFAULT_SYSTEM_PROMPT;
  const lines: string[] = [base, '', WRITING_RULES];
  const worldView = (input.worldView ?? '').trim();
  const theme = (input.theme ?? '').trim();
  if (worldView || theme) {
    lines.push('', '【本作设定】');
    if (worldView) lines.push(`世界观：${worldView}`);
    if (theme) lines.push(`主题：${theme}`);
  }
  const activeCards = (input.cards ?? []).filter((c) => c.inject && c.name.trim());
  if (activeCards.length) {
    lines.push('', '【人物卡】');
    for (const card of activeCards) {
      lines.push(`· ${card.name.trim()}`);
      if (card.description.trim()) lines.push(`  描述：${card.description.trim()}`);
      if (card.personality.trim()) lines.push(`  性格：${card.personality.trim()}`);
      if (card.experiences.trim()) lines.push(`  经历过的事件：${card.experiences.trim()}`);
      if (card.skills.trim()) lines.push(`  技能：${card.skills.trim()}`);
      if (card.status.trim()) lines.push(`  当前状态：${card.status.trim()}`);
    }
  }
  const events = input.events ?? [];
  if (events.length) {
    lines.push('', '【大纲事件（只允许写这些事件范围内的剧情，不要提前写后续事件）】');
    for (const event of events) {
      lines.push(`· ${event.type === 'major' ? '大事件' : '小事件'}《${event.title.trim()}》`);
      if (event.summary.trim()) lines.push(`  ${event.summary.trim()}`);
    }
  }
  return lines.join('\n').trim();
}

export function buildChatSystemPrompt(input: {
  settings: InspirationSettings;
  worldView?: string;
  theme?: string;
  events?: OutlineEvent[];
  cards?: InspirationCard[];
  deductionResults?: string[];
}): string {
  const lines = [
    '你是作者的小说创作助手，正在和作者讨论这部小说。',
    '你的任务是回答问题、讨论剧情 / 人物 / 设定、给建议；除非作者明确要求，不要续写正文。',
    '回答要简洁、具体，直接回应作者的问题。',
    '不要编造与已确立的设定、已采用的推演结果相矛盾的内容。',
  ];
  const worldView = (input.worldView ?? '').trim();
  const theme = (input.theme ?? '').trim();
  if (worldView || theme) {
    lines.push('', '【本作设定】');
    if (worldView) lines.push(`世界观：${worldView}`);
    if (theme) lines.push(`主题：${theme}`);
  }
  const activeCards = (input.cards ?? []).filter((c) => c.inject && c.name.trim());
  if (activeCards.length) {
    lines.push('', '【人物卡】');
    for (const card of activeCards) {
      lines.push(`· ${card.name.trim()}`);
      if (card.description.trim()) lines.push(`  描述：${card.description.trim()}`);
      if (card.personality.trim()) lines.push(`  性格：${card.personality.trim()}`);
      if (card.status.trim()) lines.push(`  当前状态：${card.status.trim()}`);
    }
  }
  const events = input.events ?? [];
  if (events.length) {
    lines.push('', '【已导入的大纲事件】');
    for (const event of events) {
      lines.push(`· ${event.type === 'major' ? '大事件' : '小事件'}《${event.title.trim()}》`);
      if (event.summary.trim()) lines.push(`  ${event.summary.trim()}`);
    }
  }
  const results = input.deductionResults ?? [];
  if (results.length) {
    lines.push('', '【已采用的推演结果（只作为故事事实参考，不要续写）】');
    results.forEach((result, index) => lines.push(`· 第 ${index + 1} 轮：${result.trim()}`));
  }
  return lines.join('\n').trim();
}

export function buildGenerateTurns(input: {
  history: HistoryTurn[];
  instruction: string;
  variantIndex: number;
  variantCount: number;
}): ChatTurn[] {
  const turns: ChatTurn[] = [];
  for (const item of input.history) {
    turns.push({ role: 'user', content: item.instruction });
    turns.push({ role: 'assistant', content: item.result });
  }
  const variantNote = input.variantCount > 1
    ? `\n\n（本次是第 ${input.variantIndex} 个候选推演，共 ${input.variantCount} 个；在合理范围内选择一个与其它候选不同的思路或侧重点，但仍要完整满足作者本轮指令的要求。）`
    : '';
  turns.push({ role: 'user', content: `${input.instruction}${variantNote}` });
  return turns;
}

export function buildMergeTurns(input: {
  history: HistoryTurn[];
  instruction: string;
  branches: string[];
  requirement?: string;
}): ChatTurn[] {
  const turns: ChatTurn[] = [];
  for (const item of input.history) {
    turns.push({ role: 'user', content: item.instruction });
    turns.push({ role: 'assistant', content: item.result });
  }
  const lines = [
    `请把下面 ${input.branches.length} 个推演结果合并成一个结果。`,
    '要求：',
    '- 保留每个结果里最好的冲突、转折、场景与细节，去掉重复和矛盾；',
    '- 合并后的人物、时间、地点、因果必须连贯；',
    '- 只输出合并后的结果，格式与详略严格按照【用户本轮指令】的要求；',
    '- 用户要求正文就写正文，要求大纲、分析、方案或其它形式就按相应形式输出；',
    '',
    `【用户本轮指令】${input.instruction}`,
    '',
    '【待合并的推演结果】',
  ];
  input.branches.forEach((branch, index) => {
    lines.push(`—— 推演 ${index + 1} ——`, branch.trim(), '');
  });
  const requirement = (input.requirement ?? '').trim();
  if (requirement) {
    lines.push('【额外要求（优先遵守）】', requirement);
  }
  turns.push({ role: 'user', content: lines.join('\n').trim() });
  return turns;
}

export function buildCardStatusTurns(card: InspirationCard, session: InspirationSession): ChatTurn[] {
  const lines: string[] = [
    '你是小说人物设定助手。请根据世界观、人物卡与已选大纲事件，写出这个人物当前的状态（处境、目标、情绪、伤势/能力变化、与关键人物的关系）。',
    '要求：只输出状态正文，80~150 字，不要解释、不要标题。',
    '',
  ];
  if (session.worldView.trim()) lines.push(`【世界观】${session.worldView.trim()}`);
  if (session.theme.trim()) lines.push(`【主题】${session.theme.trim()}`);
  lines.push('【人物卡】', `姓名：${card.name.trim()}`);
  if (card.description.trim()) lines.push(`描述：${card.description.trim()}`);
  if (card.personality.trim()) lines.push(`性格：${card.personality.trim()}`);
  if (card.experiences.trim()) lines.push(`经历过的事件：${card.experiences.trim()}`);
  if (card.skills.trim()) lines.push(`技能：${card.skills.trim()}`);
  if (session.events.length) {
    lines.push('', '【已选大纲事件（只依据这些事件推演）】');
    for (const event of session.events) {
      lines.push(`· ${event.title.trim()}：${event.summary.trim()}`);
    }
  }
  return [
    { role: 'user', content: lines.join('\n').trim() },
  ];
}

export function aiSettings(settings: InspirationSettings): AiRequestSettings {
  return {
    model: settings.model,
    temperature: settings.temperature,
    maxTokens: settings.maxTokens,
  };
}

export function streamInspiration(
  payload: { systemPrompt: string; messages: ChatTurn[]; settings: AiRequestSettings },
  handlers: StreamHandlers,
  signal?: AbortSignal,
): Promise<void> {
  return api.writing.novel.streamInspiration(payload, handlers, signal);
}