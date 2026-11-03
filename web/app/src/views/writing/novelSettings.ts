/** 写作模块的 AI 设置：读写手机端同名表 outline_settings / chapter_settings */
import { reactive } from 'vue';
import { api } from '@/api';
import type { Row } from '@/api';

export const MODEL_OPTIONS = [
  { id: 'deepseek-flash', label: 'deepseek-flash · 快' },
  { id: 'deepseek-pro', label: 'deepseek-pro · 强' },
];

export const DEFAULT_OUTLINE_PROMPT = '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';
export const DEFAULT_CHAPTER_PROMPT = '你是一个专业的小说作家。';
export const DEFAULT_BATTLE_PROMPT = '你是一位专业的战斗场景描写作家。请根据用户提供的战斗要素（双方人物技能、战斗场景氛围、战斗结果），生成一段精彩具体的战斗场景描写。\n\n要求：\n1. 紧扣用户提供的要素，不要偏离设定\n2. 描写要生动具体，包含动作、环境、心理等细节\n3. 合理运用打斗过程的起承转合\n4. 战斗结果必须与用户指定的结果一致\n5. 用中文创作，使用纯文本格式\n6. 篇幅在 1000-3000 字之间';

export interface OutlineAiSettings {
  id: number | null;
  model: string;
  temperature: number;
  maxTokens: number;
  systemPrompt: string;
  enableThinking: boolean;
}

export interface ChapterAiSettings {
  id: number | null;
  model: string;
  temperature: number;
  maxTokens: number;
  chapterSystemPrompt: string;
  enableThinking: boolean;
  enableStoryState: boolean;
  chapterMinWords: number;
  chapterMaxWords: number;
}

export interface BattleAiSettings {
  id: number | null;
  model: string;
  temperature: number;
  maxTokens: number;
  systemPrompt: string;
  /** 战斗设置表没有这一列，仅为抽屉共用字段保留（不落库） */
  enableThinking?: boolean;
}

export const outlineSettings = reactive<OutlineAiSettings>({
  id: null,
  model: 'deepseek-flash',
  temperature: 0.8,
  maxTokens: 4096,
  systemPrompt: DEFAULT_OUTLINE_PROMPT,
  enableThinking: true,
});

export const chapterSettings = reactive<ChapterAiSettings>({
  id: null,
  model: 'deepseek-flash',
  temperature: 0.8,
  maxTokens: 4096,
  chapterSystemPrompt: DEFAULT_CHAPTER_PROMPT,
  enableThinking: true,
  enableStoryState: true,
  chapterMinWords: 2000,
  chapterMaxWords: 3000,
});

export const battleSettings = reactive<BattleAiSettings>({
  id: null,
  model: 'deepseek-flash',
  temperature: 0.8,
  maxTokens: 4096,
  systemPrompt: DEFAULT_BATTLE_PROMPT,
});

function num(value: unknown, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function bool(value: unknown, fallback: boolean): boolean {
  if (value === null || value === undefined) return fallback;
  return Number(value) === 1 || value === true || value === '1';
}

function applyOutline(row: Row | undefined) {
  if (!row) return;
  outlineSettings.id = Number(row.id);
  outlineSettings.model = String(row.model || 'deepseek-flash');
  outlineSettings.temperature = num(row.temperature, 0.8);
  outlineSettings.maxTokens = num(row.max_tokens, 4096);
  outlineSettings.systemPrompt = String(row.system_prompt || DEFAULT_OUTLINE_PROMPT);
  outlineSettings.enableThinking = bool(row.enable_thinking, true);
}

function applyChapter(row: Row | undefined) {
  if (!row) return;
  chapterSettings.id = Number(row.id);
  chapterSettings.model = String(row.model || 'deepseek-flash');
  chapterSettings.temperature = num(row.temperature, 0.8);
  chapterSettings.maxTokens = num(row.max_tokens, 4096);
  chapterSettings.chapterSystemPrompt = String(row.chapter_system_prompt || DEFAULT_CHAPTER_PROMPT);
  chapterSettings.enableThinking = bool(row.enable_thinking, true);
  chapterSettings.enableStoryState = bool(row.enable_story_state, true);
  chapterSettings.chapterMinWords = num(row.chapter_min_words, 2000);
  chapterSettings.chapterMaxWords = num(row.chapter_max_words, 3000);
}

function applyBattle(row: Row | undefined) {
  if (!row) return;
  battleSettings.id = Number(row.id);
  battleSettings.model = String(row.model || 'deepseek-flash');
  battleSettings.temperature = num(row.temperature, 0.8);
  battleSettings.maxTokens = num(row.max_tokens, 4096);
  battleSettings.systemPrompt = String(row.system_prompt || DEFAULT_BATTLE_PROMPT);
}

export async function loadAiSettings(): Promise<void> {
  try {
    const [outline, chapter, battle] = await Promise.all([
      api.listRows('deepseek', 'outline_settings', { page: 1, pageSize: 1 }),
      api.listRows('deepseek', 'chapter_settings', { page: 1, pageSize: 1 }),
      api.listRows('deepseek', 'battle_settings', { page: 1, pageSize: 1 }),
    ]);
    applyOutline(outline.data[0]);
    applyChapter(chapter.data[0]);
    applyBattle(battle.data[0]);
  } catch {
    // 首次使用还没有设置行时保持默认值即可
  }
}

export async function saveOutlineSettings(): Promise<void> {
  const payload = {
    model: outlineSettings.model,
    temperature: outlineSettings.temperature,
    max_tokens: outlineSettings.maxTokens,
    system_prompt: outlineSettings.systemPrompt,
    enable_thinking: outlineSettings.enableThinking ? 1 : 0,
  };
  if (outlineSettings.id) {
    await api.updateRow('deepseek', 'outline_settings', outlineSettings.id, payload);
  } else {
    const created = await api.createRow('deepseek', 'outline_settings', payload);
    outlineSettings.id = Number(created.pk);
  }
}

export async function saveChapterSettings(): Promise<void> {
  const min = Math.min(chapterSettings.chapterMinWords, chapterSettings.chapterMaxWords);
  const max = Math.max(chapterSettings.chapterMinWords, chapterSettings.chapterMaxWords);
  const payload = {
    model: chapterSettings.model,
    temperature: chapterSettings.temperature,
    max_tokens: chapterSettings.maxTokens,
    chapter_system_prompt: chapterSettings.chapterSystemPrompt,
    enable_thinking: chapterSettings.enableThinking ? 1 : 0,
    enable_story_state: chapterSettings.enableStoryState ? 1 : 0,
    chapter_min_words: min,
    chapter_max_words: max,
  };
  if (chapterSettings.id) {
    await api.updateRow('deepseek', 'chapter_settings', chapterSettings.id, payload);
  } else {
    const created = await api.createRow('deepseek', 'chapter_settings', payload);
    chapterSettings.id = Number(created.pk);
  }
}

export async function saveBattleSettings(): Promise<void> {
  const payload = {
    model: battleSettings.model,
    temperature: battleSettings.temperature,
    max_tokens: battleSettings.maxTokens,
    system_prompt: battleSettings.systemPrompt,
  };
  if (battleSettings.id) {
    await api.updateRow('deepseek', 'battle_settings', battleSettings.id, payload);
  } else {
    const created = await api.createRow('deepseek', 'battle_settings', payload);
    battleSettings.id = Number(created.pk);
  }
}

/** 传给后端的单次调用设置 */
export function outlineRequestSettings() {
  return {
    model: outlineSettings.model,
    temperature: outlineSettings.temperature,
    maxTokens: outlineSettings.maxTokens,
    systemPrompt: outlineSettings.systemPrompt,
  };
}

export function chapterRequestSettings() {
  return {
    model: chapterSettings.model,
    temperature: chapterSettings.temperature,
    maxTokens: chapterSettings.maxTokens,
    systemPrompt: chapterSettings.chapterSystemPrompt,
  };
}

export function battleRequestSettings() {
  return {
    model: battleSettings.model,
    temperature: battleSettings.temperature,
    maxTokens: battleSettings.maxTokens,
    systemPrompt: battleSettings.systemPrompt,
  };
}
